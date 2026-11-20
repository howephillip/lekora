"""Delegated cards against Hermes' real code (docs/delegation.md). Runs only where Hermes is
installed, on a throwaway board in a temporary Hermes home."""

import inspect
import json

import pytest

kanban_db = pytest.importorskip("hermes_cli.kanban_db")
pytest.importorskip("tools.delegate_tool")

from lekora.hermes_delegation import HermesHelpers, Hooks, register  # noqa: E402
from lekora.kanban import HermesBoards  # noqa: E402


@pytest.fixture
def boards(tmp_path, monkeypatch):
    home = tmp_path / "hermes-home"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    for name in ("HERMES_KANBAN_DB", "HERMES_KANBAN_BOARD", "HERMES_KANBAN_HOME", "HERMES_KANBAN_TASK"):
        monkeypatch.delenv(name, raising=False)
    return HermesBoards()


def _create(boards, title, assignee, session=None, creator=None):
    with boards._conn("default") as conn:
        return kanban_db.create_task(conn, title=title, assignee=assignee, created_by="default",
                                     session_id=session, creator_task_id=creator)


def test_the_hooks_lekora_uses_are_hermes_hooks():
    from hermes_cli.plugins import VALID_HOOKS
    assert {"subagent_start", "post_tool_call", "subagent_stop"} <= set(VALID_HOOKS)


def test_hermes_still_sends_what_the_hooks_read():
    from tools import delegate_tool, delegate_tool_results, kanban_tools
    start = inspect.getsource(delegate_tool)
    for kw in ("parent_turn_id", "parent_subagent_id", "child_session_id", "child_subagent_id", "child_goal"):
        assert kw + "=" in start
    stop = inspect.getsource(delegate_tool_results._fire_subagent_stop_hooks)
    for kw in ("child_session_id", "child_summary", "child_status", "tool_call_history", "duration_ms"):
        assert kw + "=" in stop
    # kanban_create answers with the new task's id (what the post_tool_call hook reads).
    assert "_ok(task_id=new_tid" in inspect.getsource(kanban_tools._handle_create)


def test_register_only_watches():
    class Ctx:
        def __init__(self):
            self.hooks, self.other = {}, []

        def register_hook(self, name, cb):
            self.hooks[name] = cb

        def __getattr__(self, name):
            self.other.append(name)
            raise AttributeError(name)

    ctx = Ctx()
    register(ctx, lambda: None)
    assert set(ctx.hooks) == {"subagent_start", "post_tool_call", "subagent_stop"} and ctx.other == []


def test_new_tasks_carry_the_chat_and_the_task_that_made_them(boards):
    top, _ = boards.created_since("default", None)
    first = _create(boards, "Fix screen capture", "ashlyn", session="20261119_lekora")
    child = _create(boards, "Check permissions", "carl", creator=first)
    _, rows = boards.created_since("default", top)
    by_id = {r["id"]: r for r in rows}
    assert by_id[first]["session_id"] == "20261119_lekora" and by_id[first]["created_by"] == "default"
    assert by_id[child]["creator_task_id"] == first


def test_following_a_task(boards):
    task_id = _create(boards, "Fix screen capture", "ashlyn", session="s")
    row = boards.follow("default", [task_id, "t_gone"])
    assert row[0]["title"] == "Fix screen capture" and row[0]["assignee"] == "ashlyn"
    assert row[0]["status"] in ("ready", "todo", "running") and row[0]["doing"]
    assert row[1] == {"id": "t_gone", "status": "archived"}


def test_the_kanban_create_hook_reads_a_real_answer(monkeypatch):
    seen = []

    class D:
        async def handed_off(self, **kw):
            seen.append(kw)

    import asyncio
    loop = asyncio.new_event_loop()
    import lekora.hermes_delegation as hd
    monkeypatch.setattr(hd, "_lekora_chat", lambda: "default")
    hooks = Hooks(lambda: (D(), loop))
    hooks.post_tool_call(tool_name="kanban_create", args={"title": "Fix it", "assignee": "ashlyn"},
                         result=json.dumps({"ok": True, "task_id": "t_1", "status": "running"}), task_id="")
    loop.run_until_complete(asyncio.sleep(0.05))
    loop.close()
    assert seen and seen[0]["task_id"] == "t_1" and seen[0]["assignee"] == "ashlyn" and seen[0]["chat_id"] == "default"


def test_hermes_running_list_and_stop():
    assert HermesHelpers.running() == []
    assert HermesHelpers.interrupt("sa-0-nothere") is False
