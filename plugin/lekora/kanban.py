"""The board (spec: docs/kanban.md): Hermes' own kanban board, read and changed from the phone.

Boards are Hermes' (``~/.hermes/kanban.db`` and ``kanban/boards/<slug>/``), shared by every
agent. Everything goes through Hermes' own kanban code (``hermes_cli.kanban_db``), and status
moves through the very handlers Hermes' dashboard uses, so the dispatcher, its rules and the
task history stay right. Lekora keeps nothing about the board itself.
"""

from __future__ import annotations

import asyncio
import json
import importlib
import logging
from contextlib import closing
from dataclasses import asdict
from types import SimpleNamespace
from typing import Any, Awaitable, Callable, Iterable, Optional

log = logging.getLogger(__name__)

DONE_SHOWN = 100        # newest done (and archived) tasks sent with a board
EVENTS_SHOWN = 100
SUMMARY_CHARS = 200
TITLE_CHARS = 300
BODY_CHARS = 20_000
COMMENT_CHARS = 10_000
QUIET_EVENTS = ("heartbeat",)   # a worker saying it's alive isn't a change
STOPPED = "Stopped from Lekora"


class KanbanError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def _clip(text: Any, limit: int) -> Optional[str]:
    if not isinstance(text, str) or not text.strip():
        return None
    text = text.strip()
    return text if len(text) <= limit else text[:limit - 1].rstrip() + "…"


def describe_event(kind: str, payload: Optional[dict]) -> str:
    """A task's history line, in plain words."""
    p = payload if isinstance(payload, dict) else {}
    who = p.get("assignee") or p.get("profile") or p.get("author")
    reason = _clip(p.get("reason") or p.get("block_reason") or p.get("error"), 120)
    words = {
        "created": "Created",
        "edited": "Edited",
        "commented": f"Comment from {p['author']}" if p.get("author") else "Comment",
        "assigned": f"Assigned to {who}" if who else "Unassigned",
        "claimed": f"Picked up by {who}" if who else "Picked up",
        "spawned": "Worker started",
        "completed": "Done",
        "blocked": "Blocked" + (f": {reason}" if reason else ""),
        "unblocked": "Unblocked",
        "scheduled": "Scheduled",
        "promoted": "Ready",
        "promoted_manual": "Moved to Ready",
        "archived": "Archived",
        "linked": "Now waits on another task",
        "unlinked": "No longer waits on a task",
        "review_requested": "Review requested",
        "review_reopened": "Sent back from review",
        "changes_requested": "Changes requested",
        "reclaimed": "Stopped" + (f": {reason}" if reason else ""),
        "crashed": "Worker crashed" + (f": {reason}" if reason else ""),
        "timed_out": "Timed out",
        "gave_up": "Gave up" + (f": {reason}" if reason else ""),
        "reprioritized": "Priority changed",
    }
    if kind == "status" and p.get("status"):
        return f"Moved to {str(p['status']).capitalize()}"
    return words.get(kind) or kind.replace("_", " ").capitalize()


