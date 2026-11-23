"""Hermes glue for MCP servers (docs/mcp.md). Imports Hermes lazily: only runs inside it.

Every call runs inside the agent's own profile (``gateway.run._profile_runtime_scope``), so Hermes'
own helpers read and write that agent's config.yaml, .env and sign-in tokens.
"""

from __future__ import annotations

import contextlib
import io
import logging
import secrets
import shutil
import threading
from pathlib import Path
from typing import Any, Callable, Optional

from .mcp import McpError

log = logging.getLogger(__name__)


class _Flow:
    """A Hermes dashboard sign-in flow, run by Hermes' own OAuth worker in a thread."""

    def __init__(self, flow: Any) -> None:
        self._flow = flow

    def snapshot(self) -> dict:
        return self._flow.snapshot()

    def deliver(self, code, state, error, iss) -> None:
        self._flow.deliver_callback(code=code, state=state, error=error, iss=iss)

    def cancel(self) -> None:
        self._flow.mark_error("Cancelled by user", cancelled=True)


class HermesMcp:
    def __init__(self, home_of: Callable[[str], Path], runner: Callable[[], Any] = lambda: None) -> None:
        self._home_of = home_of
        self._runner = runner

    @contextlib.contextmanager
    def _in(self, profile_id: str, write: bool = False):
        from gateway.run import _profile_runtime_scope
        with _profile_runtime_scope(Path(self._home_of(profile_id)), hydrate_secrets=True):
            if write:
                from hermes_cli.web_routers._common import config_write_scope
                with config_write_scope(None):
                    yield
            else:
                yield

    # ---- reading ------------------------------------------------------------

    def servers(self, profile_id: str) -> dict[str, dict]:
        """As written in the agent's config.yaml: secrets stay ``${VAR}`` (Hermes' reader fills them in)."""
        from hermes_cli.config import read_user_config_raw
        raw = read_user_config_raw(Path(self._home_of(profile_id)) / "config.yaml") or {}
        servers = raw.get("mcp_servers") if isinstance(raw, dict) else None
        return {str(k): dict(v) for k, v in (servers or {}).items() if isinstance(v, dict)}

    def plugin_owned(self, profile_id: str) -> set[str]:
        return set()  # servers other plugins provide aren't in the agent's config, so aren't listed

    def catalog(self) -> list[dict]:
        from hermes_cli.mcp_catalog import list_catalog
        out = []
        for e in list_catalog():
            auth = e.auth
            out.append({
                "name": e.name, "description": e.description or "", "auth": auth.type,
                "needs": [{"name": v.name, "prompt": v.prompt or v.name, "secret": bool(v.secret),
                           "required": bool(v.required), **({"default": str(v.default)} if v.default else {})}
                          for v in auth.env or []],
                "preregistered": bool((auth.oauth or {}).get("client_id") and (auth.oauth or {}).get("redirect_port")),
                **({"url": e.transport.url} if getattr(e.transport, "url", None) else {}),
            })
        return out

    def secret(self, profile_id: str, key: str) -> Optional[str]:
        from hermes_cli.config import load_env
        with self._in(profile_id):
            return (load_env() or {}).get(key)

    def signed_in(self, profile_id: str, name: str) -> bool:
        from hermes_cli.mcp_config import _oauth_tokens_present
        with self._in(profile_id):
            return bool(_oauth_tokens_present(name))

    # ---- changing -----------------------------------------------------------

    def install_catalog(self, profile_id: str, name: str, values: dict[str, str]) -> None:
        from hermes_cli.mcp_catalog import get_entry, install_entry
        entry = get_entry(name)
        if entry is None:
            raise McpError("UNKNOWN_SERVER", "Hermes' catalog doesn't have that server")
        with self._in(profile_id, write=True), contextlib.redirect_stdout(io.StringIO()):
            install_entry(entry, enable=True, preloaded_env=dict(values))

    def save(self, profile_id: str, name: str, config: dict) -> None:
        from hermes_cli.mcp_config import _save_mcp_server
        with self._in(profile_id, write=True), contextlib.redirect_stdout(io.StringIO()):
            if not _save_mcp_server(name, config):
                raise McpError("REJECTED", "Hermes' safety check refused this server")

    def remove(self, profile_id: str, name: str) -> None:
        from hermes_cli.mcp_config import _remove_mcp_server
        with self._in(profile_id, write=True), contextlib.redirect_stdout(io.StringIO()):
            _remove_mcp_server(name)

    def set_enabled(self, profile_id: str, name: str, enabled: bool) -> None:
        from hermes_cli.config import load_config, save_config
        with self._in(profile_id, write=True):
            config = load_config()
            servers = config.get("mcp_servers") or {}
            if name not in servers:
                raise McpError("UNKNOWN_SERVER", "That server isn't there any more")
            servers[name]["enabled"] = enabled
            save_config(config)

    def save_secret(self, profile_id: str, key: str, value: str) -> None:
        from hermes_cli.config import save_env_value
        with self._in(profile_id, write=True):
            save_env_value(key, value)

    def copy_sign_in(self, from_profile: str, to_profile: str, name: str) -> bool:
        """The agent's saved sign-in for this server (tokens, client and server details), copied."""
        src = Path(self._home_of(from_profile)) / "mcp-tokens"
        dst = Path(self._home_of(to_profile)) / "mcp-tokens"
        copied = False
        for suffix in (".json", ".client.json", ".meta.json"):
            path = src / f"{name}{suffix}"
            if path.is_file():
                dst.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, dst / path.name)
                (dst / path.name).chmod(0o600)
                copied = True
        return copied

    def probe(self, profile_id: str, name: str) -> dict:
        from hermes_cli.mcp_config import _get_mcp_servers, _probe_single_server, probe_failure_class
        with self._in(profile_id), contextlib.redirect_stdout(io.StringIO()):
            config = (_get_mcp_servers() or {}).get(name)
            if config is None:
                raise McpError("UNKNOWN_SERVER", "That server isn't there any more")
            try:
                tools = _probe_single_server(name, config)
            except Exception as exc:
                return {"ok": False, "failure": probe_failure_class(exc), "error": str(exc)[:400]}
        return {"ok": True, "tools": [{"name": t[0], "description": t[1] or ""} for t in tools or []]}

    def start_sign_in(self, profile_id: str, name: str, redirect_uri: str) -> _Flow:
        from hermes_cli.mcp_config import _get_mcp_servers
        from tools.connectors.mcp_oauth import run_worker
        from tools.mcp_dashboard_oauth import DashboardOAuthFlow
        home = str(self._home_of(profile_id))
        with self._in(profile_id):
            config = dict((_get_mcp_servers() or {}).get(name) or {})
        if not config:
            raise McpError("UNKNOWN_SERVER", "That server isn't there any more")
        flow = DashboardOAuthFlow(flow_id=secrets.token_urlsafe(12), server_name=name, profile=profile_id,
                                  hermes_home=home, redirect_uri=redirect_uri, reconnect_live=True)
        threading.Thread(target=run_worker, args=(home, name, config, True), kwargs={"flow": flow},
                         name=f"lekora-mcp-signin-{name}", daemon=True).start()
        return _Flow(flow)

    def reload(self, profile_id: str) -> None:
        """Hermes connects the agent's servers as they are now, and its open chats get the new tools."""
        try:
            from tools.mcp_tool_discovery import reconcile_mcp_servers_with_config
            with self._in(profile_id):
                reconcile_mcp_servers_with_config()
        except Exception:
            log.debug("Lekora: MCP reconcile for %s failed (Hermes retries within a minute)", profile_id, exc_info=True)
        runner = self._runner()
        refresh = getattr(runner, "_mcp_reload_refresh_cached_agents", None)
        if callable(refresh):
            try:
                from agent.secret_scope import is_multiplex_active
                refresh(is_multiplex_active(), profile_id)
            except Exception:
                log.debug("Lekora: refreshing %s's open chats failed", profile_id, exc_info=True)

    def has_runner(self, command: str) -> bool:
        return shutil.which(command) is not None
