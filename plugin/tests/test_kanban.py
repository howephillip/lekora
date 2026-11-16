"""The board (docs/kanban.md), with a stand-in for Hermes' kanban code."""

import pytest

from lekora.kanban import Kanban, KanbanError, describe_event
from tests.test_files import ask, fgw, file_store, phone  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv
from tests.test_voice_replies import until

MOVES = {"triage": ["archived", "ready", "todo"], "todo": ["archived", "ready", "triage"],
         "ready": ["archived", "blocked", "done", "todo"], "running": ["archived", "blocked", "ready"],
         "blocked": ["archived", "ready"], "done": ["archived", "ready"], "archived": ["ready", "todo"]}


class FakeBoards:
    """Hermes' board as the plugin sees it (HermesBoards' shape)."""

    def __init__(self) -> None:
        self.tasks_ = {}
        self.links = set()   # (parent, child)
        self.comments = {}
        self.history = 0
        self.changed = []
        self.n = 0

    def _touch(self, task_id):
        self.history += 1
        self.changed.append(task_id)

    def resolve(self, board):
        if board in (None, "", "default"):
            return "default"
        raise KanbanError("UNKNOWN_BOARD", "There's no such board")

    def boards(self):
        return [{"slug": "default", "name": "Default", "icon": None, "current": True}]

    def workflow(self):
        return [{"key": k, "label": k.capitalize()} for k in ("triage", "todo", "ready", "running", "blocked", "done")], MOVES

    def _require(self, task_id):
        if task_id not in self.tasks_:
            raise KanbanError("UNKNOWN_TASK", "That task isn't on this board any more")
        return self.tasks_[task_id]

    def card(self, board, task_id):
        t = dict(self._require(task_id))
        t["waits_on"] = sum(1 for p, c in self.links if c == task_id and self.tasks_[p]["status"] != "done")
        t["comments"] = len(self.comments.get(task_id, []))
        return t

    def tasks(self, board, archived=False):
        return [self.card(board, i) for i, t in self.tasks_.items() if archived or t["status"] != "archived"]

    def task(self, board, task_id):
        return {"task": self.card(board, task_id), "comments": self.comments.get(task_id, []), "runs": [],
                "parents": [], "children": [], "events": []}

    def create(self, board, *, title, body, assignee, priority, parents, triage, author):
        self.n += 1
        task_id = f"t_{self.n}"
        self.tasks_[task_id] = {"id": task_id, "title": title, "body": body, "assignee": assignee,
                                "priority": priority, "status": "triage" if triage else "todo", "by": author}
        for p in parents:
            self._require(p)
            self.links.add((p, task_id))
        self._touch(task_id)
        return self.card(board, task_id)

    def edit(self, board, task_id, *, title, body, priority):
        t = self._require(task_id)
        for key, value in (("title", title), ("body", body), ("priority", priority)):
            if value is not None:
                t[key] = value
        self._touch(task_id)
        return self.card(board, task_id)

    def move(self, board, task_id, status, note=None):
        t = self._require(task_id)
        t["note"] = note
        if status not in MOVES.get(t["status"], []):
            raise KanbanError("MOVE_REFUSED", f"A {t['status']} task can't be moved to {status}")
        if status == "ready" and any(c == task_id and self.tasks_[p]["status"] != "done" for p, c in self.links):
            raise KanbanError("MOVE_REFUSED", "It waits on tasks that aren't done")
        t["status"] = status
        self._touch(task_id)
        return self.card(board, task_id)

    def assign(self, board, task_id, assignee):
        self._require(task_id)["assignee"] = assignee
        self._touch(task_id)
        return self.card(board, task_id)

    def comment(self, board, task_id, body, author):
        self._require(task_id)
        self.comments.setdefault(task_id, []).append({"author": author, "body": body})
        self._touch(task_id)
        return self.card(board, task_id)

    def link(self, board, task_id, parent_id, remove):
        self._require(task_id), self._require(parent_id)
        (self.links.discard if remove else self.links.add)((parent_id, task_id))
        self._touch(task_id)
        return self.card(board, task_id)

    def stop(self, board, task_id):
        t = self._require(task_id)
        if t["status"] != "running":
            raise KanbanError("MOVE_REFUSED", "It isn't running")
        t["status"] = "blocked"
        self._touch(task_id)
        return self.card(board, task_id)

    def changes(self, board, after):
        if after is None or self.history <= after:
            return self.history, []
        got = self.changed[after:]
        return self.history, list(dict.fromkeys(got))


