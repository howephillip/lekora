"""Read a Lekora chat's current settings from Hermes (spec: docs/chat-settings.md).

Hermes internals (GatewayRunner methods and modules that are not an official plugin
API, checked against Hermes 0.22.5). Every value is read on its own: one that fails
(e.g. after a Hermes update) comes back as None and the phone shows it as unknown,
the rest still work. Runs in a thread: it reads config files and the session database.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)


def _try(label: str, fn: Callable[[], Any]) -> Any:
    try:
        return fn()
    except Exception as exc:
        log.debug("Lekora: couldn't read %s: %s", label, exc)
        return None


def read_settings(runner: Any, source: Any, profile_home: Path) -> dict:
    """The chat's settings: model, reasoning, fast, yolo (this chat); personality, approvals,
    show_reasoning (the agent); title and usage."""
    key = runner._session_key_for_source(source)
    cfg = _try("config", lambda: _profile_config(profile_home)) or {}

    model = _try("model", lambda: _model(runner, key, cfg))
    effort = _try("reasoning", lambda: _reasoning(runner, source, key, (model or {}).get("model", "")))
    state = _try("session state", lambda: runner._peek_session_state(key))
    usage = _try("usage", lambda: _usage(runner, key))
    db = _try("session record", lambda: _session_row(runner, key, profile_home)) or {}
    if usage is None and db:
        usage = {}
    if usage is not None and db:
        usage.update({k: db[k] for k in ("cost_usd", "input_tokens", "output_tokens") if db.get(k) is not None})

    return {
        "model": model,
        "reasoning": None if effort is None else {
            "effort": effort,
            "this_chat": bool(state is not None and state.conversation.reasoning_override is not None),
        },
        "show_reasoning": _try("show reasoning", lambda: _show_reasoning(cfg)),
        "fast": _try("fast mode", lambda: _fast(runner, key)),
        "yolo": _try("auto-approve", lambda: _yolo(runner, key)),
        "personality": _try("personality", lambda: _personality(cfg)),
        "approvals": _try("approval mode", lambda: str((cfg.get("approvals") or {}).get("mode") or "manual")),
        "title": db.get("title"),
        "usage": usage,
    }


def _profile_config(profile_home: Path) -> dict:
    from hermes_cli.config_effective import load_user_config_effective
    return load_user_config_effective(Path(profile_home) / "config.yaml") or {}


def _model(runner: Any, key: str, cfg: dict) -> Optional[dict]:
    override = runner._session_model_override(key)
    if isinstance(override, dict) and override.get("model"):
        return {"model": str(override["model"]), "provider": str(override.get("provider") or ""), "this_chat": True}
    model_cfg = cfg.get("model")
    if isinstance(model_cfg, dict):
        name = model_cfg.get("default") or model_cfg.get("model") or ""
        return {"model": str(name), "provider": str(model_cfg.get("provider") or ""), "this_chat": False}
    if isinstance(model_cfg, str):
        return {"model": model_cfg, "provider": "", "this_chat": False}
    return None


def _reasoning(runner: Any, source: Any, key: str, model: str) -> str:
    config = runner._resolve_session_reasoning_config(source=source, session_key=key, model=model)
    if not config:
        return "medium"  # Hermes' default
    if config.get("enabled") is False:
        return "none"
    return str(config.get("effort") or "medium")


def _show_reasoning(cfg: dict) -> bool:
    from gateway.display_config import resolve_display_setting
    return bool(resolve_display_setting(cfg, "lekora", "show_reasoning", False))


def _fast(runner: Any, key: str) -> str:
    from agent.fast_mode import service_tier_word
    return str(service_tier_word(runner._resolve_session_service_tier(session_key=key)))


def _yolo(runner: Any, key: str) -> bool:
    from tools.approval import is_session_yolo_enabled
    if is_session_yolo_enabled(key):
        return True
    entry = runner.session_store.lookup_by_session_key(key)
    return bool(entry is not None and getattr(entry, "yolo", None) is True)


def _personality(cfg: dict) -> dict:
    from hermes_cli.personality import active_personality_name, available_personalities, describe_personality
    options = [{"name": name, "description": describe_personality(prompt, width=80)}
               for name, prompt in sorted(available_personalities(cfg).items())]
    return {"current": active_personality_name(cfg) or "none", "options": options}


def _usage(runner: Any, key: str) -> Optional[dict]:
    agent = runner._resident_agent_for(key)
    if agent is None:
        return None
    from gateway.session_usage import usage_stats
    stats = usage_stats(agent)
    return {k: stats.get(k) for k in ("input_tokens", "output_tokens", "total_tokens", "context_tokens", "context_length")}


def _session_row(runner: Any, key: str, profile_home: Path) -> Optional[dict]:
    """Title and cost from Hermes' session database (read inside the agent's profile)."""
    entry = runner.session_store.lookup_by_session_key(key)
    session_id = getattr(entry, "session_id", None)
    if not session_id:
        return None
    from gateway.run import _gateway_session_db_inner, _profile_runtime_scope
    with _profile_runtime_scope(Path(profile_home), hydrate_secrets=False):
        db = _gateway_session_db_inner(runner)
        row = db.get_session(session_id) if db is not None else None
    if not row:
        return None
    cost = row.get("actual_cost_usd") or row.get("estimated_cost_usd")
    return {"title": row.get("title"), "cost_usd": float(cost) if cost is not None else None,
            "input_tokens": row.get("input_tokens"), "output_tokens": row.get("output_tokens")}
