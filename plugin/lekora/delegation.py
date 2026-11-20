"""Delegation shown as a live tree in the chat (docs/delegation.md).

Two kinds of delegated work, one card:
- **Board handoffs**: an agent gives a task to another agent on Hermes' board (``kanban_create``
  with an assignee). Seen on the board itself: a new task whose origin is a Lekora chat is shown in
  that chat; a task created by a delegated task's worker is shown under it.
- **Sub-agents**: Hermes' ``delegate_task`` copies of the agent, from Hermes' hooks.

The card only watches. Nothing waits on it: the chat stays free, and results reach the agent the
way Hermes already delivers them. Nothing here imports Hermes (``hermes_delegation.py`` is the glue).
"""

from __future__ import annotations

import asyncio
import datetime
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Optional

log = logging.getLogger(__name__)

WAITING, WORKING, FINISHING, BLOCKED = "waiting", "working", "finishing", "blocked"
DONE, FAILED, STOPPED, TIMED_OUT = "done", "failed", "stopped", "timed_out"
ENDED = {DONE, FAILED, STOPPED, TIMED_OUT}

# Hermes' sub-agent result statuses → the card's endings.
_ENDINGS = {"completed": DONE, "success": DONE, "failed": FAILED, "error": FAILED,
            "interrupted": STOPPED, "cancelled": STOPPED, "timeout": TIMED_OUT}
# Board columns → the card's states.
_BOARD = {"triage": WAITING, "todo": WAITING, "scheduled": WAITING, "ready": WAITING,
          "running": WORKING, "review": WORKING, "blocked": BLOCKED, "done": DONE, "archived": STOPPED}

SUMMARY_LIMIT = 4000
GOAL_LIMIT = 2000
ROLE = "delegation"
JOIN_SECONDS = 120  # handoffs this close together from one chat share a card

Publish = Callable[[str, str, dict], Awaitable[int]]  # (profile_id, text, delegation) -> seq
Update = Callable[[int, str, dict], Awaitable[None]]  # (seq, text, delegation)
Interrupt = Callable[[str], bool]  # sub-agent id -> stopped?
ChatFor = Callable[[Optional[str], Optional[str]], Optional[str]]  # (session id, created by) -> chat


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
    agent: Optional[str] = None      # who does it (the assignee); None = a sub-agent copy
    task: Optional[str] = None       # the board task (board handoffs)
    board: Optional[str] = None
    session: Optional[str] = None
    status: str = WORKING
    doing: Optional[str] = None
    steps: int = 0
    ended: Optional[float] = None
    summary: Optional[str] = None
    seen: bool = False  # sub-agents: in Hermes' running list at least once

    def wire(self) -> dict:
        out: dict[str, Any] = {"id": self.id, "goal": self.goal, "status": self.status,
                               "steps": self.steps, "started_at": _iso(self.started)}
        for key in ("parent", "agent", "task", "board", "summary"):
            if getattr(self, key):
                out[key] = getattr(self, key)
        if self.doing and self.status not in ENDED:
            out["doing"] = self.doing
        if self.ended is not None:
            out["ended_at"] = _iso(self.ended)
        return out

    @classmethod
    def from_wire(cls, h: dict, clock: float) -> "Helper":
        def ts(value: Any) -> Optional[float]:
            try:
                return datetime.datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
            except ValueError:
                return None
        return cls(id=h["id"], goal=h.get("goal") or "", started=ts(h.get("started_at")) or clock,
                   parent=h.get("parent"), agent=h.get("agent"), task=h.get("task"), board=h.get("board"),
                   status=h.get("status") or WORKING, doing=h.get("doing"), steps=int(h.get("steps") or 0),
                   ended=ts(h.get("ended_at")) if h.get("ended_at") else None, summary=h.get("summary"))


@dataclass
class Tree:
    chat_id: str
    turn: str
    helpers: list[Helper] = field(default_factory=list)
    seq: Optional[int] = None
    dirty: bool = False
    last_added: float = 0.0

    @property
    def working(self) -> bool:
        return any(h.status not in ENDED for h in self.helpers)

    def wire(self) -> dict:
        return {"status": WORKING if self.working else DONE, "helpers": [h.wire() for h in self.helpers]}

    def text(self) -> str:
        """One line for anything that can't draw the card."""
        names = []
        for h in self.helpers:
            name = h.agent or "a sub-agent"
            if name not in names:
                names.append(name)
        busy = sum(1 for h in self.helpers if h.status not in ENDED)
        n = len(self.helpers)
        head = f"Delegated {n} {'task' if n == 1 else 'tasks'} to {', '.join(names)}"
        return f"{head} ({busy} open)" if busy else head


