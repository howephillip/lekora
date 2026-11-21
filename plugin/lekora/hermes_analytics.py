"""Hermes glue for Analytics (docs/analytics.md). Imports Hermes lazily: only runs inside it.

- ``read_usage``: one agent's usage from its own session database, opened read-only with Hermes'
  ``SessionDB(read_only=True)`` (never a raw sqlite connection inside the gateway).
- ``accounts``: what each provider reports about the account, with Hermes' own account checks
  (the same as its ``/usage``), run inside the agent's profile so its own keys are used.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)

_COST = "COALESCE(NULLIF({t}.actual_cost_usd, 0), {t}.estimated_cost_usd, 0)"
_TOKENS = ("COALESCE({t}.input_tokens,0) + COALESCE({t}.output_tokens,0) + "
           "COALESCE({t}.cache_read_tokens,0) + COALESCE({t}.cache_write_tokens,0)")
_DAY = "date(s.started_at, 'unixepoch', 'localtime')"

MAIN_SQL = (f"SELECT {_DAY} AS day, s.source AS source, COUNT(*) AS sessions, "
            f"SUM({_COST.format(t='s')}) AS cost_usd, SUM({_TOKENS.format(t='s')}) AS tokens "
            "FROM sessions s WHERE s.started_at >= ? GROUP BY day, s.source")
BACKGROUND_SQL = (f"SELECT {_DAY} AS day, SUM({_COST.format(t='u')}) AS cost_usd, SUM({_TOKENS.format(t='u')}) AS tokens "
                  "FROM session_model_usage u JOIN sessions s ON s.id = u.session_id "
                  "WHERE u.task != '' AND s.started_at >= ? GROUP BY day")
MODELS_SQL = (f"SELECT u.model AS model, u.billing_provider AS provider, SUM({_COST.format(t='u')}) AS cost_usd, "
              f"SUM({_TOKENS.format(t='u')}) AS tokens "
              "FROM session_model_usage u JOIN sessions s ON s.id = u.session_id "
              "WHERE s.started_at >= ? GROUP BY u.model, u.billing_provider")


def _rows(db: Any, sql: str, params: tuple) -> list[dict]:
    read_all = getattr(db, "_read_all", None)
    rows = read_all(sql, params) if callable(read_all) else db._conn.execute(sql, params).fetchall()
    return [dict(r) if not isinstance(r, dict) else r for r in rows]


def read_usage(home: Path, since: float) -> dict:
    """One agent's usage since ``since`` (seconds), from ``<home>/state.db``."""
    path = Path(home) / "state.db"
    if not path.is_file():
        return {}
    from hermes_state import SessionDB
    db = SessionDB(db_path=path, read_only=True)
    try:
        out: dict[str, list] = {"main": _rows(db, MAIN_SQL, (since,))}
        for name, sql in (("background", BACKGROUND_SQL), ("models", MODELS_SQL)):
            try:
                out[name] = _rows(db, sql, (since,))
            except Exception:  # an older store without per-model usage
                log.debug("Lekora: no %s usage in %s", name, path, exc_info=True)
                out[name] = []
        return out
    finally:
        db.close()


def _snapshot(snapshot: Any) -> Optional[dict]:
    if snapshot is None:
        return None
    if getattr(snapshot, "unavailable_reason", None) and not getattr(snapshot, "windows", None):
        return {"provider": snapshot.provider, "unavailable_reason": snapshot.unavailable_reason}
    windows = []
    for w in getattr(snapshot, "windows", ()) or ():
        item: dict[str, Any] = {"label": w.label}
        if w.used_percent is not None:
            item["used_percent"] = round(float(w.used_percent), 1)
        if w.detail:
            item["detail"] = w.detail
        if w.reset_at is not None:
            item["reset_at"] = w.reset_at.isoformat()
        windows.append(item)
    out = {"provider": snapshot.provider, "title": snapshot.title, "windows": windows,
           "details": list(getattr(snapshot, "details", ()) or ())}
    if getattr(snapshot, "plan", None):
        out["plan"] = snapshot.plan
    return out


def _fetch(provider: str) -> Optional[dict]:
    if provider == "nous":
        from agent.account_usage import _fetch_portal_account, _nous_logged_in, build_nous_credits_snapshot
        return _snapshot(build_nous_credits_snapshot(_fetch_portal_account(10.0))) if _nous_logged_in() else None
    from agent.account_usage import fetch_account_usage
    return _snapshot(fetch_account_usage(provider, read_only=True))


def accounts(pairs: list[tuple[str, str]], home_of: Callable[[str], Path]) -> list[dict]:
    """Each provider's own account report, checked inside each agent's profile; identical reports
    (the same key shared by several agents) are shown once with every agent that uses it."""
    from gateway.run import _profile_runtime_scope
    merged: dict[str, dict] = {}
    silent: dict[str, set] = {}
    for profile_id, provider in pairs:
        slug = str(provider or "").strip().lower()
        if not slug or slug in ("auto", "custom", "none"):
            continue
        try:
            with _profile_runtime_scope(Path(home_of(profile_id)), hydrate_secrets=True):
                got = _fetch(slug)
        except Exception:
            log.debug("Lekora: %s's account check for %s failed", slug, profile_id, exc_info=True)
            got = None
        if not got or (not got.get("windows") and not got.get("details")):
            silent.setdefault(slug, set()).add(profile_id)
            continue
        key = repr((got.get("provider"), got.get("windows"), got.get("details")))
        merged.setdefault(key, {**got, "agents": []})["agents"].append(profile_id)
    out = list(merged.values())
    reported = {a["provider"] for a in out}
    for slug, agents in silent.items():
        if slug not in reported:
            out.append({"provider": slug, "agents": sorted(agents),
                        "unavailable_reason": "This provider doesn't report account spend to Hermes"})
    return out


class HermesAnalytics:
    """What ``analytics.Analytics`` reads from Hermes, for the agents under ``root``."""

    def __init__(self, home_of: Callable[[str], Path]) -> None:
        self._home_of = home_of

    def read_usage(self, profile_id: str, since: float) -> dict:
        return read_usage(self._home_of(profile_id), since)

    def accounts(self, pairs: list[tuple[str, str]]) -> list[dict]:
        return accounts(pairs, self._home_of)

    def configured_provider(self, profile_id: str) -> Optional[str]:
        """The provider an agent's config names for its model (``model.provider``)."""
        try:
            from hermes_cli.config import read_user_config_raw
            model = (read_user_config_raw(Path(self._home_of(profile_id)) / "config.yaml") or {}).get("model")
        except Exception:
            return None
        provider = model.get("provider") if isinstance(model, dict) else None
        return str(provider).strip().lower() if provider else None