class HermesBoards:
    """Hermes' kanban code, as the plugin uses it. Every method blocks (run it in a thread)."""

    def __init__(self) -> None:
        self.kb = importlib.import_module("hermes_cli.kanban_db")
        try:
            self._connect = importlib.import_module("hermes_cli.kanban_db_connect").connect
        except ImportError:  # older Hermes: one module
            self._connect = self.kb.connect
        self._dashboard: Any = None

    # ---- boards ---------------------------------------------------------------------

    def resolve(self, board: Any) -> str:
        if board is None or board == "":
            return str(self.kb.get_current_board())
        if not isinstance(board, str):
            raise KanbanError("UNKNOWN_BOARD", "There's no such board")
        try:
            slug = self.kb._normalize_board_slug(board) or self.kb.DEFAULT_BOARD
        except (ValueError, AttributeError):
            slug = board
        if slug != self.kb.DEFAULT_BOARD:
            if not self.kb.board_exists(slug) or self.kb.read_board_metadata(slug).get("archived"):
                raise KanbanError("UNKNOWN_BOARD", "There's no such board")
        return slug

    def boards(self) -> list[dict]:
        current = str(self.kb.get_current_board())
        out = []
        for meta in self.kb.list_boards(include_archived=False):
            slug = meta.get("slug")
            if slug:
                out.append({"slug": slug, "name": meta.get("name") or slug,
                            "icon": meta.get("icon") or None, "current": slug == current})
        return out

    def workflow(self) -> tuple[list[dict], dict[str, list[str]]]:
        from hermes_cli.kanban_workflow import ARCHIVED, DEFAULT_WORKFLOW
        columns = [{"key": c.key, "label": c.label} for c in DEFAULT_WORKFLOW]
        moves = {src: sorted(dsts) for src, dsts in DEFAULT_WORKFLOW.manual.items()}
        for key in DEFAULT_WORKFLOW.keys():
            moves.setdefault(key, [])
            if ARCHIVED not in moves[key]:
                moves[key].append(ARCHIVED)  # archiving is always allowed
        return columns, moves

    def _conn(self, board: str):
        try:
            self.kb.init_db(board=board)  # idempotent; a fresh install has no file yet
        except Exception:
            log.debug("Lekora: kanban init_db failed", exc_info=True)
        return closing(self._connect(board=board))

    # ---- reading --------------------------------------------------------------------

    def _cards(self, conn, tasks: list) -> list[dict]:
        ids = [t.id for t in tasks]
        if not ids:
            return []
        summaries = self.kb.latest_summaries(conn, ids)
        started = self.kb.current_run_started_ats(conn, ids) if hasattr(self.kb, "current_run_started_ats") else {}
        waits: dict[str, int] = {}
        for row in conn.execute(
                "SELECT l.child_id, COUNT(*) FROM task_links l JOIN tasks p ON p.id = l.parent_id "
                "WHERE p.status NOT IN ('done', 'archived') GROUP BY l.child_id"):
            waits[row[0]] = row[1]
        comments: dict[str, int] = {}
        for row in conn.execute("SELECT task_id, COUNT(*) FROM task_comments GROUP BY task_id"):
            comments[row[0]] = row[1]
        return [self._card(t, summaries.get(t.id), started.get(t.id), waits.get(t.id, 0), comments.get(t.id, 0))
                for t in tasks]

    @staticmethod
    def _card(t, summary, running_since, waits_on, comments) -> dict:
        return {
            "id": t.id, "title": t.title, "status": t.status, "assignee": t.assignee,
            "priority": int(t.priority or 0), "created_at": t.created_at, "started_at": t.started_at,
            "completed_at": t.completed_at,
            "running_since": running_since if t.status == "running" else None,
            "summary": _clip(summary, SUMMARY_CHARS), "waits_on": waits_on, "comments": comments,
        }

    def card(self, board: str, task_id: str) -> dict:
        with self._conn(board) as conn:
            task = self._require(conn, task_id)
            return self._cards(conn, [task])[0]

    def tasks(self, board: str, archived: bool = False) -> list[dict]:
        with self._conn(board) as conn:
            tasks = self.kb.list_tasks(conn, include_archived=archived)
            open_ = [t for t in tasks if t.status not in ("done", "archived")]
            finished = []
            for status in ("done", "archived"):
                rows = [t for t in tasks if t.status == status]
                rows.sort(key=lambda t: t.completed_at or t.created_at or 0, reverse=True)
                finished += rows[:DONE_SHOWN]
            return self._cards(conn, open_ + finished)

    def _require(self, conn, task_id: Any):
        task = self.kb.get_task(conn, task_id) if isinstance(task_id, str) and task_id else None
        if task is None:
            raise KanbanError("UNKNOWN_TASK", "That task isn't on this board any more")
        return task

    def task(self, board: str, task_id: str) -> dict:
        with self._conn(board) as conn:
            task = self._require(conn, task_id)
            card = self._cards(conn, [task])[0]
            full_summary = self.kb.latest_summary(conn, task_id) if hasattr(self.kb, "latest_summary") else None
            card.update({
                "summary": (full_summary or card["summary"]),
                "body": task.body or None, "result": task.result or None,
                "failures": int(task.consecutive_failures or 0),
                "last_error": _clip(task.last_failure_error, 500),
            })

            def brief(ids: Iterable[str]) -> list[dict]:
                out = []
                for other in filter(None, (self.kb.get_task(conn, i) for i in ids)):
                    out.append({"id": other.id, "title": other.title, "status": other.status})
                return out

            events = [e for e in self.kb.list_events(conn, task_id) if e.kind not in QUIET_EVENTS]
            return {
                "task": card,
                "comments": [{"id": c.id, "author": c.author, "body": c.body, "created_at": c.created_at}
                             for c in self.kb.list_comments(conn, task_id)],
                "runs": [{"id": r.id, "profile": r.profile, "status": r.status, "outcome": r.outcome,
                          "started_at": r.started_at, "ended_at": r.ended_at,
                          "summary": r.summary or None, "error": _clip(r.error, 500)}
                         for r in self.kb.list_runs(conn, task_id)],
                "parents": brief(self.kb.parent_ids(conn, task_id)),
                "children": brief(self.kb.child_ids(conn, task_id)),
                "events": [{"id": e.id, "kind": e.kind, "created_at": e.created_at,
                            "summary": describe_event(e.kind, e.payload)} for e in events[-EVENTS_SHOWN:]],
            }

    # ---- changes --------------------------------------------------------------------

    def create(self, board: str, *, title: str, body: Optional[str], assignee: Optional[str],
               priority: int, parents: list[str], triage: bool, author: str) -> dict:
        with self._conn(board) as conn:
            for parent in parents:
                self._require(conn, parent)
            try:
                task_id = self.kb.create_task(conn, title=title, body=body, assignee=assignee,
                                              created_by=author, priority=priority, parents=parents,
                                              triage=triage)
            except ValueError as exc:
                raise KanbanError("INVALID_TASK", str(exc))
            return self._cards(conn, [self._require(conn, task_id)])[0]

    def edit(self, board: str, task_id: str, *, title: Optional[str], body: Optional[str],
             priority: Optional[int]) -> dict:
        with self._conn(board) as conn:
            self._require(conn, task_id)
            try:
                self.kb.edit_task(conn, task_id, title=title, body=body, priority=priority, board=board)
            except ValueError as exc:
                raise KanbanError("INVALID_TASK", str(exc))
            return self._cards(conn, [self._require(conn, task_id)])[0]

    def _dashboard_api(self):
        """Hermes' dashboard handlers for status moves (the same rules as dragging a card there)."""
        if self._dashboard is None:
            try:
                self._dashboard = importlib.import_module("plugins.kanban.dashboard.plugin_api")
            except Exception:
                log.warning("Lekora: Hermes' kanban dashboard code isn't available", exc_info=True)
                self._dashboard = False
        return self._dashboard or None

    def move(self, board: str, task_id: str, status: str, note: Optional[str] = None) -> dict:
        """``note``: why it's blocked, or what was done (Hermes asks for evidence before Done)."""
        with self._conn(board) as conn:
            task = self._require(conn, task_id)
            _, moves = self.workflow()
            if status == task.status:
                return self._cards(conn, [task])[0]
            if status not in moves.get(task.status, []):
                raise KanbanError("MOVE_REFUSED", f"A {task.status} task can't be moved to {status}")
            if status == "archived":
                ok = self.kb.archive_task(conn, task_id)
            else:
                api = self._dashboard_api()
                if api is None:
                    raise KanbanError("MOVE_REFUSED", "This Hermes version can't make that move from Lekora")
                payload = SimpleNamespace(result=None, summary=note if status in ("done", "review") else None,
                                          metadata=None, block_reason=note if status in ("blocked", "scheduled") else None,
                                          assignee=None)
                try:
                    ok = api._apply_status(conn, task_id, status, payload, f"unknown status: {status}")
                except Exception as exc:  # the dashboard's refusals carry Hermes' words
                    raise KanbanError("MOVE_REFUSED", getattr(exc, "detail", None) or str(exc) or "Hermes refused")
            if not ok:
                raise KanbanError("MOVE_REFUSED", self._refusal(conn, task_id, status))
            return self._cards(conn, [self._require(conn, task_id)])[0]

    def _refusal(self, conn, task_id: str, status: str) -> str:
        api = self._dashboard_api()
        try:
            if api is not None and status == "ready":
                blockers = api._parents_blocking_ready(conn, task_id)
                if blockers:
                    names = ", ".join(f"“{b['title']}” ({b['status']})" for b in blockers)
                    return f"It waits on tasks that aren't done: {names}"
            if api is not None:
                reason = api._open_parent_refusal(conn, task_id, status)
                if reason:
                    return str(reason)
        except Exception:
            log.debug("Lekora: couldn't explain a refused move", exc_info=True)
        return f"Hermes didn't allow moving it to {status} from where it is now"

    def assign(self, board: str, task_id: str, assignee: Optional[str]) -> dict:
        with self._conn(board) as conn:
            self._require(conn, task_id)
            try:
                ok = self.kb.assign_task(conn, task_id, assignee)
            except RuntimeError:
                raise KanbanError("MOVE_REFUSED", "It's running now; stop it first, then assign it")
            if not ok:
                raise KanbanError("MOVE_REFUSED", "Hermes didn't allow assigning it")
            return self._cards(conn, [self._require(conn, task_id)])[0]

    def comment(self, board: str, task_id: str, body: str, author: str) -> dict:
        with self._conn(board) as conn:
            self._require(conn, task_id)
            self.kb.add_comment(conn, task_id, author=author, body=body)
            return self._cards(conn, [self._require(conn, task_id)])[0]

    def link(self, board: str, task_id: str, parent_id: str, remove: bool) -> dict:
        with self._conn(board) as conn:
            self._require(conn, task_id)
            self._require(conn, parent_id)
            if parent_id == task_id:
                raise KanbanError("INVALID_TASK", "A task can't wait on itself")
            try:
                if remove:
                    self.kb.unlink_tasks(conn, parent_id, task_id)
                else:
                    self.kb.link_tasks(conn, parent_id, task_id)
            except (ValueError, RuntimeError) as exc:
                raise KanbanError("INVALID_TASK", str(exc))
            return self._cards(conn, [self._require(conn, task_id)])[0]

    def stop(self, board: str, task_id: str) -> dict:
        """Stop a running task's worker; it then waits as blocked (it would otherwise start again)."""
        with self._conn(board) as conn:
            task = self._require(conn, task_id)
            if task.status != "running":
                raise KanbanError("MOVE_REFUSED", "It isn't running")
            if not self.kb.reclaim_task(conn, task_id, reason=STOPPED):
                raise KanbanError("MOVE_REFUSED", "It had already stopped")
            try:
                self.kb.block_task(conn, task_id, reason=STOPPED)
            except Exception:
                log.debug("Lekora: a stopped task couldn't be parked as blocked", exc_info=True)
            return self._cards(conn, [self._require(conn, task_id)])[0]

    # ---- watching -------------------------------------------------------------------

    def created_since(self, board: str, after: Optional[int]) -> tuple[int, list[dict]]:
        """(the newest history id, tasks created since ``after``: ``{id, session_id, created_by,
        creator_task_id}``). ``after`` None: only where the history is now (docs/delegation.md)."""
        with self._conn(board) as conn:
            top = conn.execute("SELECT COALESCE(MAX(id), 0) FROM task_events").fetchone()[0]
            if after is None or top <= after:
                return top, []
            rows = conn.execute(
                "SELECT e.task_id, json_extract(e.payload, '$.creator_task_id'), t.session_id, t.created_by "
                "FROM task_events e JOIN tasks t ON t.id = e.task_id "
                "WHERE e.id > ? AND e.kind = 'created' ORDER BY e.id LIMIT 200", (after,)).fetchall()
            return top, [{"id": r[0], "creator_task_id": r[1], "session_id": r[2], "created_by": r[3]}
                         for r in rows]

    def follow(self, board: str, task_ids: Iterable[str]) -> list[dict]:
        """Where delegated tasks are now: status, who has it, what happened last, what it reported."""
        out = []
        with self._conn(board) as conn:
            for task_id in task_ids:
                task = self.kb.get_task(conn, task_id)
                if task is None:
                    out.append({"id": task_id, "status": "archived"})
                    continue
                last = conn.execute(
                    "SELECT kind, payload FROM task_events WHERE task_id = ? AND kind NOT IN ('heartbeat') "
                    "ORDER BY id DESC LIMIT 1", (task_id,)).fetchone()
                doing = None
                if last:
                    try:
                        payload = json.loads(last[1]) if last[1] else None
                    except (TypeError, ValueError):
                        payload = None
                    doing = describe_event(last[0], payload)
                summary = self.kb.latest_summary(conn, task_id) if hasattr(self.kb, "latest_summary") else None
                out.append({"id": task.id, "title": task.title, "status": task.status, "assignee": task.assignee,
                            "started_at": task.started_at, "completed_at": task.completed_at,
                            "created_at": task.created_at, "doing": doing,
                            "summary": task.result or summary or None,
                            "error": _clip(task.last_failure_error, 300)})
        return out

    def changes(self, board: str, after: Optional[int]) -> tuple[int, list[str]]:
        """(the newest history id, the tasks changed since ``after``), heartbeats left out.
        ``after`` None: only where the history is now."""
        with self._conn(board) as conn:
            top = conn.execute("SELECT COALESCE(MAX(id), 0) FROM task_events").fetchone()[0]
            if after is None or top <= after:
                return top, []
            marks = ",".join("?" for _ in QUIET_EVENTS)
            rows = conn.execute(
                f"SELECT DISTINCT task_id FROM task_events WHERE id > ? AND kind NOT IN ({marks}) LIMIT 500",
                (after, *QUIET_EVENTS)).fetchall()
            return top, [r[0] for r in rows]


