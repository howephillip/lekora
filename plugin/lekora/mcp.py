"""MCP servers for every agent, from one page (docs/mcp.md).

Hermes keeps MCP servers per agent (``mcp_servers`` in its config.yaml). This module adds them up
across agents and makes the changes the owner allowed (rule 8 exception, 2026-11-22): add, remove,
on/off and sign-in, each after a backup of that agent's config, through Hermes' own helpers (passed
in as ``backend``; see ``hermes_mcp.py``). Nothing here imports Hermes.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import secrets
import time
from typing import Any, Callable, Iterable, Optional, Protocol
from urllib.parse import parse_qs, urlencode, urlparse

log = logging.getLogger(__name__)

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,47}$")
VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")
PLACEHOLDER_RE = re.compile(r"\{([A-Za-z_][A-Za-z0-9_]*)\}")
REGISTRY = "https://registry.modelcontextprotocol.io/v0/servers"
RUNNERS = {"npm": "npx", "pypi": "uvx", "oci": "docker"}
SIGNIN_WAIT = 25.0
CALLBACK_WAIT = 90.0


class McpError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


class Flow(Protocol):
    def snapshot(self) -> dict: ...
    def deliver(self, code: Optional[str], state: Optional[str], error: Optional[str], iss: Optional[str]) -> None: ...
    def cancel(self) -> None: ...


class Backend(Protocol):
    """What Hermes does for us, always inside the given agent's profile."""
    def servers(self, profile_id: str) -> dict[str, dict]: ...
    def plugin_owned(self, profile_id: str) -> set[str]: ...
    def catalog(self) -> list[dict]: ...
    def install_catalog(self, profile_id: str, name: str, values: dict[str, str]) -> None: ...
    def save(self, profile_id: str, name: str, config: dict) -> None: ...
    def remove(self, profile_id: str, name: str) -> None: ...
    def set_enabled(self, profile_id: str, name: str, enabled: bool) -> None: ...
    def save_secret(self, profile_id: str, key: str, value: str) -> None: ...
    def secret(self, profile_id: str, key: str) -> Optional[str]: ...
    def signed_in(self, profile_id: str, name: str) -> bool: ...
    def copy_sign_in(self, from_profile: str, to_profile: str, name: str) -> bool: ...
    def probe(self, profile_id: str, name: str) -> dict: ...
    def start_sign_in(self, profile_id: str, name: str, redirect_uri: str) -> Flow: ...
    def reload(self, profile_id: str) -> None: ...
    def has_runner(self, command: str) -> bool: ...


def _sanitize(name: str) -> str:
    out = re.sub(r"[^a-z0-9_-]+", "-", name.lower()).strip("-_")[:48]
    return out or "server"


def _env_name(server: str, key: str) -> str:
    return re.sub(r"[^A-Z0-9_]", "_", f"MCP_{server}_{key}".upper())


def _vars(value: Any) -> set[str]:
    """Every ${VAR} a config refers to."""
    if isinstance(value, str):
        return set(VAR_RE.findall(value))
    if isinstance(value, dict):
        return set().union(*(_vars(v) for v in value.values())) if value else set()
    if isinstance(value, list):
        return set().union(*(_vars(v) for v in value)) if value else set()
    return set()


def with_transport(config: dict, remote_type: Optional[str] = None) -> dict:
    """An address that serves the older SSE style (registry type ``sse``, or a path ending in /sse) is
    marked ``transport: sse``; Hermes otherwise speaks the newer style to it, which such servers refuse
    with "Not Found" (owner's PayPal test, 2026-11-22: even Hermes' own catalog entry lacks it)."""
    url = str(config.get("url") or "")
    if url and "transport" not in config and (remote_type == "sse" or urlparse(url).path.rstrip("/").endswith("/sse")):
        return {**config, "transport": "sse"}
    return config


