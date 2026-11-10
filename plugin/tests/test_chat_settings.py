"""Per-chat settings (docs/chat-settings.md)."""

import sys
import types
from pathlib import Path
from types import SimpleNamespace

import pytest

from lekora import hermes_settings
from lekora.chat_settings import ChatSettings, SettingsError, command_for
from tests.test_gateway import PROFILES, env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import hello_rev


# ---- changes become Hermes' own commands ------------------------------------------

@pytest.mark.parametrize("key,value,command", [
    ("reasoning", "high", "/reasoning high"),
    ("reasoning", "reset", "/reasoning reset"),
    ("show_reasoning", True, "/reasoning show"),
    ("show_reasoning", False, "/reasoning hide"),
    ("fast", "fast", "/fast fast"),
    ("approvals", "smart", "/approvals smart"),
    ("personality", "pirate", "/personality pirate"),
    ("personality", None, "/personality none"),
    ("title", "  Ramen   plans ", "/title Ramen plans"),
])
def test_commands(key, value, command):
    assert command_for(key, value, {"personality": {"options": [{"name": "pirate"}]}}) == command


def test_yolo_is_only_toggled_when_it_changes():
    assert command_for("yolo", True, {"yolo": False}) == "/yolo"
    assert command_for("yolo", True, {"yolo": True}) is None
    assert command_for("yolo", False, {"yolo": True}) == "/yolo"
    assert command_for("yolo", True, {}) == "/yolo", "unknown state: send it"


@pytest.mark.parametrize("key,value", [("reasoning", "turbo"), ("fast", "warp"), ("approvals", "yes"),
                                       ("personality", "ghost"), ("personality", "a; rm"), ("title", "  "),
                                       ("nonsense", 1)])
def test_bad_values_are_refused(key, value):
    with pytest.raises(SettingsError):
        command_for(key, value, {"personality": {"options": [{"name": "pirate"}]}})


# ---- the gateway -------------------------------------------------------------------------

async def test_settings_requests(gw, store):
    sent = []

    async def send_command(profile_id, text):
        sent.append((profile_id, text))
    gw.settings = ChatSettings(lambda p: {"yolo": False, "reasoning": {"effort": "medium", "this_chat": False}},
                               send_command)
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(ws)
    await ws.send(env(store, "settings.get", {}, profile_id="coder", msg_id="s1"))
    got = await recv(ws)
    assert got["type"] == "settings.get.result" and got["data"]["yolo"] is False
    await ws.send(env(store, "settings.set", {"key": "yolo", "value": True}, profile_id="coder", msg_id="s2"))
    assert (await recv(ws))["data"] == {"key": "yolo", "command": "/yolo"}
    await ws.send(env(store, "settings.set", {"key": "fast", "value": "warp"}, profile_id="coder", msg_id="s3"))
    assert (await recv(ws))["data"]["code"] == "INVALID_SETTING"
    await ws.send(env(store, "settings.action", {"action": "compress"}, profile_id="coder", msg_id="s4"))
    assert (await recv(ws))["data"]["command"] == "/compress"
    assert sent == [("coder", "/yolo"), ("coder", "/compress")]
    await ws.close()


# ---- reading Hermes (stand-ins for its internals) -----------------------------------------

