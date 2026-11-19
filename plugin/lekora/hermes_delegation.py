"""Hermes glue for Helpers (docs/delegation.md). Imports Hermes lazily: only runs inside it.

- Hermes' official hooks (``subagent_start``, ``post_tool_call``, ``subagent_stop``) feed
  ``delegation.Delegations`` on the gateway's event loop.
- ``HermesHelpers``: Hermes' running-helper list and its Stop.
- ``LekoraDelegationProvider`` + ``lekora_ask_agent``: an agent hands a task to another agent,
  which runs as itself (Hermes' profile routes) and reports back (owner, 2026-11-19).
"""

from __future__ import annotations

import asyncio
import contextvars
import json
import logging
import threading
from typing import Any, Callable, Mapping, Optional

log = logging.getLogger(__name__)

PLATFORM = "lekora"
BACKEND = "lekora"
ASK_TOOL = "lekora_ask_agent"

# Which agent ``lekora_ask_agent`` is asking, for the subagent_start hook on the same thread.
_ASKING: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar("lekora_asking", default=None)
_switch_lock = threading.Lock()
_switched: dict[str, list] = {}  # session key -> [backend before, asks in progress]

Target = Callable[[], Optional[tuple[Any, asyncio.AbstractEventLoop]]]  # (Delegations, loop) or None


def _session_env(name: str) -> str:
    try:
        from gateway.session_context import get_session_env
        return get_session_env(name, "") or ""
    except Exception:
        return ""


class HermesHelpers:
    """Hermes' list of running helpers and its Stop."""

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
            log.debug("Lekora: helper event not delivered", exc_info=True)

    def subagent_start(self, **kw: Any) -> None:
        chat_id = _session_env("HERMES_SESSION_CHAT_ID") if _session_env("HERMES_SESSION_PLATFORM") == PLATFORM else ""
        helper_id = str(kw.get("child_subagent_id") or "")
        if not helper_id:
            return
        agent = _ASKING.get()
        self._run(lambda d: d.started(
            chat_id=chat_id or None, turn=kw.get("parent_turn_id") or kw.get("parent_session_id"),
            helper_id=helper_id, goal=kw.get("child_goal"), parent_id=kw.get("parent_subagent_id") or None,
            agent=agent, session=kw.get("child_session_id")))

    def post_tool_call(self, **kw: Any) -> None:
        helper_id = str(kw.get("task_id") or "")
        if not helper_id.startswith("sa-"):
            return  # not a helper's tool
        tool = kw.get("tool_name")
        self._run(lambda d: d.used_tool(helper_id, tool))

    def subagent_stop(self, **kw: Any) -> None:
        session = kw.get("child_session_id")
        if not session:
            return
        history = kw.get("tool_call_history")
        steps = len(history) if isinstance(history, list) else None
        self._run(lambda d: d.finished(
            session=str(session), status=kw.get("child_status"), summary=kw.get("child_summary"),
            duration_ms=kw.get("duration_ms"), steps=steps))


# ---- asking another agent -----------------------------------------------------

def make_provider(profiles: Callable[[], list[str]]):
    """Lekora's delegation backend: a task naming ``agent`` runs as that Hermes profile;
    anything else takes the ``delegation`` section's own route, as Hermes' default does."""
    from agent.delegation_provider import DelegationProvider, DelegationRouteError

    class LekoraDelegationProvider(DelegationProvider):
        @property
        def name(self) -> str:
            return BACKEND

        @property
        def display_name(self) -> str:
            return "Lekora"

        @property
        def summary(self) -> str:
            return "Used by Lekora's ask-another-agent tool: the task runs as the agent it names."

        def task_parameters(self, config: Mapping[str, Any]) -> dict[str, dict[str, Any]]:
            return {"agent": {"type": "string", "description": "The Hermes profile that does this task."}}

        def route_task(self, task: Mapping[str, Any], config: Mapping[str, Any]) -> dict[str, Any]:
            agent = task.get("agent")
            if not agent:
                return {k: v for k, v in config.items() if k != "service_tier"}
            if agent not in profiles():
                raise DelegationRouteError(f"There is no agent called {agent!r}.")
            return {"profile": agent, "label": agent}

    return LekoraDelegationProvider()


