"""Helpers against Hermes' real delegation code (docs/delegation.md). Runs only where Hermes is
installed, in a temporary Hermes home with throwaway profiles."""

import inspect
import json
from types import SimpleNamespace

import pytest

pytest.importorskip("tools.delegate_tool_routes")

from agent import delegation_backends, delegation_registry  # noqa: E402
from tools.delegate_tool_routes import resolve_task_routes  # noqa: E402

from lekora import hermes_delegation  # noqa: E402
from lekora.hermes_delegation import BACKEND, HermesHelpers, ask_agent, make_provider  # noqa: E402


class Ctx:
    def __init__(self):
        self.hooks, self.tools = {}, {}

    def register_hook(self, name, cb):
        self.hooks[name] = cb

    def register_delegation_provider(self, provider):
        delegation_registry._registry.register(provider)

    def register_tool(self, **kw):
        self.tools[kw["name"]] = kw


@pytest.fixture
def home(tmp_path, monkeypatch):
    root = tmp_path / "hermes-home"
    # A local model endpoint that is never called: routes resolve without the network.
    model = ("model:\n  default: test-model\n  provider: custom\n"
             "  base_url: http://127.0.0.1:9/v1\n  api_key: test-key\n")
    (root / "profiles" / "researcher").mkdir(parents=True)
    (root / "profiles" / "researcher" / "config.yaml").write_text(model)
    (root / "config.yaml").write_text(model)
    monkeypatch.setenv("HERMES_HOME", str(root))
    before = delegation_registry._registry.snapshot_registration(BACKEND)
    yield root
    delegation_backends.set_session_backend("sess-1", None)
    now = delegation_registry._registry.snapshot_registration(BACKEND)
    if now is not None:
        delegation_registry._registry.restore_registration(BACKEND, now, before)


def test_the_hooks_lekora_uses_are_hermes_hooks():
    from hermes_cli.plugins import VALID_HOOKS
    assert {"subagent_start", "post_tool_call", "subagent_stop"} <= set(VALID_HOOKS)


def test_hermes_still_sends_what_the_hooks_read():
    from tools import delegate_tool, delegate_tool_results
    start = inspect.getsource(delegate_tool)
    for kw in ("parent_turn_id", "parent_subagent_id", "child_session_id", "child_subagent_id", "child_goal"):
        assert kw + "=" in start
    stop = inspect.getsource(delegate_tool_results._fire_subagent_stop_hooks)
    for kw in ("child_session_id", "child_summary", "child_status", "tool_call_history", "duration_ms"):
        assert kw + "=" in stop


def test_register_adds_hooks_backend_and_tool(home):
    ctx = Ctx()
    hermes_delegation.register(ctx, lambda: None, lambda: ["default", "researcher"], lambda: True)
    assert set(ctx.hooks) == {"subagent_start", "post_tool_call", "subagent_stop"}
    assert "lekora_ask_agent" in ctx.tools
    assert any(i.name == BACKEND and i.available for i in delegation_backends.list_backends())


def test_a_task_naming_an_agent_runs_as_that_profile(home):
    delegation_registry._registry.register(make_provider(lambda: ["default", "researcher"]))
    delegation_backends.set_session_backend("sess-1", BACKEND)
    parent = SimpleNamespace(session_id="sess-1")
    routes, err = resolve_task_routes([{"goal": "Look into it", "agent": "researcher"}], {}, parent)
    assert err is None and routes[0].error is None
    assert routes[0].profile_home == home / "profiles" / "researcher"
    assert routes[0].backend == BACKEND and routes[0].label == "researcher"


def test_an_unknown_agent_is_refused_by_name(home):
    delegation_registry._registry.register(make_provider(lambda: ["default", "researcher"]))
    delegation_backends.set_session_backend("sess-1", BACKEND)
    routes, err = resolve_task_routes([{"goal": "x", "agent": "nobody"}], {}, SimpleNamespace(session_id="sess-1"))
    assert err is None and "nobody" in routes[0].error


def test_asking_needs_a_real_other_agent(home):
    names = lambda: ["default", "researcher"]  # noqa: E731
    assert "task" in json.loads(ask_agent({"agent": "researcher"}, profiles=names))["error"]
    err = json.loads(ask_agent({"agent": "nobody", "task": "x"}, profiles=names))["error"]
    assert "default, researcher" in err
    # Outside a chat turn there's no agent to report back to.
    assert "chat turn" in json.loads(ask_agent({"agent": "researcher", "task": "x"}, profiles=names))["error"]


def test_hermes_running_list_and_stop():
    assert HermesHelpers.running() == []
    assert HermesHelpers.interrupt("sa-0-nothere") is False