@pytest.fixture
def fake_hermes(monkeypatch, tmp_path):
    yolo_sessions = set()
    modules = {
        "hermes_cli.config_effective": {"load_user_config_effective": lambda path: {
            "model": {"default": "claude-opus-5-5", "provider": "anthropic"},
            "approvals": {"mode": "smart"}, "display": {"personality": "pirate"}}},
        "gateway.display_config": {"resolve_display_setting": lambda cfg, platform, setting, fallback=None: True},
        "agent.fast_mode": {"service_tier_word": lambda tier: {"priority": "fast", None: "normal"}.get(tier, tier)},
        "tools.approval": {"is_session_yolo_enabled": lambda key: key in yolo_sessions},
        "hermes_cli.personality": {"active_personality_name": lambda cfg: cfg["display"]["personality"],
                                   "available_personalities": lambda cfg: {"pirate": "Talk like a pirate", "kind": "Be kind"},
                                   "describe_personality": lambda prompt, width=50: prompt[:width]},
        "gateway.session_usage": {"usage_stats": lambda agent: {"input_tokens": 1200, "output_tokens": 300,
                                                                "total_tokens": 1500, "context_tokens": 9000,
                                                                "context_length": 200000, "model": "x"}},
        "gateway.run": {"_gateway_session_db_inner": lambda runner: runner.db,
                        "_profile_runtime_scope": lambda home, hydrate_secrets=True: __import__("contextlib").nullcontext()},
    }
    for name, attrs in modules.items():
        module = types.ModuleType(name)
        for attr, value in attrs.items():
            setattr(module, attr, value)
        monkeypatch.setitem(sys.modules, name, module)
    for parent in ("hermes_cli", "gateway", "agent", "tools"):
        monkeypatch.setitem(sys.modules, parent, types.ModuleType(parent))
    return yolo_sessions


class FakeRunner:
    def __init__(self, override=None, reasoning=None, tier=None, agent=True, row=None):
        self._override, self._reasoning, self._tier = override, reasoning, tier
        self._agent = object() if agent else None
        self.db = SimpleNamespace(get_session=lambda sid: row)
        self.session_store = SimpleNamespace(lookup_by_session_key=lambda key: SimpleNamespace(session_id="s1", yolo=None))

    def _session_key_for_source(self, source):
        return "agent:main:lekora:dm:" + source.chat_id

    def _session_model_override(self, key):
        return self._override

    def _resolve_session_reasoning_config(self, source=None, session_key=None, model=""):
        return self._reasoning

    def _peek_session_state(self, key):
        return SimpleNamespace(conversation=SimpleNamespace(reasoning_override=self._reasoning))

    def _resolve_session_service_tier(self, session_key=None):
        return self._tier

    def _resident_agent_for(self, key):
        return self._agent


def test_reads_every_setting(fake_hermes, tmp_path):
    fake_hermes.add("agent:main:lekora:dm:default")
    runner = FakeRunner(override={"model": "deepseek/v4", "provider": "openrouter"},
                        reasoning={"enabled": True, "effort": "high"}, tier="priority",
                        row={"title": "Ramen plans", "estimated_cost_usd": 0.0123, "actual_cost_usd": None,
                             "input_tokens": 5000, "output_tokens": 800})
    got = hermes_settings.read_settings(runner, SimpleNamespace(chat_id="default"), tmp_path)
    assert got["model"] == {"model": "deepseek/v4", "provider": "openrouter", "this_chat": True}
    assert got["reasoning"] == {"effort": "high", "this_chat": True}
    assert got["fast"] == "fast" and got["yolo"] is True and got["show_reasoning"] is True
    assert got["approvals"] == "smart"
    assert got["personality"]["current"] == "pirate" and [o["name"] for o in got["personality"]["options"]] == ["kind", "pirate"]
    assert got["title"] == "Ramen plans"
    assert got["usage"]["context_tokens"] == 9000 and got["usage"]["cost_usd"] == 0.0123
    assert got["usage"]["input_tokens"] == 5000, "the session record's totals"


def test_defaults_and_a_broken_part(fake_hermes, tmp_path, monkeypatch):
    runner = FakeRunner(reasoning=None, tier=None, agent=False, row=None)
    monkeypatch.setattr(runner, "_resolve_session_service_tier", lambda session_key=None: 1 / 0)  # a Hermes change
    got = hermes_settings.read_settings(runner, SimpleNamespace(chat_id="default"), tmp_path)
    assert got["model"] == {"model": "claude-opus-5-5", "provider": "anthropic", "this_chat": False}
    assert got["reasoning"] == {"effort": "medium", "this_chat": False}
    assert got["fast"] is None, "unknown, the rest still read"
    assert got["yolo"] is False and got["usage"] is None and got["title"] is None
