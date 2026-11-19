"""Helpers (Hermes subagents) shown as a live tree in the chat (docs/delegation.md).

Hermes' hooks arrive here as plain calls (``started``, ``used_tool``, ``finished``, ``running``);
each reply that used helpers becomes one saved Helpers card, updated in place at most once a
second. Nothing here imports Hermes: ``hermes_delegation.py`` is the glue.
"""

from __future__ import annotations

import asyncio
import datetime
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Optional

log = logging.getLogger(__name__)

WORKING, FINISHING = "working", "finishing"
DONE, FAILED, STOPPED, TIMED_OUT = "done", "failed", "stopped", "timed_out"
ENDED = {DONE, FAILED, STOPPED, TIMED_OUT}

# Hermes' result statuses → the card's endings.
_ENDINGS = {"completed": DONE, "success": DONE, "failed": FAILED, "error": FAILED,
            "interrupted": STOPPED, "cancelled": STOPPED, "timeout": TIMED_OUT}

SUMMARY_LIMIT = 4000
GOAL_LIMIT = 2000
ROLE = "helpers"

Publish = Callable[[str, str, dict], Awaitable[int]]  # (profile_id, text, delegation) -> seq
Update = Callable[[int, str, dict], Awaitable[None]]  # (seq, text, delegation)
Interrupt = Callable[[str], bool]  # helper id -> stopped?