def _tools_label(config: dict) -> str:
    tools = config.get("tools") if isinstance(config.get("tools"), dict) else {}
    if isinstance(tools.get("include"), list):
        return f"{len(tools['include'])} selected"
    if isinstance(tools.get("exclude"), list) and tools["exclude"]:
        return f"{len(tools['exclude'])} left out"
    return "all"


# ---- the public registry ------------------------------------------------------------------

def registry_option(server: dict, has_runner: Callable[[str], bool]) -> dict:
    """How a registry server would run here: the best remote, else a package whose runner is installed.
    ``{kind: url|command, needs: [...], runnable, reason?, ...}``."""
    remotes = [r for r in server.get("remotes") or [] if isinstance(r, dict) and r.get("url")]
    remotes.sort(key=lambda r: 0 if r.get("type") == "streamable-http" else 1)
    if remotes:
        remote = remotes[0]
        needs, headers = [], {}
        for h in remote.get("headers") or []:
            if not isinstance(h, dict) or not h.get("name"):
                continue
            template = str(h.get("value") or "{value}")
            keys = PLACEHOLDER_RE.findall(template) or ["value"]
            if not PLACEHOLDER_RE.findall(template):
                template = "{value}"
            for key in keys:
                needs.append({"name": key, "prompt": h.get("description") or h["name"],
                              "secret": bool(h.get("isSecret", True)), "required": bool(h.get("isRequired", False))})
            headers[h["name"]] = template
        return {"kind": "url", "url": remote["url"], "transport": remote.get("type"), "headers": headers,
                "needs": needs, "runnable": True}
    reasons = []
    for package in server.get("packages") or []:
        if not isinstance(package, dict) or not package.get("identifier"):
            continue
        registry_type = package.get("registryType")
        runner = RUNNERS.get(registry_type)
        if runner is None:
            reasons.append(f"{registry_type} packages aren't supported")
            continue
        if (package.get("transport") or {}).get("type", "stdio") != "stdio":
            reasons.append("its package doesn't run as a command")
            continue
        if any(isinstance(a, dict) and a.get("isRequired") and not (a.get("value") or a.get("default"))
               for a in (package.get("packageArguments") or []) + (package.get("runtimeArguments") or [])):
            reasons.append("it needs start-up arguments the app can't set yet")
            continue
        if not has_runner(runner):
            reasons.append(f"it needs {runner}, which isn't installed on the Hermes machine")
            continue
        needs = [{"name": v["name"], "prompt": v.get("description") or v["name"], "secret": bool(v.get("isSecret", False)),
                  "required": bool(v.get("isRequired", False)), **({"default": str(v["default"])} if v.get("default") else {})}
                 for v in package.get("environmentVariables") or [] if isinstance(v, dict) and v.get("name")]
        return {"kind": "command", "runner": runner, "package": package["identifier"],
                "version": package.get("version") or "", "registry_type": registry_type, "needs": needs, "runnable": True}
    return {"kind": None, "needs": [], "runnable": False,
            "reason": reasons[0] if reasons else "It doesn't say how to run it"}


def registry_config(option: dict, server_name: str, values: dict[str, str]) -> tuple[dict, dict[str, str]]:
    """Hermes' config for a registry server, and the secrets to store (env name -> value)."""
    store: dict[str, str] = {}

    def value_for(need: dict) -> str:
        given = values.get(need["name"])
        if given is None or given == "":
            if need.get("default"):
                return need["default"]
            if need.get("required"):
                raise McpError("MISSING_VALUE", f"{need['prompt']} is needed")
            return ""
        if need.get("secret"):
            env = _env_name(server_name, need["name"]) if option["kind"] == "url" else need["name"]
            store[env] = given
            return "${" + env + "}"
        return given

    if option["kind"] == "url":
        filled = {n["name"]: value_for(n) for n in option["needs"]}
        headers = {}
        for header, template in option["headers"].items():
            text = PLACEHOLDER_RE.sub(lambda m: filled.get(m.group(1), ""), template).strip()
            if text and text.lower() != "bearer":
                headers[header] = text
        config: dict[str, Any] = {"url": option["url"]}
        if headers:
            config["headers"] = headers
        return with_transport(config, option.get("transport")), store
    env = {}
    for need in option["needs"]:
        got = value_for(need)
        if got:
            env[need["name"]] = got
    package, version = option["package"], option["version"]
    if option["runner"] == "npx":
        args = ["-y", f"{package}@{version}" if version else package]
    elif option["runner"] == "uvx":
        args = [f"{package}=={version}" if version else package]
    else:
        args = ["run", "-i", "--rm", *[a for k in env for a in ("-e", k)], f"{package}:{version}" if version else package]
    config = {"command": option["runner"], "args": args}
    if env:
        config["env"] = env
    return config, store


