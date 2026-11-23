"""MCP servers for every agent, from one page (docs/mcp.md)."""

import asyncio
import json

import pytest

from lekora.mcp import Mcp, McpError, registry_config, registry_option, registry_result
from tests.test_gateway import env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev

CATALOG = [
    {"name": "linear", "description": "Linear issues", "auth": "oauth", "needs": [], "preregistered": False,
     "url": "https://mcp.linear.app/mcp"},
    {"name": "n8n", "description": "n8n workflows", "auth": "none", "preregistered": False,
     "needs": [{"name": "N8N_URL", "prompt": "Your n8n address", "secret": False, "required": True},
               {"name": "N8N_KEY", "prompt": "API key", "secret": True, "required": True}]},
    {"name": "asana", "description": "Asana", "auth": "oauth", "needs": [], "preregistered": True},
]

REMOTE = {"server": {"name": "ai.smithery/smithery-notion", "description": "Notion", "version": "1.0.0",
                     "remotes": [{"type": "streamable-http", "url": "https://server.smithery.ai/notion/mcp",
                                  "headers": [{"name": "Authorization", "value": "Bearer {smithery_api_key}",
                                               "isSecret": True, "isRequired": True, "description": "Smithery key"}]}]}}
OPEN_REMOTE = {"server": {"name": "io.github.acme/weather", "description": "Weather", "version": "2.0.0",
                          "remotes": [{"type": "streamable-http", "url": "https://weather.example/mcp"}]}}
PACKAGE = {"server": {"name": "com.foreverworks/notion", "description": "Notion files", "version": "0.1.1",
                      "packages": [{"registryType": "npm", "identifier": "@foreverworks/mcp-notion", "version": "0.1.1",
                                    "transport": {"type": "stdio"},
                                    "environmentVariables": [{"name": "NOTION_TOKEN", "isSecret": True, "isRequired": True},
                                                             {"name": "NOTION_REGION", "default": "eu"}]}]}}
NEEDS_ARGS = {"server": {"name": "x/needs-args", "version": "1",
                         "packages": [{"registryType": "pypi", "identifier": "needs-args", "transport": {"type": "stdio"},
                                       "packageArguments": [{"type": "positional", "isRequired": True}]}]}}


class Flow:
    def __init__(self):
        self.status, self.delivered, self.cancelled = "starting", None, False

    def snapshot(self):
        if self.status == "starting":
            self.status = "authorization_required"
        out = {"status": self.status}
        if self.status == "authorization_required":
            out["authorization_url"] = "https://auth.example/authorize?state=s1"
        if self.status == "approved":
            out["tools"] = [{"name": "list_issues", "description": "Issues"}]
        return out

    def deliver(self, code, state, error, iss):
        self.delivered = (code, state, error)
        self.status = "approved" if code and state == "s1" else "error"

    def cancel(self):
        self.cancelled = True


class Backend:
    def __init__(self):
        self.configs = {"default": {"linear": {"url": "https://mcp.linear.app/mcp", "auth": "oauth"},
                                    "ga4": {"command": "python3", "args": ["ga4.py"], "env": {"KEY": "${GA4_KEY}"},
                                            "tools": {"include": ["a", "b"]}}},
                        "coder": {"ga4": {"command": "python3", "args": ["ga4.py"], "enabled": False}}}
        self.env = {"default": {"GA4_KEY": "secret-1"}, "coder": {}}
        self.tokens = {("default", "linear")}
        self.probes = {}
        self.calls = []
        self.flow = Flow()

    def servers(self, p):
        return {k: dict(v) for k, v in self.configs.get(p, {}).items()}

    def plugin_owned(self, p):
        return set()

    def catalog(self):
        return [dict(e) for e in CATALOG]

    def install_catalog(self, p, name, values):
        self.calls.append(("install", p, name, dict(values)))
        self.configs.setdefault(p, {})[name] = {"url": f"https://{name}.example/mcp"}

    def save(self, p, name, config):
        if "evil" in json.dumps(config):
            from lekora.mcp import McpError
            raise McpError("REJECTED", "Hermes' safety check refused this server")
        self.calls.append(("save", p, name))
        self.configs.setdefault(p, {})[name] = config

    def remove(self, p, name):
        self.configs[p].pop(name)

    def set_enabled(self, p, name, enabled):
        self.configs[p][name]["enabled"] = enabled

    def save_secret(self, p, key, value):
        self.env.setdefault(p, {})[key] = value

    def secret(self, p, key):
        return self.env.get(p, {}).get(key)

    def signed_in(self, p, name):
        return (p, name) in self.tokens

    def copy_sign_in(self, a, b, name):
        if (a, name) in self.tokens:
            self.tokens.add((b, name))
            return True
        return False

    def probe(self, p, name):
        return self.probes.get(name, {"ok": True, "tools": [{"name": "t", "description": ""}]})

    def start_sign_in(self, p, name, redirect_uri):
        self.calls.append(("signin", p, name, redirect_uri))
        return self.flow

    def reload(self, p):
        self.calls.append(("reload", p))

    def has_runner(self, command):
        return command in ("npx", "uvx")


