"""Hermes glue for Delegated cards (docs/delegation.md). Imports Hermes lazily: only runs inside it.

- Hermes' official hooks (``subagent_start``, ``post_tool_call``, ``subagent_stop``) feed
  ``delegation.Delegations`` on the gateway's event loop. ``post_tool_call`` also catches a
  ``kanban_create`` from a Lekora chat the moment it happens (the board check would find it a
  few seconds later anyway).
- ``HermesHelpers``: Hermes' running sub-agent list and its Stop.
Nothing is registered that changes what agents can do: these only watch.
"""

from __future__ import annotations

import asyncio
import json
import logging
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)

PLATFORM = "lekora"

Target = Callable[[], Optional[tuple[Any, asyncio.AbstractEventLoop]]]  # (Delegations, loop) or None


def _session_env(name: str) -> str:
    try:
        from gateway.session_context import get_session_env
        return get_session_env(name, "") or ""
    except Exception:
        return ""


def _lekora_chat() -> Optional[str]:
    if _session_env("HERMES_SESSION_PLATFORM") != PLATFORM:
        return None
    return _session_env("HERMES_SESSION_CHAT_ID") or None


class HermesHelpers:
    """Hermes' list of running sub-agents and its Stop."""

    @staticmethod
    def running() -> list[dict]:
        from tools.delegate_tool_registry import list_active_subagents
        return list_active_subagents()

    @staticmethod
    def interrupt(helper_id: str) -> bool:
        from tools.delegate_tool_registry import interrupt_subagent
        return interrupt_subagent(helper_id)


class Hooks:
    """Hermes' hook callbacks, run on Hermes' threads; each hands its event to the loop."""

    def __init__(self, target: Target) -> None:
        self._target = target

    def _run(self, call: Callable[[Any], Any]) -> None:
        target = self._target()
        if target is None or target[0] is None:
            return
        delegations, loop = target
        try:
            asyncio.run_coroutine_threadsafe(call(delegations), loop)
        except Exception:
            log.debug("Lekora: delegation event not delivered", exc_info=True)

    def subagent_start(self, **kw: Any) -> None:
        helper_id = str(kw.get("child_subagent_id") or "")
        if not helper_id:
            return
        chat_id = _lekora_chat()
        self._run(lambda d: d.started(
            chat_id=chat_id, turn=kw.get("parent_turn_id") or kw.get("parent_session_id"),
            helper_id=helper_id, goal=kw.get("child_goal"), parent_id=kw.get("parent_subagent_id") or None,
            session=kw.get("child_session_id")))

    def post_tool_call(self, **kw: Any) -> None:
        tool = kw.get("tool_name")
        task_id = str(kw.get("task_id") or "")
        if task_id.startswith("sa-"):
            self._run(lambda d: d.used_tool(task_id, tool))
            return
        if tool != "kanban_create":
            return
        chat_id = _lekora_chat()
        try:
            result = json.loads(kw.get("result") or "{}")
        except (TypeError, ValueError):
            return
        args = kw.get("args") or {}
        if not chat_id or not isinstance(result, dict) or not result.get("task_id"):
            return
        self._run(lambda d: d.handed_off(
            chat_id=chat_id, task_id=str(result["task_id"]), title=result.get("title") or args.get("title"),
            assignee=result.get("assignee") or args.get("assignee"), board=args.get("board") or None))

    def subagent_stop(self, **kw: Any) -> None:
        session = kw.get("child_session_id")
        if not session:
            return
        history = kw.get("tool_call_history")
        steps = len(history) if isinstance(history, list) else None
        self._run(lambda d: d.finished(
            session=str(session), status=kw.get("child_status"), summary=kw.get("child_summary"),
            duration_ms=kw.get("duration_ms"), steps=steps))


def register(ctx: Any, target: Target) -> None:
    """The hooks; each optional, so an older Hermes still loads Lekora."""
    hooks = Hooks(target)
    for name in ("subagent_start", "post_tool_call", "subagent_stop"):
        try:
            ctx.register_hook(name, getattr(hooks, name))
        except Exception:
            log.info("Lekora: this Hermes has no %s hook; Delegated cards will show less", name)
