"""Analytics: usage and spend across every agent (docs/analytics.md).

``read_usage(profile_id, since)`` gives one agent's usage rows from Hermes (``hermes_analytics.py``);
``accounts(pairs)`` gives what providers report. This module only adds them up. Nothing imports Hermes.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import time
from typing import Any, Awaitable, Callable, Iterable, Optional

PERIODS = (1, 7, 30)
BACKGROUND = "background"
ACCOUNT_CACHE_SECONDS = 300

# One agent's usage since a time: {"main": [{day, source, sessions, cost_usd, tokens}],
# "background": [{day, cost_usd, tokens}], "models": [{model, provider, cost_usd, tokens}]}
ReadUsage = Callable[[str, float], dict]
# [(profile id, provider)] -> [account dict with "provider" and "agents"]
Accounts = Callable[[list[tuple[str, str]]], list[dict]]


class AnalyticsError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def _num(value: Any) -> float:
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _add(into: dict, key: Any, cost: Any, tokens: Any, sessions: Any = 0) -> None:
    row = into.setdefault(key, {"cost_usd": 0.0, "tokens": 0, "sessions": 0})
    row["cost_usd"] += _num(cost)
    row["tokens"] += int(_num(tokens))
    row["sessions"] += int(_num(sessions))


def _rounded(rows: dict, name: str, keep_sessions: bool = False) -> list[dict]:
    out = []
    for key, row in rows.items():
        item = {name: key, "cost_usd": round(row["cost_usd"], 6), "tokens": row["tokens"]}
        if keep_sessions:
            item["sessions"] = row["sessions"]
        out.append(item)
    return sorted(out, key=lambda r: (-r["cost_usd"], -r["tokens"], str(r[name])))


class Analytics:
    def __init__(self, profiles: Callable[[], Iterable[str]], read_usage: ReadUsage,
                 accounts: Optional[Accounts] = None, configured_provider: Callable[[str], Optional[str]] = lambda p: None,
                 clock: Callable[[], float] = time.time) -> None:
        self._profiles = profiles
        self._read_usage = read_usage
        self._accounts = accounts
        self._configured_provider = configured_provider
        self._clock = clock
        self._account_cache: tuple[float, tuple, list[dict]] = (0.0, (), [])

    def since(self, days: int) -> float:
        """Local midnight ``days - 1`` days ago: Today is since this midnight."""
        now = dt.datetime.fromtimestamp(self._clock())
        start = now.replace(hour=0, minute=0, second=0, microsecond=0) - dt.timedelta(days=days - 1)
        return start.timestamp()

    async def get(self, days: Any, profile_id: Any = None) -> dict:
        if days not in PERIODS:
            raise AnalyticsError("INVALID_REQUEST", "Days must be 1, 7 or 30")
        profiles = list(self._profiles())
        if profile_id is not None:
            if profile_id not in profiles:
                raise AnalyticsError("UNKNOWN_PROFILE", "Unknown agent")
            profiles = [profile_id]
        since = self.since(days)
        usage = await asyncio.gather(*(asyncio.to_thread(self._safe_read, p, since) for p in profiles))
        daily: dict = {}
        agents: dict = {}
        models: dict = {}
        sources: dict = {}
        totals: dict = {}
        pairs: list[tuple[str, str]] = []
        for profile, rows in zip(profiles, usage):
            for r in rows.get("main") or []:
                _add(daily, r.get("day"), r.get("cost_usd"), r.get("tokens"))
                _add(agents, profile, r.get("cost_usd"), r.get("tokens"), r.get("sessions"))
                _add(sources, r.get("source") or "other", r.get("cost_usd"), r.get("tokens"))
                _add(totals, "all", r.get("cost_usd"), r.get("tokens"), r.get("sessions"))
            for r in rows.get("background") or []:
                _add(daily, r.get("day"), r.get("cost_usd"), r.get("tokens"))
                _add(agents, profile, r.get("cost_usd"), r.get("tokens"))
                _add(sources, BACKGROUND, r.get("cost_usd"), r.get("tokens"))
                _add(totals, "all", r.get("cost_usd"), r.get("tokens"))
            for r in rows.get("models") or []:
                _add(models, r.get("model") or "unknown", r.get("cost_usd"), r.get("tokens"))
                if r.get("provider"):
                    pairs.append((profile, str(r["provider"])))
            configured = self._configured_provider(profile)
            if configured:
                pairs.append((profile, configured))
        for profile in profiles:
            agents.setdefault(profile, {"cost_usd": 0.0, "tokens": 0, "sessions": 0})
        total = totals.get("all", {"cost_usd": 0.0, "tokens": 0, "sessions": 0})
        return {
            "days": days, "since": dt.date.fromtimestamp(since).isoformat(),
            "totals": {"cost_usd": round(total["cost_usd"], 6), "tokens": total["tokens"], "sessions": total["sessions"]},
            "daily": self._days(daily, since, days),
            "by_agent": [{"profile_id": r["key"], **{k: v for k, v in r.items() if k != "key"}}
                         for r in _rounded(agents, "key", keep_sessions=True)],
            "by_model": _rounded(models, "model"),
            "by_source": _rounded(sources, "source"),
            "estimated": True,
            "accounts": await self._account_list(sorted(set(pairs))),
        }

    def _safe_read(self, profile_id: str, since: float) -> dict:
        try:
            return self._read_usage(profile_id, since) or {}
        except Exception:
            return {}

    @staticmethod
    def _days(daily: dict, since: float, days: int) -> list[dict]:
        """Every day of the period, empty ones too, oldest first."""
        first = dt.date.fromtimestamp(since)
        out = []
        for i in range(days):
            day = (first + dt.timedelta(days=i)).isoformat()
            row = daily.get(day, {"cost_usd": 0.0, "tokens": 0})
            out.append({"day": day, "cost_usd": round(row["cost_usd"], 6), "tokens": row["tokens"]})
        return out

    async def _account_list(self, pairs: list[tuple[str, str]]) -> list[dict]:
        if self._accounts is None or not pairs:
            return []
        at, key, cached = self._account_cache
        if key == tuple(pairs) and self._clock() - at < ACCOUNT_CACHE_SECONDS:
            return cached
        try:
            got = await asyncio.to_thread(self._accounts, pairs)
        except Exception:
            got = []
        self._account_cache = (self._clock(), tuple(pairs), got)
        return got