def _iso(ts: float) -> str:
    return datetime.datetime.fromtimestamp(ts, datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _clip(value: Any, limit: int) -> str:
    text = str(value or "").strip()
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def doing_text(tool: Any) -> Optional[str]:
    """A tool name as the user reads it: ``web_search`` → ``Web search``."""
    name = str(tool or "").strip()
    if not name:
        return None
    if name.startswith("mcp_"):
        name = name[4:]
    words = name.replace("_", " ").replace("-", " ").strip()
    return words[:1].upper() + words[1:] if words else None


@dataclass
class Helper:
    id: str
    goal: str
    started: float
    parent: Optional[str] = None
    agent: Optional[str] = None
    session: Optional[str] = None
    status: str = WORKING
    doing: Optional[str] = None
    steps: int = 0
    ended: Optional[float] = None
    summary: Optional[str] = None
    seen: bool = False  # in Hermes' running list at least once (a queued helper isn't yet)

    def wire(self) -> dict:
        out: dict[str, Any] = {"id": self.id, "goal": self.goal, "status": self.status,
                               "steps": self.steps, "started_at": _iso(self.started)}
        if self.parent:
            out["parent"] = self.parent
        if self.agent:
            out["agent"] = self.agent
        if self.doing and self.status in (WORKING, FINISHING):
            out["doing"] = self.doing
        if self.ended is not None:
            out["ended_at"] = _iso(self.ended)
        if self.summary:
            out["summary"] = self.summary
        return out


@dataclass
class Tree:
    chat_id: str
    turn: str
    helpers: list[Helper] = field(default_factory=list)
    seq: Optional[int] = None
    dirty: bool = False

    @property
    def working(self) -> bool:
        return any(h.status not in ENDED for h in self.helpers)

    def wire(self) -> dict:
        return {"status": WORKING if self.working else DONE, "helpers": [h.wire() for h in self.helpers]}

    def text(self) -> str:
        """One line for anything that can't draw the card."""
        n = len(self.helpers)
        busy = sum(1 for h in self.helpers if h.status not in ENDED)
        noun = "helper" if n == 1 else "helpers"
        return f"Using {n} {noun} ({busy} working)" if busy else f"Used {n} {noun}"


class Delegations:
    """Every Helpers card the plugin is keeping up to date. Runs on the gateway's event loop."""

    def __init__(self, store: Any, publish: Publish, update: Update, *,
                 interrupt: Optional[Interrupt] = None, clock: Callable[[], float] = time.time,
                 every: float = 1.0) -> None:
        self._store = store
        self._publish = publish
        self._update = update
        self._interrupt = interrupt
        self._clock = clock
        self._every = every
        self._trees: dict[tuple[str, str], Tree] = {}
        self._helper_tree: dict[str, Tree] = {}
        self._session_helper: dict[str, str] = {}
        self._flush_task: Optional[asyncio.Task] = None

    # ---- Hermes' events -----------------------------------------------------

    async def started(self, *, chat_id: Optional[str], turn: Any, helper_id: str, goal: Any,
                      parent_id: Optional[str] = None, agent: Optional[str] = None,
                      session: Optional[str] = None) -> None:
        if not helper_id or helper_id in self._helper_tree:
            return
        tree = self._helper_tree.get(parent_id) if parent_id else None
        if tree is None:
            if not chat_id:
                return  # not started from a Lekora chat
            key = (chat_id, str(turn or ""))
            tree = self._trees.get(key)
            if tree is None:
                tree = Tree(chat_id, key[1])
                self._trees[key] = tree
        helper = Helper(helper_id, _clip(goal, GOAL_LIMIT) or "A task", self._clock(),
                        parent=parent_id if parent_id in self._helper_tree else None,
                        agent=agent or None, session=session or None)
        tree.helpers.append(helper)
        self._helper_tree[helper_id] = tree
        if session:
            self._session_helper[session] = helper_id
        if tree.seq is None:
            tree.seq = await self._publish(tree.chat_id, tree.text(), tree.wire())
        else:
            await self._changed(tree, now=True)

    async def used_tool(self, helper_id: Any, tool: Any) -> None:
        helper, tree = self._find(helper_id)
        if helper is None or helper.status in ENDED:
            return
        helper.steps += 1
        helper.doing = doing_text(tool) or helper.doing
        await self._changed(tree)

    async def finished(self, *, session: Optional[str] = None, helper_id: Optional[str] = None,
                       status: Any = None, summary: Any = None, duration_ms: Any = None,
                       steps: Optional[int] = None) -> None:
        helper_id = helper_id or self._session_helper.get(session or "")
        helper, tree = self._find(helper_id)
        if helper is None:
            return
        helper.status = _ENDINGS.get(str(status or "").lower(), FAILED if status else DONE)
        if helper.ended is None:
            try:
                helper.ended = helper.started + float(duration_ms) / 1000.0 if duration_ms else self._clock()
            except (TypeError, ValueError):
                helper.ended = self._clock()
        if summary:
            helper.summary = _clip(summary, SUMMARY_LIMIT)
        if isinstance(steps, int) and steps > helper.steps:
            helper.steps = steps
        await self._changed(tree, now=True)

    async def running(self, snapshot: list[dict]) -> None:
        """Hermes' list of running helpers: what each is doing now; one that left it is finishing."""
        live = {str(r.get("subagent_id")): r for r in snapshot or [] if r.get("subagent_id")}
        for tree in {id(t): t for t in self._trees.values() if t.working}.values():
            changed = False
            for helper in tree.helpers:
                if helper.status in ENDED:
                    continue
                row = live.get(helper.id)
                if row is None:
                    if helper.status == WORKING and helper.seen:
                        helper.status, changed = FINISHING, True
                    continue
                helper.seen = True
                count = row.get("tool_count")
                if isinstance(count, int) and count > helper.steps:
                    helper.steps, changed = count, True
                doing = doing_text(row.get("last_tool"))
                if doing and doing != helper.doing:
                    helper.doing, changed = doing, True
            if changed:
                await self._changed(tree)

    @property
    def any_working(self) -> bool:
        return any(t.working for t in self._trees.values())

    # ---- the phone's Stop ---------------------------------------------------

    async def stop(self, seq: int, helper_id: Optional[str] = None) -> list[str]:
        tree = next((t for t in self._trees.values() if t.seq == seq), None)
        if tree is None:
            raise KeyError(seq)
        if self._interrupt is None:
            raise RuntimeError("UNAVAILABLE")
        targets = [h for h in tree.helpers if h.status in (WORKING, FINISHING)
                   and (helper_id is None or h.id == helper_id)]
        stopped = []
        for helper in targets:
            try:
                ok = await asyncio.to_thread(self._interrupt, helper.id)
            except Exception:
                log.debug("Lekora: stopping helper %s failed", helper.id, exc_info=True)
                ok = False
            if ok:
                stopped.append(helper.id)
                helper.doing = "Stopping"
        if stopped:
            await self._changed(tree, now=True)
        return stopped

    # ---- restarts -----------------------------------------------------------

    async def close_leftovers(self) -> int:
        """Cards still working when the plugin stopped: their helpers are gone (docs/delegation.md)."""
        closed = 0
        for ev in self._store.working_helper_cards():
            card = dict(ev.payload.get("delegation") or {})
            now = _iso(self._clock())
            helpers = []
            for h in card.get("helpers") or []:
                h = dict(h)
                if h.get("status") not in ENDED:
                    h["status"] = STOPPED
                    h.pop("doing", None)
                    h.setdefault("ended_at", now)
                helpers.append(h)
            card.update(status=DONE, helpers=helpers)
            n = len(helpers)
            await self._update(ev.seq, f"Used {n} {'helper' if n == 1 else 'helpers'}", card)
            closed += 1
        return closed

    # ---- internals ----------------------------------------------------------

    def _find(self, helper_id: Any) -> tuple[Optional[Helper], Optional[Tree]]:
        tree = self._helper_tree.get(str(helper_id or ""))
        if tree is None:
            return None, None
        return next((h for h in tree.helpers if h.id == helper_id), None), tree

    async def _changed(self, tree: Tree, now: bool = False) -> None:
        tree.dirty = True
        if now or self._every <= 0:
            await self._send(tree)
        elif self._flush_task is None or self._flush_task.done():
            self._flush_task = asyncio.ensure_future(self._flush_later())

    async def _flush_later(self) -> None:
        await asyncio.sleep(self._every)
        for tree in list({id(t): t for t in self._trees.values()}.values()):
            if tree.dirty:
                await self._send(tree)

    async def _send(self, tree: Tree) -> None:
        if tree.seq is None:
            return
        tree.dirty = False
        try:
            await self._update(tree.seq, tree.text(), tree.wire())
        except Exception:
            log.exception("Lekora: Helpers card update failed")
        if not tree.working:
            self._forget(tree)

    def _forget(self, tree: Tree) -> None:
        """A finished tree is saved; keep only what a late event could still need for a while."""
        for key, other in list(self._trees.items()):
            if other is tree:
                del self._trees[key]
        for h in tree.helpers:
            self._helper_tree.pop(h.id, None)
            if h.session:
                self._session_helper.pop(h.session, None)