class Origins:
    def __init__(self):
        self.rows = {}

    def get(self, name):
        return self.rows.get(name)

    def set(self, name, info):
        if info is None:
            self.rows.pop(name, None)
        else:
            self.rows[name] = info


@pytest.fixture
def backend():
    return Backend()


@pytest.fixture
def mcp(backend):
    backups = []
    registry = {"servers": [REMOTE, OPEN_REMOTE, PACKAGE, NEEDS_ARGS, PACKAGE]}
    m = Mcp(profiles=lambda: ["default", "coder", "writer"], backend=backend, backup=backups.append,
            origins=Origins(), fetch_json=lambda url: registry)
    m.backups = backups
    return m


def test_every_server_once_with_the_agents_that_have_it(mcp):
    got = {s["name"]: s for s in mcp.all()}
    assert set(got) == {"linear", "ga4"}
    assert got["linear"]["source"] == "catalog" and got["linear"]["auth"] == "oauth"
    assert got["linear"]["agents"] == [{"profile_id": "default", "enabled": True, "tools": "all", "signed_in": True}]
    ga4 = got["ga4"]
    assert ga4["source"] == "custom" and ga4["kind"] == "command" and ga4["auth"] == "key"
    assert [(a["profile_id"], a["enabled"], a["tools"]) for a in ga4["agents"]] == [
        ("default", True, "2 selected"), ("coder", False, "all")]
    assert "secret-1" not in json.dumps(got), "secrets never go to the phone"


def test_the_catalog_says_who_has_each(mcp):
    found = mcp.catalog("lin")
    assert [e["name"] for e in found] == ["linear"] and found[0]["installed_for"] == ["default"] and found[0]["vetted"]


def test_registry_servers_become_hermes_configs():
    remote = registry_option(REMOTE["server"], lambda c: False)
    assert remote["kind"] == "url" and remote["needs"][0]["name"] == "smithery_api_key"
    config, store = registry_config(remote, "notion", {"smithery_api_key": "sk-1"})
    assert config == {"url": "https://server.smithery.ai/notion/mcp",
                      "headers": {"Authorization": "Bearer ${MCP_NOTION_SMITHERY_API_KEY}"}}
    assert store == {"MCP_NOTION_SMITHERY_API_KEY": "sk-1"}, "the key goes to the agent's .env, not config.yaml"
    with pytest.raises(McpError):
        registry_config(remote, "notion", {})

    package = registry_option(PACKAGE["server"], lambda c: c == "npx")
    config, store = registry_config(package, "notion", {"NOTION_TOKEN": "nt-1"})
    assert config == {"command": "npx", "args": ["-y", "@foreverworks/mcp-notion@0.1.1"],
                      "env": {"NOTION_TOKEN": "${NOTION_TOKEN}", "NOTION_REGION": "eu"}}
    assert store == {"NOTION_TOKEN": "nt-1"}
    missing = registry_option(PACKAGE["server"], lambda c: False)
    assert not missing["runnable"] and "npx" in missing["reason"]
    assert not registry_option(NEEDS_ARGS["server"], lambda c: True)["runnable"]
    result = registry_result(REMOTE, lambda c: False)
    assert result["vetted"] is False and result["name"] == "smithery-notion"