class Kanban:
    """The board for phones: checks what they send, signs comments, tells phones what changed."""

    def __init__(self, boards: Any, publish: Callable[[str, list[str]], Awaitable[None]],
                 profiles: Callable[[], Iterable[str]], author: Callable[[], str]) -> None:
        self.boards = boards        # HermesBoards (or a stand-in in tests)
        self.publish = publish      # (board, task ids): `kanban.changed` to every phone
        self.profiles = profiles    # the agents a task can be assigned to
        self.author = author        # who comments and new tasks are from (the user's name)
        self._cursors: dict[str, int] = {}

    async def _run(self, fn: Callable, *args: Any, **kw: Any) -> Any:
        return await asyncio.to_thread(fn, *args, **kw)

    # ---- for the phone ---------------------------------------------------------------

    async def board(self, data: dict) -> dict:
        def read() -> dict:
            slug = self.boards.resolve(data.get("board"))
            columns, moves = self.boards.workflow()
            return {"board": slug, "boards": self.boards.boards(), "columns": columns, "moves": moves,
                    "tasks": self.boards.tasks(slug, archived=bool(data.get("archived")))}
        return await self._run(read)

    async def task(self, data: dict) -> dict:
        def read() -> dict:
            slug = self.boards.resolve(data.get("board"))
            return {"board": slug, **self.boards.task(slug, self._task_id(data.get("task_id")))}
        return await self._run(read)

    async def change(self, type_: str, data: dict) -> dict:
        slug = await self._run(self.boards.resolve, data.get("board"))
        if type_ == "kanban.create":
            parents = data.get("parents") or []
            if not isinstance(parents, list) or not all(isinstance(p, str) and p for p in parents):
                raise KanbanError("INVALID_TASK", "parents must be task ids")
            card = await self._run(
                self.boards.create, slug, title=self._title(data.get("title")),
                body=self._text(data.get("body"), BODY_CHARS), assignee=self._assignee(data.get("assignee")),
                priority=self._priority(data.get("priority")) or 0, parents=parents[:50],
                triage=bool(data.get("triage")), author=self.author())
        else:
            task_id = self._task_id(data.get("task_id"))
            if type_ == "kanban.edit":
                title = data.get("title")
                card = await self._run(
                    self.boards.edit, slug, task_id,
                    title=self._title(title) if title is not None else None,
                    body=self._text(data.get("body"), BODY_CHARS, keep_empty=True) if "body" in data else None,
                    priority=self._priority(data.get("priority")))
            elif type_ == "kanban.move":
                status = data.get("status")
                if not isinstance(status, str) or not status:
                    raise KanbanError("INVALID_TASK", "status is required")
                note = self._text(data.get("note"), COMMENT_CHARS)
                if status == "done" and not note:
                    note = f"Marked done in Lekora by {self.author()}"
                card = await self._run(self.boards.move, slug, task_id, status, note)
            elif type_ == "kanban.assign":
                card = await self._run(self.boards.assign, slug, task_id, self._assignee(data.get("assignee")))
            elif type_ == "kanban.comment":
                body = self._text(data.get("body"), COMMENT_CHARS)
                if not body:
                    raise KanbanError("INVALID_TASK", "A comment needs some words")
                card = await self._run(self.boards.comment, slug, task_id, body, self.author())
            elif type_ == "kanban.link":
                card = await self._run(self.boards.link, slug, task_id, self._task_id(data.get("parent_id")),
                                       bool(data.get("remove")))
            elif type_ == "kanban.stop":
                card = await self._run(self.boards.stop, slug, task_id)
            else:
                raise KanbanError("INVALID_TASK", f"Unknown board change: {type_}")
        await self._publish(slug, [card["id"]])
        return {"board": slug, "task": card}

    # ---- checks ----------------------------------------------------------------------

    @staticmethod
    def _task_id(value: Any) -> str:
        if not isinstance(value, str) or not value.strip():
            raise KanbanError("UNKNOWN_TASK", "Which task?")
        return value.strip()

    @staticmethod
    def _text(value: Any, limit: int, keep_empty: bool = False) -> Optional[str]:
        if value is None:
            return "" if keep_empty else None
        if not isinstance(value, str):
            raise KanbanError("INVALID_TASK", "Text expected")
        value = value.strip()
        if len(value) > limit:
            raise KanbanError("INVALID_TASK", f"That's too long (up to {limit} characters)")
        return value if value or keep_empty else None

    def _title(self, value: Any) -> str:
        title = self._text(value, TITLE_CHARS)
        if not title:
            raise KanbanError("INVALID_TASK", "A task needs a title")
        return " ".join(title.split())

    @staticmethod
    def _priority(value: Any) -> Optional[int]:
        if value is None:
            return None
        if isinstance(value, bool) or not isinstance(value, int) or not -100 <= value <= 100:
            raise KanbanError("INVALID_TASK", "Priority must be a whole number")
        return value

    def _assignee(self, value: Any) -> Optional[str]:
        if value is None or value == "":
            return None
        if not isinstance(value, str) or value not in set(self.profiles()):
            raise KanbanError("UNKNOWN_PROFILE", "There's no such agent on this Hermes instance")
        return value

    # ---- watching --------------------------------------------------------------------

    async def _publish(self, board: str, task_ids: list[str]) -> None:
        try:
            await self.publish(board, task_ids)
        except Exception:
            log.debug("Lekora: couldn't tell phones about a board change", exc_info=True)

    async def check(self) -> None:
        """One look at every board's history; phones hear about what changed since the last look."""
        boards = await self._run(self.boards.boards)
        for board in boards:
            slug = board["slug"]
            top, changed = await self._run(self.boards.changes, slug, self._cursors.get(slug))
            self._cursors[slug] = top
            if changed:
                await self._publish(slug, changed)

    async def watch(self, every: float = 3.0, active: Callable[[], bool] = lambda: True) -> None:
        while True:
            try:
                if active():
                    await self.check()
                else:
                    self._cursors.clear()  # nobody's looking: start fresh when a phone is back
            except Exception:
                log.debug("Lekora: board check failed", exc_info=True)
            await asyncio.sleep(every)