def registry_result(item: dict, has_runner: Callable[[str], bool]) -> Optional[dict]:
    server = item.get("server") if isinstance(item.get("server"), dict) else item
    if not isinstance(server, dict) or not server.get("name"):
        return None
    option = registry_option(server, has_runner)
    out = {"id": server["name"], "name": _sanitize(server["name"].rsplit("/", 1)[-1]),
           "title": server.get("title") or server["name"].rsplit("/", 1)[-1],
           "description": server.get("description") or "", "version": server.get("version") or "",
           "kind": option["kind"], "needs": [{k: n[k] for k in ("name", "prompt", "secret", "required", "default") if k in n}
                                               for n in option["needs"]],
           "runnable": option["runnable"], "vetted": False}
    for key in ("websiteUrl", "repository"):
        if server.get(key):
            out["website" if key == "websiteUrl" else "repository"] = (
                server[key] if isinstance(server[key], str) else (server[key] or {}).get("url"))
    if not option["runnable"]:
        out["reason"] = option["reason"]
    return out


def fetch_json(url: str, timeout: float = 20) -> Any:
    """A public JSON document (the MCP registry)."""
    from urllib.request import Request, urlopen
    from .openrouter_catalog import _ssl_context
    with urlopen(Request(url, headers={"Accept": "application/json", "User-Agent": "Lekora"}), timeout=timeout,
                 context=_ssl_context()) as r:
        return json.loads(r.read(5_000_000))


