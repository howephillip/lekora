"""The board against Hermes' real kanban code (docs/kanban.md). Runs only where Hermes is installed,
on a throwaway board in a temporary Hermes home (never the instance's own board)."""

import pytest

kanban_db = pytest.importorskip("hermes_cli.kanban_db")

from lekora.kanban import HermesBoards, KanbanError  # noqa: E402


@pytest.fixture
def boards(tmp_path, monkeypatch):
    home = tmp_path / "hermes-home"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    for name in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD", "HERMES_KANBAN_HOME"):
        monkeypatch.delenv(name, raising=False)
    got = HermesBoards()
    assert str(kanban_db.kanban_db_path("default")).startswith(str(home))
    return got


def test_reading_an_empty_board(boards):
    slug = boards.resolve(None)
    assert slug == "default"
    assert [b["slug"] for b in boards.boards()] == ["default"]
    columns, moves = boards.workflow()
    assert [c["key"] for c in columns][:2] == ["triage", "todo"] and "archived" in moves["todo"]
    assert boards.tasks(slug) == []
    with pytest.raises(KanbanError) as err:
        boards.resolve("no-such-board")
    assert err.value.code == "UNKNOWN_BOARD"


def test_every_action(boards):
    first = boards.create("default", title="Research", body="Find sources", assignee="default", priority=1,
                          parents=[], triage=False, author="Phillip")
    second = boards.create("default", title="Write", body=None, assignee=None, priority=0,
                           parents=[first["id"]], triage=False, author="Phillip")
    assert second["waits_on"] == 1
    edited = boards.edit("default", first["id"], title="Research more", body=None, priority=3)
    assert edited["title"] == "Research more" and edited["priority"] == 3
    assert boards.comment("default", first["id"], "Use 2026 numbers", "Phillip")["comments"] == 1
    assert boards.assign("default", second["id"], "default")["assignee"] == "default"

    with pytest.raises(KanbanError) as err:
        boards.move("default", second["id"], "ready")  # it waits on Research
    assert err.value.code == "MOVE_REFUSED" and "Research" in err.value.reason
    with pytest.raises(KanbanError):
        boards.move("default", first["id"], "running")  # only Hermes runs tasks

    done = boards.move("default", first["id"], "done", "Found five sources")
    assert done["status"] == "done"
    assert boards.card("default", second["id"])["waits_on"] == 0
    boards.link("default", second["id"], first["id"], remove=True)
    detail = boards.task("default", second["id"])
    assert detail["parents"] == [] and detail["task"]["status"] in ("todo", "ready")

    archived = boards.move("default", first["id"], "archived")
    assert archived["status"] == "archived"
    assert first["id"] not in [t["id"] for t in boards.tasks("default")]
    assert first["id"] in [t["id"] for t in boards.tasks("default", archived=True)]
    restored = boards.move("default", first["id"], "todo")
    assert restored["status"] == "todo"

    detail = boards.task("default", first["id"])
    assert any(r["summary"] == "Found five sources" for r in detail["runs"]) or detail["task"]["summary"] == "Found five sources"
    blocked = boards.move("default", second["id"], "blocked", "Needs a key")
    assert blocked["status"] == "blocked"
    assert "Needs a key" in " ".join(e["summary"] for e in boards.task("default", second["id"])["events"])
    assert detail["comments"][0]["author"] == "Phillip" and detail["comments"][0]["body"] == "Use 2026 numbers"
    assert any(e["summary"] == "Created" for e in detail["events"])
    assert all(e["kind"] != "heartbeat" for e in detail["events"])

    with pytest.raises(KanbanError) as err:
        boards.stop("default", first["id"])
    assert err.value.code == "MOVE_REFUSED"
    # Stopping a running one: Hermes stops its worker, and it waits as blocked.
    from contextlib import closing
    with closing(kanban_db.connect(board="default") if hasattr(kanban_db, "connect") else boards._connect(board="default")) as conn:
        conn.execute("UPDATE tasks SET status = 'running', claim_lock = 'test-lock' WHERE id = ?", (first["id"],))
        conn.commit()
    stopped = boards.stop("default", first["id"])
    assert stopped["status"] == "blocked"
    assert any("Stopped" in e["summary"] for e in boards.task("default", first["id"])["events"])
    with pytest.raises(KanbanError) as err:
        boards.card("default", "t_missing")
    assert err.value.code == "UNKNOWN_TASK"


def test_changes_are_seen(boards):
    top, changed = boards.changes("default", None)
    assert changed == []
    made = boards.create("default", title="New", body=None, assignee=None, priority=0, parents=[],
                         triage=True, author="Phillip")
    assert made["status"] == "triage"
    later, changed = boards.changes("default", top)
    assert later > top and changed == [made["id"]]
    assert boards.changes("default", later) == (later, [])