def service(published=None, profiles=("assistant", "coder")):
    boards = FakeBoards()
    published = published if published is not None else []

    async def publish(board, ids):
        published.append((board, ids))
    return Kanban(boards, publish, profiles=lambda: list(profiles), author=lambda: "Phillip"), boards, published


async def test_create_edit_comment_and_read():
    kanban, boards, published = service()
    made = (await kanban.change("kanban.create", {"title": "  Write   the  report ", "body": "Two pages",
                                                  "assignee": "coder", "priority": 2}))["task"]
    assert made["title"] == "Write the report" and made["assignee"] == "coder" and made["status"] == "todo"
    assert boards.tasks_[made["id"]]["by"] == "Phillip"
    await kanban.change("kanban.edit", {"task_id": made["id"], "title": "Write it", "priority": 5})
    await kanban.change("kanban.comment", {"task_id": made["id"], "body": "Use the new numbers"})
    got = await kanban.task({"task_id": made["id"]})
    assert got["task"]["title"] == "Write it" and got["task"]["priority"] == 5 and got["task"]["comments"] == 1
    assert got["comments"][0] == {"author": "Phillip", "body": "Use the new numbers"}
    board = await kanban.board({})
    assert board["board"] == "default" and board["moves"] == MOVES and [t["id"] for t in board["tasks"]] == [made["id"]]
    assert [ids for _, ids in published] == [[made["id"]]] * 3  # phones hear about each change


async def test_bad_input_is_refused_plainly():
    kanban, boards, _ = service()
    for type_, data, code in (
            ("kanban.create", {"title": "  "}, "INVALID_TASK"),
            ("kanban.create", {"title": "x", "assignee": "nobody"}, "UNKNOWN_PROFILE"),
            ("kanban.create", {"title": "x", "priority": "high"}, "INVALID_TASK"),
            ("kanban.create", {"title": "x", "parents": "t_1"}, "INVALID_TASK"),
            ("kanban.create", {"title": "x" * 400}, "INVALID_TASK"),
            ("kanban.comment", {"task_id": "t_9", "body": "hi"}, "UNKNOWN_TASK"),
            ("kanban.move", {"task_id": "", "status": "done"}, "UNKNOWN_TASK"),
            ("kanban.create", {"title": "x", "board": "elsewhere"}, "UNKNOWN_BOARD")):
        with pytest.raises(KanbanError) as err:
            await kanban.change(type_, data)
        assert err.value.code == code
    made = (await kanban.change("kanban.create", {"title": "x"}))["task"]
    with pytest.raises(KanbanError) as err:
        await kanban.change("kanban.comment", {"task_id": made["id"], "body": "   "})
    assert err.value.code == "INVALID_TASK"


async def test_moves_follow_hermes_rules_and_links_hold_a_task_back():
    kanban, boards, _ = service()
    first = (await kanban.change("kanban.create", {"title": "Research"}))["task"]
    second = (await kanban.change("kanban.create", {"title": "Write", "parents": [first["id"]]}))["task"]
    assert second["waits_on"] == 1
    with pytest.raises(KanbanError) as err:
        await kanban.change("kanban.move", {"task_id": second["id"], "status": "ready"})
    assert err.value.code == "MOVE_REFUSED" and "waits on" in err.value.reason
    with pytest.raises(KanbanError):
        await kanban.change("kanban.move", {"task_id": first["id"], "status": "running"})  # only Hermes runs tasks
    await kanban.change("kanban.link", {"task_id": second["id"], "parent_id": first["id"], "remove": True})
    moved = (await kanban.change("kanban.move", {"task_id": second["id"], "status": "ready"}))["task"]
    assert moved["status"] == "ready" and moved["waits_on"] == 0
    await kanban.change("kanban.move", {"task_id": first["id"], "status": "archived"})
    assert [t["id"] for t in (await kanban.board({}))["tasks"]] == [second["id"]]
    assert len((await kanban.board({"archived": True}))["tasks"]) == 2
    restored = (await kanban.change("kanban.move", {"task_id": first["id"], "status": "todo"}))["task"]
    assert restored["status"] == "todo"
    await kanban.change("kanban.move", {"task_id": second["id"], "status": "done"})
    assert boards.tasks_[second["id"]]["note"] == "Marked done in Lekora by Phillip"  # Hermes wants evidence
    await kanban.change("kanban.move", {"task_id": first["id"], "status": "ready"})
    await kanban.change("kanban.move", {"task_id": first["id"], "status": "blocked", "note": "Needs a key"})
    assert boards.tasks_[first["id"]]["note"] == "Needs a key"