class Mcp:
    def __init__(self, profiles: Callable[[], Iterable[str]], backend: Backend, backup: Callable[[str], Any],
                 origins: Any, fetch_json: Callable[[str], Any], clock: Callable[[], float] = time.monotonic) -> None:
        self._profiles = profiles
        self._backend = backend
        self._backup = backup                # profile_id -> backs up its config.yaml first (rule 8)
        self._origins = origins              # where each server came from (Lekora's store)
        self._fetch = fetch_json
        self._clock = clock
        self._flows: dict[str, dict] = {}

    def _agent(self, profile_id: Any) -> str:
        if not isinstance(profile_id, str) or profile_id not in set(self._profiles()):
            raise McpError("UNKNOWN_PROFILE", "Unknown agent")
        return profile_id

    def _agents(self, ids: Any) -> list[str]:
        if not isinstance(ids, list) or not ids:
            raise McpError("INVALID_REQUEST", "Which agents?")
        return [self._agent(p) for p in dict.fromkeys(ids)]

    def _config(self, profile_id: str, name: Any) -> dict:
        got = self._backend.servers(profile_id).get(name) if isinstance(name, str) else None
        if got is None:
            raise McpError("UNKNOWN_SERVER", "That server isn't there any more")
        return got

    def _repair(self, profile_id: str, name: str) -> dict:
        """An entry saved before Lekora marked SSE servers (or by Hermes' own catalog) gets ``transport: sse``
        now, after a backup (owner's PayPal test, 2026-11-22: it was added before the fix)."""
        config = self._config(profile_id, name)
        fixed = with_transport(config)
        if fixed != config and name not in self._backend.plugin_owned(profile_id):
            self._backup(profile_id)
            self._backend.save(profile_id, name, fixed)
            log.info("Lekora: %s's MCP server %s marked as SSE so Hermes can reach it (config backed up first)",
                     profile_id, name)
        return fixed

    def _not_plugins(self, profile_id: str, name: str) -> None:
        if name in self._backend.plugin_owned(profile_id):
            raise McpError("INVALID_REQUEST", "Another Hermes plugin manages this server")

    # ---- reading -------------------------------------------------------------

    def all(self) -> list[dict]:
        catalog = {e["name"]: e for e in self._backend.catalog()}
        merged: dict[str, dict] = {}
        for profile_id in self._profiles():
            plugins = self._backend.plugin_owned(profile_id)
            for name, config in self._backend.servers(profile_id).items():
                entry = merged.get(name)
                if entry is None:
                    origin = self._origins.get(name) or {}
                    source = ("plugin" if name in plugins else origin.get("source")
                              or ("catalog" if name in catalog else "custom"))
                    entry = merged[name] = {
                        "name": name, "source": source,
                        "description": origin.get("description") or (catalog.get(name) or {}).get("description") or "",
                        "kind": "url" if config.get("url") else "command",
                        "auth": "oauth" if config.get("auth") == "oauth" else "key" if _vars(config) else "none",
                        "agents": []}
                    if config.get("url"):
                        entry["url"] = str(config["url"])
                    elif config.get("command"):
                        entry["command"] = " ".join([str(config["command"]), *map(str, config.get("args") or [])])[:200]
                agent = {"profile_id": profile_id, "enabled": config.get("enabled", True) is not False,
                         "tools": _tools_label(config)}
                if config.get("auth") == "oauth":
                    agent["signed_in"] = self._backend.signed_in(profile_id, name)
                entry["agents"].append(agent)
        return sorted(merged.values(), key=lambda s: s["name"])

    def catalog(self, query: Any = "") -> list[dict]:
        words = str(query or "").lower().split()
        have: dict[str, list[str]] = {}
        for profile_id in self._profiles():
            for name in self._backend.servers(profile_id):
                have.setdefault(name, []).append(profile_id)
        out = []
        for e in self._backend.catalog():
            text = f"{e['name']} {e.get('description', '')}".lower()
            if all(w in text for w in words):
                out.append({**e, "vetted": True, "installed_for": have.get(e["name"], [])})
        return out

    async def search_registry(self, query: Any) -> list[dict]:
        words = " ".join(str(query or "").split())[:100]
        if not words:
            return []
        url = f"{REGISTRY}?{urlencode({'search': words, 'limit': 30, 'version': 'latest'})}"
        try:
            got = await asyncio.to_thread(self._fetch, url)
        except Exception as exc:
            log.info("Lekora: the MCP registry search failed: %s", exc)
            raise McpError("REGISTRY_UNAVAILABLE", "The public registry couldn't be reached from your Hermes instance. "
                                                   "Try again in a moment.")
        items = got.get("servers") if isinstance(got, dict) else None
        out, seen = [], set()
        for item in items or []:
            result = registry_result(item, self._backend.has_runner) if isinstance(item, dict) else None
            if result and result["id"] not in seen:
                seen.add(result["id"])
                out.append(result)
        return out

    async def _registry_server(self, server_id: str) -> dict:
        url = f"{REGISTRY}?{urlencode({'search': server_id, 'limit': 50, 'version': 'latest'})}"
        got = await asyncio.to_thread(self._fetch, url)
        for item in (got or {}).get("servers") or []:
            server = item.get("server") if isinstance(item, dict) else None
            if isinstance(server, dict) and server.get("name") == server_id:
                return server
        raise McpError("UNKNOWN_SERVER", "The registry doesn't have that server any more")

    # ---- adding --------------------------------------------------------------

    async def add(self, data: dict) -> dict:
        """``{source: catalog|registry|custom, name | id, to: [agents], values: {name: value}, url?,
        bearer?, command?, args?, headers?}``. Agents that have it already are left alone."""
        source = data.get("source")
        targets = self._agents(data.get("to"))
        values = {str(k): str(v) for k, v in (data.get("values") or {}).items() if v is not None}
        description = ""
        if source == "catalog":
            entry = next((e for e in self._backend.catalog() if e["name"] == data.get("name")), None)
            if entry is None:
                raise McpError("UNKNOWN_SERVER", "Hermes' catalog doesn't have that server")
            if entry.get("preregistered"):
                raise McpError("SIGN_IN_ON_HERMES",
                               f"{entry['name']} signs in with a client registered on the Hermes machine. Install it "
                               f"there with: hermes mcp install {entry['name']}")
            name, description = entry["name"], entry.get("description") or ""
            for need in entry.get("needs") or []:
                if need.get("required") and not values.get(need["name"]) and not need.get("default"):
                    raise McpError("MISSING_VALUE", f"{need.get('prompt') or need['name']} is needed")

            def write(profile_id: str) -> None:
                for need in entry.get("needs") or []:
                    if need.get("secret") and values.get(need["name"]):
                        self._backend.save_secret(profile_id, need["name"], values[need["name"]])
                self._backend.install_catalog(profile_id, name, values)
                installed = self._backend.servers(profile_id).get(name)
                if installed is not None and with_transport(installed) != installed:
                    self._backend.save(profile_id, name, with_transport(installed))
        elif source == "registry":
            server = await self._registry_server(str(data.get("id") or ""))
            option = registry_option(server, self._backend.has_runner)
            if not option["runnable"]:
                raise McpError("CANT_RUN", f"It can't run here: {option['reason']}")
            name = self._free_name(_sanitize(str(data.get("name") or server["name"].rsplit("/", 1)[-1])), server["name"])
            description = server.get("description") or ""
            config, secrets_ = registry_config(option, name, values)

            def write(profile_id: str) -> None:
                for key, value in secrets_.items():
                    self._backend.save_secret(profile_id, key, value)
                self._backend.save(profile_id, name, dict(config))
        elif source == "custom":
            name = str(data.get("name") or "").strip().lower()
            if not NAME_RE.match(name):
                raise McpError("INVALID_REQUEST", "A name is lowercase letters, digits, - and _")
            config, secrets_ = self._custom_config(name, data)
            description = str(data.get("description") or "")[:200]

            def write(profile_id: str) -> None:
                for key, value in secrets_.items():
                    self._backend.save_secret(profile_id, key, value)
                self._backend.save(profile_id, name, dict(config))
        else:
            raise McpError("INVALID_REQUEST", "Add from where?")

        added, failed = [], []
        for profile_id in targets:
            if name in self._backend.servers(profile_id):
                await asyncio.to_thread(self._repair, profile_id, name)
                continue
            try:
                self._backup(profile_id)
                await asyncio.to_thread(write, profile_id)
                added.append(profile_id)
            except McpError as exc:
                failed.append({"profile_id": profile_id, "reason": exc.reason})
            except Exception as exc:
                failed.append({"profile_id": profile_id, "reason": str(getattr(exc, "reason", None) or exc)})
        if added:
            self._origins.set(name, {"source": source, "description": description,
                                     **({"id": data.get("id")} if source == "registry" else {})})
        out: dict[str, Any] = {"name": name, "added": added, "failed": failed}
        if added:
            out["test"] = await self._test_after_add(added, name)
            for profile_id in added:
                await asyncio.to_thread(self._backend.reload, profile_id)
        return out

    def _free_name(self, name: str, registry_id: str) -> str:
        taken = set().union(*(self._backend.servers(p).keys() for p in self._profiles())) if list(self._profiles()) else set()
        if name not in taken or (self._origins.get(name) or {}).get("id") == registry_id:
            return name
        n = 2
        while f"{name}-{n}" in taken:
            n += 1
        return f"{name}-{n}"

    def _custom_config(self, name: str, data: dict) -> tuple[dict, dict[str, str]]:
        store: dict[str, str] = {}
        url = str(data.get("url") or "").strip()
        command = str(data.get("command") or "").strip()
        if url:
            if not url.startswith(("https://", "http://")):
                raise McpError("INVALID_REQUEST", "The address starts with https://")
            config: dict[str, Any] = {"url": url}
            if data.get("bearer"):
                key = _env_name(name, "API_KEY")
                store[key] = str(data["bearer"])
                config["headers"] = {"Authorization": "Bearer ${" + key + "}"}
            elif data.get("oauth"):
                config["auth"] = "oauth"
            return with_transport(config), store
        if command:
            args = data.get("args") or []
            if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
                raise McpError("INVALID_REQUEST", "Arguments are a list of words")
            config = {"command": command, "args": list(args)}
            env = {}
            for key, value in (data.get("env") or {}).items():
                key = str(key)
                if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
                    raise McpError("INVALID_REQUEST", f"{key} isn't a valid setting name")
                store[key] = str(value)
                env[key] = "${" + key + "}"
            if env:
                config["env"] = env
            return config, store
        raise McpError("INVALID_REQUEST", "Give an address or a command")

    async def _test_after_add(self, added: list[str], name: str) -> dict:
        first = added[0]
        got = await asyncio.to_thread(self._backend.probe, first, name)
        if got.get("failure") == "auth_required":
            config = self._backend.servers(first).get(name) or {}
            if config.get("url") and config.get("auth") != "oauth" and not config.get("headers"):
                # It wants an account sign-in: Hermes needs the oauth marker for that.
                for profile_id in added:
                    cfg = dict(self._backend.servers(profile_id).get(name) or config, auth="oauth")
                    await asyncio.to_thread(self._backend.save, profile_id, name, cfg)
            got = {**got, "sign_in": True}
        elif (self._backend.servers(first).get(name) or {}).get("auth") == "oauth" and not got.get("ok"):
            got = {**got, "sign_in": True}
        return got

    async def copy(self, from_profile: Any, name: Any, to: Any) -> dict:
        """Gives agents a server another agent has: its entry, the secret values it refers to and its
        sign-in, all copied on the Hermes instance."""
        from_profile = self._agent(from_profile)
        config = self._config(from_profile, name)
        self._not_plugins(from_profile, name)
        added, failed = [], []
        for profile_id in self._agents(to):
            if profile_id == from_profile or name in self._backend.servers(profile_id):
                continue
            try:
                self._backup(profile_id)

                def write(target: str = profile_id) -> None:
                    for key in sorted(_vars(config)):
                        value = self._backend.secret(from_profile, key)
                        if value is not None:
                            self._backend.save_secret(target, key, value)
                    self._backend.save(target, name, json.loads(json.dumps(config)))
                    if config.get("auth") == "oauth":
                        self._backend.copy_sign_in(from_profile, target, name)
                await asyncio.to_thread(write)
                await asyncio.to_thread(self._backend.reload, profile_id)
                added.append(profile_id)
            except Exception as exc:
                failed.append({"profile_id": profile_id, "reason": str(getattr(exc, "reason", None) or exc)})
        return {"name": name, "added": added, "failed": failed}

    # ---- changing ------------------------------------------------------------

    async def set_enabled(self, profile_id: Any, name: Any, enabled: Any) -> dict:
        profile_id = self._agent(profile_id)
        self._config(profile_id, name)
        self._not_plugins(profile_id, name)
        if not isinstance(enabled, bool):
            raise McpError("INVALID_REQUEST", "On or off?")
        self._backup(profile_id)
        await asyncio.to_thread(self._backend.set_enabled, profile_id, name, enabled)
        await asyncio.to_thread(self._backend.reload, profile_id)
        log.info("Lekora: %s's MCP server %s turned %s (config backed up first)", profile_id, name, "on" if enabled else "off")
        return {"name": name, "enabled": enabled}

    async def remove(self, profile_id: Any, name: Any) -> dict:
        profile_id = self._agent(profile_id)
        self._config(profile_id, name)
        self._not_plugins(profile_id, name)
        self._backup(profile_id)
        await asyncio.to_thread(self._backend.remove, profile_id, name)
        await asyncio.to_thread(self._backend.reload, profile_id)
        if not any(name in self._backend.servers(p) for p in self._profiles()):
            self._origins.set(name, None)
        log.info("Lekora: %s's MCP server %s removed (config backed up first)", profile_id, name)
        return {"name": name}

    async def test(self, profile_id: Any, name: Any) -> dict:
        profile_id = self._agent(profile_id)
        config = await asyncio.to_thread(self._repair, profile_id, name)
        got = await asyncio.to_thread(self._backend.probe, profile_id, name)
        if config.get("auth") == "oauth" and not got.get("ok"):
            got = {**got, "sign_in": not self._backend.signed_in(profile_id, name)}
        return got

    # ---- sign-in (OAuth), on the phone -----------------------------------------

    async def sign_in_start(self, profile_id: Any, name: Any, redirect_uri: Any, share_with: Any = None) -> dict:
        profile_id = self._agent(profile_id)
        config = await asyncio.to_thread(self._repair, profile_id, name)
        if config.get("auth") != "oauth":
            raise McpError("INVALID_REQUEST", "This server doesn't use an account sign-in")
        if not isinstance(redirect_uri, str) or not redirect_uri.startswith(("lekora://", "http://127.0.0.1:")):
            raise McpError("INVALID_REQUEST", "Unsupported return address")
        share = [p for p in self._agents(share_with) if p != profile_id] if share_with else []
        self._backup(profile_id)
        flow = await asyncio.to_thread(self._backend.start_sign_in, profile_id, name, redirect_uri)
        flow_id = secrets.token_urlsafe(12)
        self._flows[flow_id] = {"flow": flow, "profile_id": profile_id, "name": name, "share": share}
        snap = await self._wait(flow, ("authorization_required", "approved", "error"), SIGNIN_WAIT)
        return {"flow_id": flow_id, **self._public(snap)}

    async def sign_in_finish(self, flow_id: Any, callback_url: Any) -> dict:
        held = self._flows.get(flow_id) if isinstance(flow_id, str) else None
        if held is None:
            raise McpError("UNKNOWN_FLOW", "That sign-in has expired; start again")
        query = parse_qs(urlparse(str(callback_url or "")).query)
        first = lambda key: (query.get(key) or [None])[0]  # noqa: E731
        await asyncio.to_thread(held["flow"].deliver, first("code"), first("state"),
                                first("error_description") or first("error"), first("iss"))
        snap = await self._wait(held["flow"], ("approved", "error"), CALLBACK_WAIT)
        if snap.get("status") in ("approved", "error"):
            self._flows.pop(flow_id, None)
        if snap.get("status") == "approved":
            await asyncio.to_thread(self._backend.reload, held["profile_id"])
            for target in held["share"]:
                try:
                    if held["name"] in self._backend.servers(target):
                        await asyncio.to_thread(self._backend.copy_sign_in, held["profile_id"], target, held["name"])
                        await asyncio.to_thread(self._backend.reload, target)
                except Exception:
                    log.warning("Lekora: sharing %s's sign-in with %s failed", held["name"], target, exc_info=True)
        return self._public(snap)

    def sign_in_cancel(self, flow_id: Any) -> dict:
        held = self._flows.pop(flow_id, None) if isinstance(flow_id, str) else None
        if held is not None:
            held["flow"].cancel()
        return {"cancelled": held is not None}

    async def _wait(self, flow: Flow, done: tuple, seconds: float) -> dict:
        until = self._clock() + seconds
        while True:
            snap = flow.snapshot() or {}
            if snap.get("status") in done or self._clock() >= until:
                return snap
            await asyncio.sleep(0.2)

    @staticmethod
    def _public(snap: dict) -> dict:
        out = {"status": snap.get("status") or "starting"}
        for key in ("authorization_url", "error"):
            if snap.get(key):
                out[key] = snap[key]
        if snap.get("tools"):
            out["tools"] = [{"name": t.get("name"), "description": t.get("description") or ""}
                            for t in snap["tools"] if isinstance(t, dict)]
        return out