class Delegations:
    """Every Delegated card the plugin is keeping up to date. Runs on the gateway's event loop."""

    def __init__(self, store: Any, publish: Publish, update: Update, *,
                 interrupt: Optional[Interrupt] = None, boards: Any = None, chat_for: Optional[ChatFor] = None,
                 clock: Callable[[], float] = time.time, every: float = 1.0) -> None:
        self._store = store
        self._publish = publish
        self._update = update
        self._interrupt = interrupt
        self._boards = boards        # HermesBoards: follow / created_since / stop / boards
        self._chat_for = chat_for or (lambda session, created_by: None)
        self._clock = clock
        self._every = every
        self._trees: dict[tuple[str, str], Tree] = {}
        self._helper_tree: dict[str, Tree] = {}
        self._session_helper: dict[str, str] = {}
        self._cursors: dict[str, int] = {}
        self._flush_task: Optional[asyncio.Task] = None

    # ---- board handoffs ------------------------------------------------------

    async def handed_off(self, *, chat_id: Optional[str], task_id: str, title: Any, assignee: Any,
                         board: Optional[str] = None, parent_task: Optional[str] = None,
                         turn: Any = None) -> None:
        """A task given to an agent on the board: from a Lekora chat, or by a delegated task."""
        if not task_id or task_id in self._helper_tree:
            return
        parent = parent_task if parent_task in self._helper_tree else None
        tree = self._helper_tree.get(parent) if parent else self._tree_for(chat_id, turn)
        if tree is None:
            return
        helper = Helper(task_id, _clip(title, GOAL_LIMIT) or "A task", self._clock(), parent=parent,
                        agent=str(assignee) if assignee else None, task=task_id, board=board, status=WAITING)
        await self._add(tree, helper)

    async def board_tick(self) -> None:
        """New handoffs and where the followed ones are now, from the board itself."""
        if self._boards is None:
            return
        try:
            slugs = [b["slug"] for b in await asyncio.to_thread(self._boards.boards)] or ["default"]
        except Exception:
            log.debug("Lekora: boards unreadable", exc_info=True)
            return
        try:
            current = await asyncio.to_thread(self._boards.resolve, None)
        except Exception:
            current = slugs[0]
        for tree in self._open_trees():
            for h in tree.helpers:
                if h.task and not h.board:
                    h.board = current  # a handoff seen by the hook names no board: it's the current one
        for slug in slugs:
            after = self._cursors.get(slug)
            top, created = await asyncio.to_thread(self._boards.created_since, slug, after)
            self._cursors[slug] = top
            new: list[tuple[dict, Optional[str], Optional[str]]] = []  # (row, chat, parent task)
            for row in created:
                creator = row.get("creator_task_id")
                if creator and creator in self._helper_tree:
                    new.append((row, None, creator))
                elif not creator:
                    chat = self._chat_for(row.get("session_id"), row.get("created_by"))
                    if chat:
                        new.append((row, chat, None))
            if new:
                info = {r["id"]: r for r in await asyncio.to_thread(
                    self._boards.follow, slug, [row["id"] for row, _, _ in new])}
                for row, chat, parent in new:
                    now = info.get(row["id"], {})
                    await self.handed_off(chat_id=chat, task_id=row["id"], title=now.get("title"),
                                          assignee=now.get("assignee"), board=slug, parent_task=parent)
            followed = [h for t in self._open_trees() for h in t.helpers
                        if h.task and h.board == slug and h.status not in ENDED]
            if not followed:
                continue
            now = await asyncio.to_thread(self._boards.follow, slug, [h.task for h in followed])
            by_id = {row["id"]: row for row in now}
            for helper in followed:
                row = by_id.get(helper.task)
                if row and self._apply_board(helper, row):
                    await self._changed(self._helper_tree[helper.id], now=helper.status in ENDED)

    def _apply_board(self, helper: Helper, row: dict) -> bool:
        before = (helper.status, helper.doing, helper.summary, helper.agent, helper.goal)
        helper.status = _BOARD.get(str(row.get("status") or ""), WORKING)
        if row.get("title"):
            helper.goal = _clip(row["title"], GOAL_LIMIT)
        if row.get("assignee"):
            helper.agent = str(row["assignee"])
        doing = row.get("doing")
        if helper.status == BLOCKED and row.get("error") and not doing:
            doing = row["error"]
        helper.doing = doing or helper.doing
        if row.get("summary"):
            helper.summary = _clip(row["summary"], SUMMARY_LIMIT)
        if row.get("created_at") and not helper.seen:
            helper.started, helper.seen = float(row["created_at"]), True
        if helper.status in ENDED:
            helper.ended = float(row.get("completed_at") or 0) or helper.ended or self._clock()
        return (helper.status, helper.doing, helper.summary, helper.agent, helper.goal) != before

    # ---- sub-agents (Hermes' hooks) --------------------------------------------

    async def started(self, *, chat_id: Optional[str], turn: Any, helper_id: str, goal: Any,
                      parent_id: Optional[str] = None, session: Optional[str] = None) -> None:
        if not helper_id or helper_id in self._helper_tree:
            return
        tree = self._helper_tree.get(parent_id) if parent_id else None
        if tree is None:
            tree = self._tree_for(chat_id, turn)
        if tree is None:
            return
        helper = Helper(helper_id, _clip(goal, GOAL_LIMIT) or "A task", self._clock(),
                        parent=parent_id if parent_id in self._helper_tree else None, session=session or None)
        if session:
            self._session_helper[session] = helper_id
        await self._add(tree, helper)

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
        """Hermes' list of running sub-agents: what each is doing now; one that left it is finishing."""
        live = {str(r.get("subagent_id")): r for r in snapshot or [] if r.get("subagent_id")}
        for tree in self._open_trees():
            changed = False
            for helper in tree.helpers:
                if helper.task or helper.status in ENDED:
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
        tree = next((t for t in self._open_trees() if t.seq == seq), None)
        if tree is None:
            raise KeyError(seq)
        targets = [h for h in tree.helpers if h.status in (WORKING, FINISHING, WAITING)
                   and (helper_id is None or h.id == helper_id)]
        stopped = []
        for helper in targets:
            try:
                ok = await asyncio.to_thread(self._stop_one, helper)
            except Exception:
                log.debug("Lekora: stopping %s failed", helper.id, exc_info=True)
                ok = False
            if ok:
                stopped.append(helper.id)
                helper.doing = "Stopping"
        if helper_id is not None and not targets:
            raise KeyError(seq)
        if stopped:
            await self._changed(tree, now=True)
        return stopped

    def _stop_one(self, helper: Helper) -> bool:
        if helper.task:
            if self._boards is None or helper.status != WORKING:
                return False  # only a running task has a worker to stop
            self._boards.stop(helper.board or self._boards.resolve(None), helper.task)
            return True
        if self._interrupt is None:
            raise RuntimeError("UNAVAILABLE")
        return bool(self._interrupt(helper.id))

    # ---- restarts -----------------------------------------------------------

    async def resume(self) -> int:
        """Cards still open when the plugin stopped: sub-agents are gone (stopped); board tasks
        live on in Hermes, so they're followed again (docs/delegation.md)."""
        kept = 0
        for ev in self._store.working_helper_cards():
            card = ev.payload.get("delegation") or {}
            tree = Tree(ev.profile_id, f"resumed-{ev.seq}", seq=ev.seq)
            for h in card.get("helpers") or []:
                helper = Helper.from_wire(h, self._clock())
                if not helper.task and helper.status not in ENDED:
                    helper.status, helper.doing = STOPPED, None
                    helper.ended = helper.ended or self._clock()
                tree.helpers.append(helper)
                self._helper_tree[helper.id] = tree
            self._trees[(tree.chat_id, tree.turn)] = tree
            await self._send(tree)
            kept += 1
        return kept

    # ---- internals ----------------------------------------------------------

    def _open_trees(self) -> list[Tree]:
        return list({id(t): t for t in self._trees.values() if t.working}.values())

    def _tree_for(self, chat_id: Optional[str], turn: Any) -> Optional[Tree]:
        if not chat_id:
            return None  # not from a Lekora chat
        if turn:
            tree = self._trees.get((chat_id, str(turn)))
        else:
            # Found on the board (no turn): join this chat's newest open card if it's recent.
            recent = [t for t in self._open_trees()
                      if t.chat_id == chat_id and self._clock() - t.last_added < JOIN_SECONDS]
            tree = recent[-1] if recent else None
        if tree is None:
            tree = Tree(chat_id, str(turn or f"board-{self._clock()}"))
            self._trees[(chat_id, tree.turn)] = tree
        return tree

    async def _add(self, tree: Tree, helper: Helper) -> None:
        tree.helpers.append(helper)
        tree.last_added = self._clock()
        self._helper_tree[helper.id] = tree
        if tree.seq is None:
            tree.seq = await self._publish(tree.chat_id, tree.text(), tree.wire())
        else:
            await self._changed(tree, now=True)

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
            log.exception("Lekora: Delegated card update failed")
        if not tree.working:
            self._forget(tree)

    def _forget(self, tree: Tree) -> None:
        """A finished card is saved; stop following it."""
        for key, other in list(self._trees.items()):
            if other is tree:
                del self._trees[key]
        for h in tree.helpers:
            self._helper_tree.pop(h.id, None)
            if h.session:
                self._session_helper.pop(h.session, None)