async def test_reassign_and_stop():
    kanban, boards, _ = service()
    made = (await kanban.change("kanban.create", {"title": "x", "assignee": "assistant"}))["task"]
    assert (await kanban.change("kanban.assign", {"task_id": made["id"], "assignee": "coder"}))["task"]["assignee"] == "coder"
    assert (await kanban.change("kanban.assign", {"task_id": made["id"], "assignee": None}))["task"]["assignee"] is None
    with pytest.raises(KanbanError):
        await kanban.change("kanban.stop", {"task_id": made["id"]})
    boards.tasks_[made["id"]]["status"] = "running"
    assert (await kanban.change("kanban.stop", {"task_id": made["id"]}))["task"]["status"] == "blocked"


async def test_watching_tells_phones_what_changed_elsewhere():
    kanban, boards, published = service()
    boards.history = 40  # a board with history already: nothing is announced on the first look
    boards.changed = ["old"] * 40
    await kanban.check()
    assert published == []
    boards.tasks_["t_x"] = {"id": "t_x", "title": "From an agent", "status": "todo"}
    boards._touch("t_x")
    boards._touch("t_x")
    await kanban.check()
    assert published == [("default", ["t_x"])]
    await kanban.check()
    assert len(published) == 1


def test_history_lines_are_plain_words():
    assert describe_event("status", {"status": "ready"}) == "Moved to Ready"
    assert describe_event("blocked", {"reason": "needs a key"}) == "Blocked: needs a key"
    assert describe_event("claimed", {"profile": "coder"}) == "Picked up by coder"
    assert describe_event("workspace_cleanup_deferred_shared", None) == "Workspace cleanup deferred shared"


async def test_the_phone_uses_the_board(fgw, store):
    kanban, boards, _ = service()
    fgw.kanban = Kanban(boards, fgw.publish_kanban_changed, profiles=lambda: ["assistant", "coder"],
                        author=lambda: "Phillip")
    ws = await phone(fgw, store)
    other = await phone(fgw, store)

    async def send(type_, data):
        await ws.send(env(store, type_, data, msg_id=type_))
        while True:
            got = await recv(ws)
            if got["type"] != "kanban.changed":
                return got

    got = await send("kanban.create", {"title": "Plan the trip", "assignee": "coder"})
    assert got["type"] == "kanban.create.result" and got["data"]["task"]["title"] == "Plan the trip"
    task_id = got["data"]["task"]["id"]
    changed = (await until(other, "kanban.changed"))[0]
    assert changed["data"] == {"board": "default", "task_ids": [task_id]} and "profile_id" not in changed
    got = await send("kanban.board", {})
    assert got["type"] == "kanban.board.result" and got["data"]["tasks"][0]["id"] == task_id
    got = await send("kanban.move", {"task_id": task_id, "status": "running"})
    assert got["type"] == "error" and got["data"]["code"] == "MOVE_REFUSED"
    await ws.close()
    await other.close()


async def test_without_a_board_the_phone_is_told(fgw, store):
    ws = await phone(fgw, store)
    got = await ask(ws, store, "kanban.board", {}, profile=None)
    assert got["type"] == "error" and got["data"]["code"] == "KANBAN_UNAVAILABLE"
    await ws.close()
