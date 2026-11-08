"""Lekora service: wires the store, route resolver and gateway to a Hermes bridge.

Everything here is independent of Hermes internals. Hermes is reached only
through the small :class:`AgentBridge` protocol, so the gateway and store stay
decoupled and tests can use a fake Hermes. The real Hermes platform adapter
lives in ``hermes_adapter.py`` and implements that bridge.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass, field
from typing import Any, Mapping, Optional, Protocol

from . import __version__
from .gateway import Gateway
from .profiles import discover_profiles
from .routes import resolve_candidate_endpoints
from .store import Store

log = logging.getLogger(__name__)

# Hermes releases this plugin is known to work with (inclusive min, exclusive max).
MIN_HERMES = (0, 22, 0)
MAX_HERMES_EXCLUSIVE = (1, 0, 0)

class UnsupportedHermesVersion(RuntimeError):
    """Raised at startup when the running Hermes is outside the supported range."""


def _parse_version(text: str) -> Optional[tuple[int, int, int]]:
    m = re.match(r"\s*v?(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)


def check_hermes_version(version: Optional[str]) -> None:
    """Raise UnsupportedHermesVersion with plain-language guidance if out of range."""
    parsed = _parse_version(version or "")
    lo = ".".join(map(str, MIN_HERMES))
    hi = ".".join(map(str, MAX_HERMES_EXCLUSIVE))
    if parsed is None or not (MIN_HERMES <= parsed < MAX_HERMES_EXCLUSIVE):
        raise UnsupportedHermesVersion(
            f"Lekora {__version__} works with Hermes {lo} up to (not including) {hi}, "
            f"but this Hermes reports version {version or 'unknown'}. "
            "Update Hermes or Lekora, then restart. Lekora has not started."
        )


class AgentBridge(Protocol):
    """What Lekora needs from Hermes: hand a phone message to an agent profile."""

    async def deliver_to_agent(self, profile_id: str, text: str, message_id: str) -> None: ...


@dataclass
class LekoraConfig:
    db_path: Optional[str] = None            # None -> LEKORA_DB_PATH or ~/.hermes/lekora.db
    listen_host: str = "0.0.0.0"
    instance_name: Optional[str] = None
    extra_hosts: list[str] = field(default_factory=list)   # e.g. a domain name you own
    # None (the normal case): the phone sees the real Hermes profiles, discovered live.
    # A list here pins a fixed set instead (tests, or hiding profiles from the phone).
    profiles: Optional[list[dict]] = None
    hermes_root: Optional[str] = None        # where to discover profiles; None -> Hermes' root

    def current_profiles(self) -> list[dict]:
        """The agents offered to the phone right now (re-read on every use, so a profile
        created or deleted in Hermes shows up at the phone's next connect)."""
        if self.profiles is not None:
            return [dict(p) for p in self.profiles]
        return discover_profiles(self.hermes_root)

    @classmethod
    def from_extra(cls, extra: Optional[Mapping[str, Any]]) -> "LekoraConfig":
        extra = extra or {}
        cfg = cls()
        cfg.db_path = extra.get("db_path") or None
        cfg.listen_host = extra.get("listen_host") or cfg.listen_host
        cfg.instance_name = extra.get("instance_name") or None
        cfg.extra_hosts = [str(h) for h in extra.get("extra_hosts") or []]
        cfg.hermes_root = extra.get("hermes_root") or None
        profiles = extra.get("profiles")
        if profiles:
            cfg.profiles = [
                {"profile_id": str(p["profile_id"]),
                 "name": str(p.get("name", p["profile_id"])),
                 "avatar": str(p.get("avatar", "sparkles")),
                 **({"description": str(p["description"])} if p.get("description") else {})}
                for p in profiles
            ]
        return cfg


class LekoraService:
    def __init__(
        self,
        bridge: AgentBridge,
        config: Optional[LekoraConfig] = None,
        store: Optional[Store] = None,
        hermes_version: Optional[str] = None,
        check_version: bool = True,
        auth_timeout: Optional[float] = None,
    ) -> None:
        self._bridge = bridge
        self.config = config or LekoraConfig()
        self._hermes_version = hermes_version
        self._check_version = check_version
        self._owns_store = store is None
        self._store = store
        self._auth_timeout = auth_timeout
        self.gateway: Optional[Gateway] = None

    @property
    def store(self) -> Store:
        assert self._store is not None, "service not started"
        return self._store

    async def start(self) -> int:
        """Version-gate, open the store, start the gateway. Returns the bound port."""
        if self._check_version:
            check_hermes_version(self._hermes_version)  # before touching disk or network
        if self._store is None:
            self._store = Store(self.config.db_path)
        if self.config.instance_name:
            self._store.set_instance_name(self.config.instance_name)

        kwargs: dict[str, Any] = {}
        if self._auth_timeout is not None:
            kwargs["auth_timeout"] = self._auth_timeout
        self.gateway = Gateway(
            self._store,
            dispatch=self._bridge.deliver_to_agent,
            profiles=self.config.current_profiles,
            endpoints=lambda port: resolve_candidate_endpoints(
                port, self.config.extra_hosts),
            host=self.config.listen_host,
            **kwargs,
        )
        try:
            return await self.gateway.start()
        except BaseException:
            await self.stop()
            raise

    async def stop(self) -> None:
        if self.gateway is not None:
            await self.gateway.stop()
            self.gateway = None
        if self._owns_store and self._store is not None:
            self._store.close()
            self._store = None

    async def handle_agent_reply(self, profile_id: str, text: str) -> int:
        """Called when an agent produces output for a phone; returns its event seq."""
        if self.gateway is None:
            raise RuntimeError("Lekora is not running")
        return await self.gateway.publish_message(profile_id, text)

    # ---- Hermes registration (only runs inside Hermes) ----------------------

    def endpoints(self) -> list[str]:
        port = self.gateway.port if self.gateway else 0
        return resolve_candidate_endpoints(port or 0, self.config.extra_hosts)


def register(ctx) -> None:
    """Hermes plugin entry point. Imported lazily so this module works without Hermes."""
    from .hermes_adapter import register as _register
    _register(ctx)
