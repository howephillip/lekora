"""Lekora service: wires the store, route resolver and gateway to a Hermes bridge.

Everything here is independent of Hermes internals. Hermes is reached only
through the small :class:`AgentBridge` protocol, so the gateway and store stay
decoupled and tests can use a fake Hermes. The real Hermes platform adapter
lives in ``hermes_adapter.py`` and implements that bridge.
"""

from __future__ import annotations

import asyncio

import logging
import re
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Any, Callable, Mapping, Optional, Protocol

from . import __version__
from .gateway import Gateway
from .instance_lock import InstanceLock, LekoraAlreadyRunning  # noqa: F401 (re-exported)
from .profile_admin import ProfileAdmin, RunCli, run_hermes_cli
from . import profiles as _profiles
from .profiles import discover_profiles
from .routes import resolve_candidate_endpoints
from .tls import TLSIdentity, ensure_identity, tls_dir_for
from .store import Store

if TYPE_CHECKING:
    from .prompts import Resolvers

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
    # With photos or files (docs/files.md), also ``files=[{"path", "name", "mime"}]``.


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
        profiles_provider: Optional[Callable[[], list[dict]]] = None,
        run_cli: RunCli = run_hermes_cli,
        resolvers: Optional["Resolvers"] = None,
        commands_provider: Optional[Callable[[str], list[dict]]] = None,
        model_info: Optional[Callable[[str, str], Optional[dict]]] = None,
        settings_reader: Optional[Callable[[str], dict]] = None,
        hermes_voice: Optional[Callable[[str], dict]] = None,
        speaker: Optional[Callable[[str, str], list[Path]]] = None,
        rewriter: Optional[Callable[[str, str, str], str]] = None,
        tools_reader: Optional[Callable[[str], dict]] = None,
    ) -> None:
        self._tools_reader = tools_reader  # an agent's tools in Lekora chats (docs/agent-tools.md)
        self._rewriter = rewriter  # personality voice scripts (docs/voice.md §2)
        # Hermes' own voice per agent (docs/voice.md §2); from the adapter.
        self._hermes_voice = hermes_voice
        self._speaker = speaker
        self._settings_reader = settings_reader
        self._commands_provider = commands_provider
        self._model_info = model_info
        self._run_cli = run_cli
        # Approval and question cards (docs/prompts.md); Hermes' resolvers come from the adapter.
        from .prompts import Prompts
        self.prompts = Prompts(lambda: self.gateway, resolvers)
        self._instance_lock: Optional[InstanceLock] = None
        self.tls: Optional[TLSIdentity] = None
        self._bridge = bridge
        # What the phone is offered; the Hermes adapter narrows it to routable profiles.
        self._profiles_provider = profiles_provider
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
        # One running Lekora per store (instance_lock.py). A second copy stops here,
        # before it can take another port and overwrite the saved one.
        if str(self._store.path) != ":memory:":
            lock = InstanceLock(Path(str(self._store.path) + ".lock"))
            try:
                lock.acquire()
            except LekoraAlreadyRunning:
                await self.stop()
                raise
            self._instance_lock = lock
        if self.config.instance_name:
            self._store.set_instance_name(self.config.instance_name)
        # Every connection is encrypted (wss://) with the plugin's own certificate, which
        # phones pin at pairing (tls.py). Created once, next to lekora.db.
        try:
            if str(self._store.path) == ":memory:":
                import tempfile
                tls_dir = Path(tempfile.mkdtemp(prefix="lekora-tls-"))
            else:
                tls_dir = tls_dir_for(self._store.path)
            self.tls = ensure_identity(tls_dir, common_name=f"Lekora {self._store.instance_id}")
        except BaseException:
            await self.stop()
            raise

        kwargs: dict[str, Any] = {}
        if self._auth_timeout is not None:
            kwargs["auth_timeout"] = self._auth_timeout
        # Create/delete agents from the phone, unless the owner pinned a fixed agent list.
        admin = None
        if self.config.profiles is None:
            admin = ProfileAdmin(
                self._store,
                hermes_root=lambda: Path(self.config.hermes_root) if self.config.hermes_root else _profiles.hermes_root(),
                run_cli=self._run_cli,
                move_files=lambda profile_id, to: self.gateway.files.move_profile(profile_id, to)
                if self.gateway is not None and self.gateway.files is not None else None)
        self.gateway = Gateway(
            self._store,
            dispatch=self._bridge.deliver_to_agent,
            profiles=self._profiles_provider or self.config.current_profiles,
            endpoints=lambda port: resolve_candidate_endpoints(
                port, self.config.extra_hosts),
            host=self.config.listen_host,
            profile_admin=admin,
            ssl_context=self.tls.server_context(),
            **kwargs,
        )
        self.gateway.files = self._file_store()
        from .voice_settings import VoiceSettings
        self.gateway.voice = VoiceSettings(self._store, self.gateway.files,
                                           **({"hermes_voice": self._hermes_voice} if self._hermes_voice else {}),
                                           speak=self._speaker)
        if self._tools_reader is not None:
            from .agent_tools import AgentTools
            from .routing_config import RoutingConfig
            root = Path(self.config.hermes_root) if self.config.hermes_root else _profiles.hermes_root()
            backups = RoutingConfig(root / "lekora-backups" / "config")
            self.gateway.tools = AgentTools(
                self._tools_reader, self._run_cli,
                backup=lambda profile_id: backups.backup(profile_id, _profiles.profile_home(profile_id, root) / "config.yaml"))
        from .voice_replies import VoiceReplies
        self.gateway.voice_replies = VoiceReplies(self.gateway, self.gateway.voice, self._speaker, self._rewriter)
        self.gateway.prompts = self.prompts
        # "/model … --global" and friends, from the model picker: handed to Hermes like a typed command.
        self.prompts.send_command = lambda chat_id, text: self._bridge.deliver_to_agent(
            chat_id, text, "lekora-" + uuid.uuid4().hex[:12])
        self.gateway.commands_provider = self._commands_provider
        self.gateway.models = self._models_service()
        from .chat_settings import ChatSettings
        self.gateway.settings = ChatSettings(
            self._settings_reader or (lambda profile_id: {}),
            send_command=self.prompts.send_command)
        if self.gateway.models is not None:
            self.prompts.knows_openrouter_model = self.gateway.models.knows_openrouter_model
        try:
            port = await self.gateway.start()
        except BaseException:
            await self.stop()
            raise
        try:
            # Hermes forgot any request still waiting from a previous run.
            await self.prompts.expire_leftovers()
        except Exception:
            logging.getLogger(__name__).exception("Lekora: could not expire old cards")
        return port

    def _file_store(self):
        """Files both ways (docs/files.md): kept in ``<Hermes>/lekora-files``."""
        from .files import FileStore
        if str(self._store.path) == ":memory:":
            import tempfile
            root = Path(tempfile.mkdtemp(prefix="lekora-files-"))
        else:
            root = (Path(self.config.hermes_root) if self.config.hermes_root else _profiles.hermes_root()) / "lekora-files"
        files = FileStore(root, self._store)
        try:
            files.clean_stale_uploads()
        except OSError:
            logging.getLogger(__name__).exception("Lekora: could not clean unfinished uploads")
        return files

    async def take_transcript(self, profile_id: str, content: str) -> bool:
        """Hermes' 🎙️ "…" line after a voice note: put it on the voice bubble instead of
        showing it (docs/voice.md). False for anything else."""
        from .hermes_files import transcript_from_echo
        text = transcript_from_echo(content)
        if text is None or self.gateway is None:
            return False
        return await self.gateway.attach_transcript(profile_id, text)

    async def handle_agent_file(self, profile_id: str, path: Path, caption: str = "",
                                name: Optional[str] = None, mime: Optional[str] = None) -> int:
        """A file from the agent: a copy is kept and sent to every phone; returns its seq."""
        if self.gateway is None or self.gateway.files is None:
            raise RuntimeError("Lekora is not running")
        files = self.gateway.files
        described = await asyncio.to_thread(files.add_agent_file, profile_id, Path(path), name, mime)
        return await self.gateway.publish_files(profile_id, [described], caption or "")

    def _models_service(self):
        """Model picker details: OpenRouter's catalog (cached next to lekora.db) and routing."""
        from .models_service import ModelsService
        from .openrouter_catalog import OpenRouterCatalog
        from .routing_config import RoutingConfig
        root = Path(self.config.hermes_root) if self.config.hermes_root else _profiles.hermes_root()
        db = str(self._store.path)
        cache_dir = None if db == ":memory:" else Path(db).parent / "lekora-cache"
        return ModelsService(
            OpenRouterCatalog(cache_dir),
            RoutingConfig(root / "lekora-backups" / "config"),
            profile_home=lambda profile_id: _profiles.profile_home(profile_id, root),
            **({"model_info": self._model_info} if self._model_info else {}))

    async def stop(self) -> None:
        if self.gateway is not None:
            await self.gateway.stop()
            self.gateway = None
        if self._owns_store and self._store is not None:
            self._store.close()
            self._store = None
        if self._instance_lock is not None:
            self._instance_lock.release()
            self._instance_lock = None

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