ASK_SCHEMA = {
    "name": ASK_TOOL,
    "description": (
        "Ask another of the user's agents (another Hermes profile) to do a task. It works in the "
        "background as itself, with its own personality, model, tools and settings, and its answer "
        "comes back to you as a new message when it is done. The user watches it live. Use it when "
        "another agent is better suited (e.g. a specialist); for help of your own kind, use delegate_task. "
        "Unsure of the names? Call it with any name: the reply lists the other agents."),
    "parameters": {
        "type": "object",
        "properties": {
            "agent": {"type": "string", "description": "The other agent's name (its Hermes profile name)."},
            "task": {"type": "string", "description": "What it should do, complete and self-contained."},
            "context": {"type": "string", "description": "Anything it needs to know: it can't see this chat."},
        },
        "required": ["agent", "task"],
    },
}


def _error(text: str) -> str:
    return json.dumps({"success": False, "error": text})


def ask_agent(args: Mapping[str, Any], *, profiles: Callable[[], list[str]]) -> str:
    """``lekora_ask_agent``: Hermes' own ``delegate_task`` with this session switched to Lekora's
    backend for the one call (in memory; nothing written)."""
    agent = str(args.get("agent") or "").strip()
    task = str(args.get("task") or "").strip()
    context = str(args.get("context") or "").strip() or None
    own = _session_env("HERMES_SESSION_CHAT_ID")
    others = [p for p in profiles() if p != own]
    if not task:
        return _error("Say what the other agent should do (task).")
    if agent == own:
        return _error("That's you. To get help of your own kind, use delegate_task.")
    if agent not in others:
        names = ", ".join(others) or "none"
        return _error(f"There is no other agent called {agent!r}. Other agents: {names}.")
    from agent.subagent_lifecycle import get_active_subagent_parent
    parent = get_active_subagent_parent()
    if parent is None:
        return _error("Asking another agent only works inside a chat turn.")
    from agent.delegation_backends import _current_session_key, get_session_backend, set_session_backend
    from tools.delegate_tool import delegate_task
    key = _current_session_key(parent)
    token = _ASKING.set(agent)
    try:
        # Only this session, only while asking: switching backends is per session and in memory.
        with _switch_lock:
            held = _switched.setdefault(key, [get_session_backend(key), 0])
            held[1] += 1
            set_session_backend(key, BACKEND)
        try:
            return delegate_task(
                tasks=[{"goal": task, "context": context, "agent": agent}], parent_agent=parent,
                background=not (getattr(parent, "_delegate_depth", 0) > 0))
        finally:
            with _switch_lock:
                held[1] -= 1
                if held[1] <= 0:
                    _switched.pop(key, None)
                    set_session_backend(key, held[0])
    except ValueError as exc:
        return _error(str(exc))
    finally:
        _ASKING.reset(token)


def register(ctx: Any, target: Target, profiles: Callable[[], list[str]], check: Callable[[], bool]) -> None:
    """Hooks, the backend and the tool; each one optional, so an older Hermes still loads Lekora."""
    hooks = Hooks(target)
    for name in ("subagent_start", "post_tool_call", "subagent_stop"):
        try:
            ctx.register_hook(name, getattr(hooks, name))
        except Exception:
            log.info("Lekora: this Hermes has no %s hook; Helpers cards will be less detailed", name)
    try:
        ctx.register_delegation_provider(make_provider(profiles))
    except Exception:
        log.info("Lekora: this Hermes can't run a task as another agent; %s is unavailable", ASK_TOOL)
        return
    ctx.register_tool(name=ASK_TOOL, toolset="lekora", schema=ASK_SCHEMA,
                      handler=lambda args, **_kw: ask_agent(args or {}, profiles=profiles),
                      check_fn=check, description=ASK_SCHEMA["description"], emoji="🤝")
