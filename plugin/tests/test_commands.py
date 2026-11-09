"""Slash command lists (docs/slash-commands.md)."""

import sys
import types
from dataclasses import dataclass, field

import pytest

from lekora import hermes_commands
from lekora.profiles import profile_home
from tests.test_gateway import PROFILES, env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import hello_rev


# ---- the gateway side ------------------------------------------------------------

async def phone(gw, store):
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(ws)
    return ws


async def test_commands_list_for_an_agent(gw, store):
    asked = []

    def provider(profile_id):
        asked.append(profile_id)
        return [{"name": "new", "description": "Start a new session", "args": "", "choices": [],
                 "aliases": ["reset"], "group": "hermes", "category": "Session"}]
    gw.commands_provider = provider
    ws = await phone(gw, store)
    await ws.send(env(store, "commands.list", {}, profile_id="coder", msg_id="k1"))
    reply = await recv(ws)
    assert reply["type"] == "commands.list.result" and reply["id"] == "k1" and reply["profile_id"] == "coder"
    assert reply["data"]["commands"][0]["name"] == "new" and len(reply["data"]["fingerprint"]) == 16
    assert asked == ["coder"]
    await ws.send(env(store, "commands.list", {}, profile_id="coder", msg_id="k2"))
    assert (await recv(ws))["data"]["fingerprint"] == reply["data"]["fingerprint"], "same list, same fingerprint"
    await ws.close()


async def test_commands_list_survives_a_failing_provider(gw, store):
    def broken(profile_id):
        raise RuntimeError("Hermes changed")
    gw.commands_provider = broken
    ws = await phone(gw, store)
    await ws.send(env(store, "commands.list", {}, profile_id="assistant", msg_id="k1"))
    assert (await recv(ws))["data"]["commands"] == []
    await ws.send(env(store, "commands.list", {}, profile_id="nobody", msg_id="k2"))
    assert (await recv(ws))["data"]["code"] == "UNKNOWN_PROFILE"
    await ws.close()


def test_profile_home(tmp_path):
    assert profile_home("default", tmp_path) == tmp_path
    assert profile_home("bruce", tmp_path) == tmp_path / "profiles" / "bruce"


# ---- reading Hermes' own lists (stand-ins for Hermes' modules) ----------------------

@dataclass
class CommandDef:
    name: str
    description: str
    category: str = "Session"
    aliases: tuple = ()
    args_hint: str = ""

    def describe(self):
        return self.description + " (localized)"


@pytest.fixture
def fake_hermes(monkeypatch):
    homes = []
    state = types.SimpleNamespace(
        builtin=[CommandDef("new", "Start a new session", aliases=("reset",)),
                 CommandDef("approvals", "Approval mode", "Configuration", args_hint="[manual|smart|off]")],
        entries=[("standup", "Post the daily standup", "", "standup"),
                 ("ramen-finder", "Find ramen nearby", "/ramen-finder", "ramen-finder")],
        plugin_meta={"standup": {"args_hint": "[team]"}},
        quick={"deploy": {"type": "exec", "command": "make deploy"},
               "fast": {"type": "alias", "target": "/model fast", "description": "Switch to the fast model"}},
        fail_builtin=False)

    constants = types.ModuleType("hermes_constants")
    constants.set_hermes_home_override = lambda home: homes.append(home) or "token"
    constants.reset_hermes_home_override = lambda token: homes.append("reset")
    commands = types.ModuleType("hermes_cli.commands")
    commands.SUBCOMMANDS = {"/approvals": ["manual", "smart", "off"]}
    commands.category_label = lambda c: c.upper()
    platforms = types.ModuleType("hermes_cli.commands_platforms")

    def available():
        if state.fail_builtin:
            raise AttributeError("renamed in a Hermes update")
        return state.builtin
    platforms._gateway_available_commands = available
    platforms._collect_gateway_skill_entries = lambda platform, max_slots, reserved, desc_limit=100: (
        [e for e in state.entries if e[0] not in reserved], 0)
    plugins = types.ModuleType("hermes_cli.plugins")
    plugins.get_plugin_commands = lambda: state.plugin_meta
    config = types.ModuleType("hermes_cli.config")
    config.read_raw_config = lambda: {"quick_commands": state.quick}
    package = types.ModuleType("hermes_cli")
    for name, module in {"hermes_constants": constants, "hermes_cli": package, "hermes_cli.commands": commands,
                         "hermes_cli.commands_platforms": platforms, "hermes_cli.plugins": plugins,
                         "hermes_cli.config": config}.items():
        monkeypatch.setitem(sys.modules, name, module)
    state.homes = homes
    return state


def test_lists_builtin_plugin_skill_and_quick_commands(fake_hermes, tmp_path):
    commands = hermes_commands.list_commands(tmp_path / "profiles" / "bruce")
    assert fake_hermes.homes == [str(tmp_path / "profiles" / "bruce"), "reset"], "read in the agent's own profile"
    by_name = {c["name"]: c for c in commands}
    assert list(by_name) == ["new", "approvals", "standup", "ramen-finder", "deploy", "fast"]
    assert by_name["new"] == {"name": "new", "description": "Start a new session (localized)", "args": "",
                              "choices": [], "aliases": ["reset"], "group": "hermes", "category": "SESSION"}
    assert by_name["approvals"]["choices"] == ["manual", "smart", "off"]
    assert by_name["standup"]["group"] == "plugin" and by_name["standup"]["args"] == "[team]"
    assert by_name["ramen-finder"]["group"] == "skill"
    assert by_name["deploy"]["description"] == "Runs: make deploy"
    assert by_name["fast"]["description"] == "Switch to the fast model" and by_name["fast"]["group"] == "quick"


def test_a_broken_source_leaves_the_others(fake_hermes, tmp_path):
    fake_hermes.fail_builtin = True
    names = [c["name"] for c in hermes_commands.list_commands(tmp_path)]
    assert names == ["standup", "ramen-finder", "deploy", "fast"]


def test_quick_command_shadowed_by_a_builtin_is_left_out(fake_hermes, tmp_path):
    fake_hermes.quick = {"new": {"type": "exec", "command": "echo hi"}}
    names = [c["name"] for c in hermes_commands.list_commands(tmp_path)]
    assert names.count("new") == 1
