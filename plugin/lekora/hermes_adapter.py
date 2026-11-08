"""Hermes platform adapter for Lekora.

Written against the plugin contract in Hermes' ``gateway/platforms/ADDING_A_PLATFORM.md``
and its IRC reference adapter. It only imports Hermes modules, so it loads
inside Hermes and is NOT exercised by the fake-Hermes unit tests. It must be
verified in the real-Hermes pass before this feature counts as done.

Mapping: each Lekora profile is a real Hermes profile, and one Hermes chat
(``chat_id == profile_id == profile name``). One Hermes gateway serves every
profile, so each message is stamped with its target profile
(``source.profile``) and Hermes runs that turn as that profile; replies come
back through ``send(chat_id=profile)``. No Hermes config is written. Every
profile is equal. Paired devices are authenticated by Lekora itself, so
the platform is registered ``trusted_inbound`` (no second allow-list/pairing).
"""

from __future__ import annotations

import datetime
import logging
import uuid
from typing import Any, Optional

from gateway.config import HomeChannel, Platform
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent, MessageType

from .plugin import LekoraConfig, LekoraService, UnsupportedHermesVersion

logger = logging.getLogger(__name__)

PLATFORM_NAME = "lekora"


def _hermes_version() -> Optional[str]:
    try:
        import hermes_cli
        return str(hermes_cli.__version__)
    except Exception:  # pragma: no cover - depends on the Hermes install
        return None


class LekoraAdapter(BasePlatformAdapter):
    def __init__(self, config, **kwargs):
        super().__init__(config=config, platform=Platform(PLATFORM_NAME))
        self._cfg = LekoraConfig.from_extra(getattr(config, "extra", {}) or {})
        self._service: Optional[LekoraService] = None
        self._set_in_memory_home_channel(config)

    def _set_in_memory_home_channel(self, config) -> None:
        """Stop Hermes' "no home channel is set" notice on the first message.

        Kept in memory only: nothing is written to the user's Hermes config.
        Scheduled-job output with no explicit target goes to the first profile.
        """
        try:
            profiles = self._cfg.current_profiles()
            if getattr(config, "home_channel", None) or not profiles:
                return
            first = profiles[0]
            config.home_channel = HomeChannel(
                platform=Platform(PLATFORM_NAME),
                chat_id=first["profile_id"], name=first["name"])
        except Exception as exc:  # never block startup over a cosmetic notice
            logger.debug("Lekora: could not set in-memory home channel: %s", exc)

    @property
    def name(self) -> str:
        return "Lekora"

    # -- AgentBridge: phone -> agent -----------------------------------------
    async def deliver_to_agent(self, profile_id: str, text: str, message_id: str) -> None:
        if not self._message_handler:
            return
        source = self.build_source(
            chat_id=profile_id, chat_name=profile_id, chat_type="dm",
            user_id="lekora-owner", user_name="Lekora")
        # Run this turn as the chosen profile. The gateway already rejected unknown
        # profiles (UNKNOWN_PROFILE), so this never silently falls back to another agent.
        # A configured gateway.profile_routes entry for this chat still takes precedence.
        if not getattr(source, "profile", None):
            source.profile = profile_id
        await self.handle_message(MessageEvent(
            text=text, message_type=MessageType.TEXT, source=source,
            message_id=message_id, timestamp=datetime.datetime.now()))

    # -- lifecycle -----------------------------------------------------------
    async def connect(self, *, is_reconnect: bool = False) -> bool:
        self._service = LekoraService(
            self, config=self._cfg, hermes_version=_hermes_version())
        try:
            port = await self._service.start()
        except UnsupportedHermesVersion as exc:
            logger.error("Lekora: %s", exc)
            self._set_fatal_error("unsupported_hermes", str(exc), retryable=False)
            return False
        except Exception as exc:
            logger.error("Lekora: failed to start: %s", exc)
            self._set_fatal_error("start_failed", str(exc), retryable=True)
            return False
        self._mark_connected()
        logger.info("Lekora: listening on port %s", port)
        self._wire_plugin_handlers(None)
        return True

    async def disconnect(self) -> None:
        self._mark_disconnected()
        if self._service is not None:
            await self._service.stop()
            self._service = None

    # -- agent -> phone ------------------------------------------------------
    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[dict[str, Any]] = None):
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        try:
            seq = await self._service.handle_agent_reply(chat_id, content)
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=str(seq))

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        """Typing indicators arrive with the streaming feature."""

    async def get_chat_info(self, chat_id: str) -> dict[str, Any]:
        return {"name": chat_id, "type": "dm", "chat_id": chat_id}


def check_requirements() -> bool:
    return True  # standard library only; nothing to install


def register(ctx) -> None:
    from .pairing import handle_cli, setup_cli
    ctx.register_cli_command(
        "lekora", help="Lekora iPhone app: pairing and paired devices",
        setup_fn=setup_cli, handler_fn=handle_cli,
        description="Manage the Lekora iOS companion app "
                    "(hermes lekora pair, hermes lekora devices).")
    ctx.register_platform(
        name=PLATFORM_NAME,
        label="Lekora",
        adapter_factory=LekoraAdapter,
        check_fn=check_requirements,
        validate_config=lambda config: True,
        required_env=[],
        install_hint="No extra packages needed (standard library only)",
        trusted_inbound=True,  # devices are authenticated by Lekora's own pairing
        emoji="📱",
        pii_safe=False,
    )