async def test_searching_the_registry_marks_every_result_not_vetted(mcp):
    found = await mcp.search_registry("notion")
    assert [r["id"] for r in found] == ["ai.smithery/smithery-notion", "io.github.acme/weather",
                                        "com.foreverworks/notion", "x/needs-args"], "one entry per server"
    assert all(r["vetted"] is False for r in found)
    assert found[3]["runnable"] is False and found[3]["reason"]
    assert await mcp.search_registry("  ") == []


async def test_adding_from_the_catalog_for_several_agents(mcp, backend):
    with pytest.raises(McpError) as missing:
        await mcp.add({"source": "catalog", "name": "n8n", "to": ["coder"], "values": {"N8N_URL": "https://n8n.me"}})
    assert missing.value.code == "MISSING_VALUE"
    got = await mcp.add({"source": "catalog", "name": "n8n", "to": ["coder", "writer"],
                         "values": {"N8N_URL": "https://n8n.me", "N8N_KEY": "k-1"}})
    assert got["added"] == ["coder", "writer"] and got["test"]["ok"]
    assert backend.env["coder"]["N8N_KEY"] == "k-1" and backend.env["writer"]["N8N_KEY"] == "k-1"
    assert ("install", "coder", "n8n", {"N8N_URL": "https://n8n.me", "N8N_KEY": "k-1"}) in backend.calls
    assert mcp.backups == ["coder", "writer"], "each agent's config backed up first"
    assert ("reload", "coder") in backend.calls and ("reload", "writer") in backend.calls
    again = await mcp.add({"source": "catalog", "name": "n8n", "to": ["coder"], "values": {"N8N_URL": "x", "N8N_KEY": "y"}})
    assert again["added"] == [], "an agent that has it is left alone"
    with pytest.raises(McpError) as asana:
        await mcp.add({"source": "catalog", "name": "asana", "to": ["coder"]})
    assert asana.value.code == "SIGN_IN_ON_HERMES"


async def test_a_registry_server_that_wants_an_account_gets_a_sign_in(mcp, backend):
    backend.probes["weather"] = {"ok": False, "failure": "auth_required", "error": "401"}
    got = await mcp.add({"source": "registry", "id": "io.github.acme/weather", "to": ["default", "coder"]})
    assert got["name"] == "weather" and got["test"]["sign_in"] is True
    assert backend.configs["default"]["weather"] == {"url": "https://weather.example/mcp", "auth": "oauth"}
    assert backend.configs["coder"]["weather"]["auth"] == "oauth"
    listed = {s["name"]: s for s in mcp.all()}["weather"]
    assert listed["source"] == "registry" and listed["description"] == "Weather"
    assert all(a["signed_in"] is False for a in listed["agents"])


async def test_adding_your_own(mcp, backend):
    got = await mcp.add({"source": "custom", "name": "mine", "url": "https://mine.example/mcp", "bearer": "tok",
                         "to": ["coder"]})
    assert got["added"] == ["coder"]
    assert backend.configs["coder"]["mine"]["headers"] == {"Authorization": "Bearer ${MCP_MINE_API_KEY}"}
    assert backend.env["coder"]["MCP_MINE_API_KEY"] == "tok"
    bad = await mcp.add({"source": "custom", "name": "bad", "command": "sh", "args": ["-c", "evil"], "to": ["coder"]})
    assert bad["added"] == [] and "safety" in bad["failed"][0]["reason"], "Hermes' check refuses it"
    for wrong in ({"name": "Bad Name", "url": "https://x"}, {"name": "x", "url": "ftp://x"}, {"name": "x"}):
        with pytest.raises(McpError):
            await mcp.add({"source": "custom", "to": ["coder"], **wrong})


async def test_giving_another_agent_a_server_shares_its_keys_and_sign_in(mcp, backend):
    got = await mcp.copy("default", "ga4", ["coder", "writer"])
    assert got["added"] == ["writer"], "coder has it already"
    assert backend.env["writer"]["GA4_KEY"] == "secret-1", "copied on the instance, not through the phone"
    got = await mcp.copy("default", "linear", ["coder"])
    assert got["added"] == ["coder"] and ("coder", "linear") in backend.tokens


async def test_on_off_and_remove_back_up_first(mcp, backend, ):
    await mcp.set_enabled("coder", "ga4", True)
    assert backend.configs["coder"]["ga4"]["enabled"] is True and mcp.backups == ["coder"]
    mcp._origins.set("ga4", {"source": "custom"})
    await mcp.remove("coder", "ga4")
    assert "ga4" not in backend.configs["coder"] and mcp._origins.get("ga4"), "default still has it"
    await mcp.remove("default", "ga4")
    assert mcp._origins.get("ga4") is None
    with pytest.raises(McpError):
        await mcp.remove("coder", "ga4")
    with pytest.raises(McpError):
        await mcp.set_enabled("nobody", "linear", True)


async def test_signing_in_on_the_phone_then_sharing_it(mcp, backend):
    backend.configs["coder"]["linear"] = {"url": "https://mcp.linear.app/mcp", "auth": "oauth"}
    backend.tokens.clear()
    with pytest.raises(McpError):
        await mcp.sign_in_start("default", "linear", "https://evil.example/cb")
    started = await mcp.sign_in_start("default", "linear", "lekora://mcp-oauth", share_with=["coder"])
    assert started["status"] == "authorization_required" and started["authorization_url"].startswith("https://auth.")
    assert ("signin", "default", "linear", "lekora://mcp-oauth") in backend.calls
    backend.tokens.add(("default", "linear"))  # what Hermes saves when it's approved
    done = await mcp.sign_in_finish(started["flow_id"], "lekora://mcp-oauth?code=c1&state=s1")
    assert backend.flow.delivered == ("c1", "s1", None)
    assert done["status"] == "approved" and done["tools"][0]["name"] == "list_issues"
    assert ("coder", "linear") in backend.tokens, "the same sign-in for the other agent"
    with pytest.raises(McpError):
        await mcp.sign_in_finish(started["flow_id"], "lekora://mcp-oauth?code=c1&state=s1")
    with pytest.raises(McpError):
        await mcp.sign_in_start("default", "ga4", "lekora://mcp-oauth")


async def test_the_phone_lists_adds_and_gets_errors(gw, store, mcp):
    gw.mcp = mcp
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)
    await ws.send(env(store, "mcp.all", {}, msg_id="m1"))
    got = [m for m in await drain(ws) if m.get("id") == "m1"][0]
    assert got["type"] == "mcp.all.result" and {s["name"] for s in got["data"]["servers"]} == {"linear", "ga4"}
    await ws.send(env(store, "mcp.registry.search", {"query": "notion"}, msg_id="m2"))
    got = [m for m in await drain(ws) if m.get("id") == "m2"][0]
    assert got["data"]["results"][0]["vetted"] is False
    await ws.send(env(store, "mcp.enable", {"name": "ga4", "enabled": True}, profile_id="coder", msg_id="m3"))
    got = [m for m in await drain(ws) if m.get("id") == "m3"][0]
    assert got["data"] == {"name": "ga4", "enabled": True}
    await ws.send(env(store, "mcp.remove", {"name": "nope"}, profile_id="coder", msg_id="m4"))
    err = [m for m in await drain(ws) if m.get("id") == "m4"][0]
    assert err["type"] == "error" and err["data"]["code"] == "UNKNOWN_SERVER"
    await ws.send(env(store, "mcp.all", {}, msg_id="m5"))
    assert [m for m in await drain(ws) if m.get("id") == "m5"][0]["type"] == "mcp.all.result", "still connected"


def test_where_a_server_came_from_is_kept(store):
    store.set_mcp_origin("weather", {"source": "registry", "id": "io.github.acme/weather"})
    assert store.mcp_origin("weather")["source"] == "registry"
    store.set_mcp_origin("weather", None)
    assert store.mcp_origin("weather") is None
