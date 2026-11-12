"""Hermes platform adapter for Lekora.

Written against the plugin contract in Hermes' ``gateway/platforms/ADDING_A_PLATFORM.md``
and its IRC reference adapter. It only imports Hermes modules, so it loads
inside Hermes and is NOT exercised by the fake-Hermes unit tests. It must be
verified in the real-Hermes pass before this feature counts as done.

Mapping: each Lekora profile is a real Hermes profile, and one Hermes chat
(``chat_id == profile_id == profile name``). One Hermes gateway serves every
profile; ``hermes_routes.ProfileRouter`` keeps an in-memory route per named
profile so Hermes runs each chat as its profile, and replies come back through
``send(chat_id=profile)``. No Hermes config is written. Every profile is equal. Paired devices are authenticated by Lekora itself, so
the platform is registered ``trusted_inbound`` (no second allow-list/pairing).
"""

from __future__ import annotations

import asyncio
import datetime
import logging
import uuid
from pathlib import Path
from typing import Any, Optional

from gateway.config import HomeChannel, Platform
from gateway.platforms.base import BasePlatformAdapter, SendResult
from gateway.platforms.event import MessageEvent, MessageType

from . import hermes_streaming
from .hermes_files import TOOL_NAME, TOOL_SCHEMA, TOOLSET, inbound_media, send_file_tool
from .hermes_routes import ProfileRouter, check_routed
from .prompts import CARD_MESSAGE_PREFIX, Resolvers
from .streaming import LiveReplies
from .plugin import LekoraAlreadyRunning, LekoraConfig, LekoraService, UnsupportedHermesVersion
from .profiles import named_profile_in_scope

logger = logging.getLogger(__name__)

PLATFORM_NAME = "lekora"


def _hermes_resolvers() -> Resolvers:
    """Hermes' own answer functions for approvals and questions (docs/prompts.md)."""
    def approve(session_key: str, choice: str, reason: Optional[str]) -> int:
        from tools.approval import resolve_gateway_approval
        return resolve_gateway_approval(session_key, choice, reason=reason)

    def answer(clarify_id: str, text: str) -> bool:
        from tools.clarify_gateway import resolve_gateway_clarify
        return resolve_gateway_clarify(clarify_id, text)

    def approval_timeout() -> Optional[int]:
        from gateway.platforms.base_exec_approval import approval_timeout_seconds
        return approval_timeout_seconds()

    async def confirm(session_key: str, confirm_id: str, choice: str) -> tuple[bool, Optional[str]]:
        from tools import slash_confirm
        entry = slash_confirm.get_pending(session_key)
        if not entry or entry.get("confirm_id") != confirm_id or slash_confirm.clear_if_stale(session_key):
            return False, None
        return True, await slash_confirm.resolve(session_key, confirm_id, choice)

    def waiting(kind: str, session_key: str, clarify_id: Optional[str]) -> Optional[bool]:
        if kind == "approval":
            from tools.approval import has_blocking_approval
            return has_blocking_approval(session_key)
        if kind == "confirm":
            from tools import slash_confirm
            entry = slash_confirm.get_pending(session_key)
            return bool(entry and entry.get("confirm_id") == clarify_id)
        from tools.clarify_gateway import get_pending
        return get_pending(clarify_id or "") is not None

    def model_warning(model: str, provider: str) -> Optional[str]:
        # The same check Hermes' own Telegram/Discord pickers run before switching.
        from hermes_cli.model_selection_guards import combined_selection_warning
        warning = combined_selection_warning(model, provider=provider)
        return warning.message if warning is not None else None

    return Resolvers(approve=approve, answer=answer, approval_timeout=approval_timeout,
                     waiting=waiting, confirm=confirm, model_warning=model_warning)


def _hermes_version() -> Optional[str]:
    try:
        import hermes_cli
        return str(hermes_cli.__version__)
    except Exception:  # pragma: no cover - depends on the Hermes install
        return None


# The running adapter and its event loop, for the lekora_send_file tool (docs/files.md).
_ACTIVE: Optional[tuple["LekoraAdapter", asyncio.AbstractEventLoop]] = None


def _hermes_cache(data: bytes, name: str, mime: str):
    """Hermes' own media cache (gateway.platforms.base.cache_media_bytes)."""
    from gateway.platforms.base import cache_document_from_bytes, cache_media_bytes
    cached = cache_media_bytes(data, filename=name, mime_type=mime)
    if cached is None:  # an "image" Hermes can't read: still give it to the agent, as a file
        return cache_document_from_bytes(data, name), mime or "application/octet-stream", "document"
    return cached.path, cached.media_type, cached.kind


def _local_path(url: str) -> Optional[str]:
    if url.startswith("file://"):
        from urllib.parse import unquote, urlparse
        return unquote(urlparse(url).path)
    if url.startswith("/"):
        return url
    return None


def _lekora_session() -> bool:
    """The tool is only offered in Lekora chats."""
    try:
        from gateway.session_context import get_session_env
        return get_session_env("HERMES_SESSION_PLATFORM") == PLATFORM_NAME
    except Exception:
        return False


def _send_file_handler(args: dict, **_kwargs) -> str:
    from gateway.session_context import get_session_env
    active = _ACTIVE
    return send_file_tool(
        args, platform=get_session_env("HERMES_SESSION_PLATFORM"), chat_id=get_session_env("HERMES_SESSION_CHAT_ID"),
        deliver=active[0]._tool_deliver if active else None, loop=active[1] if active else None,
        validate=BasePlatformAdapter.validate_media_delivery_path)


class LekoraAdapter(BasePlatformAdapter):
    # Streaming (docs/streaming.md): Hermes sends the first words, then edits the message.
    SUPPORTS_MESSAGE_EDITING = True
    REQUIRES_EDIT_FINALIZE = True       # always told when a message is sealed
    MAX_MESSAGE_LENGTH = 100_000        # the phone shows long replies in one bubble
    supports_status_text = True         # "Searching the web…" in the working indicator

    def __init__(self, config, **kwargs):
        super().__init__(config=config, platform=Platform(PLATFORM_NAME))
        self._cfg = LekoraConfig.from_extra(getattr(config, "extra", {}) or {})
        self._service: Optional[LekoraService] = None
        self._router = ProfileRouter(lambda: self.gateway_runner, PLATFORM_NAME)
        self._live = LiveReplies(
            lambda: self._service.gateway if self._service is not None else None,
            cursor=lambda: hermes_streaming.cursor_of(self.gateway_runner))
        # A copy started inside another agent's profile stays idle (see connect), so it
        # must not become that agent's home channel either: its job output would be lost.
        if named_profile_in_scope(getattr(self, "_owner_profile", None)) is None:
            self._set_in_memory_home_channel(config)

    def offered_profiles(self) -> list[dict]:
        """Profiles for the phone, refreshing the in-memory routes on every call (each
        phone connect and message), so new or deleted Hermes profiles need no restart."""
        return self._router.offered(self._cfg.current_profiles())

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

    def _commands_for(self, profile_id: str) -> list[dict]:
        """The slash commands this agent can use, from Hermes' own lists (in its profile)."""
        from .hermes_commands import list_commands
        from .profiles import profile_home
        root = Path(self._cfg.hermes_root) if self._cfg.hermes_root else None
        return list_commands(profile_home(profile_id, root))

    def _settings_for(self, profile_id: str) -> dict:
        """A chat's current settings, read from Hermes (docs/chat-settings.md)."""
        from .hermes_settings import read_settings
        from .profiles import profile_home
        source = self.build_source(chat_id=profile_id, chat_name=profile_id, chat_type="dm",
                                   user_id="lekora-owner", user_name="Lekora")
        root = Path(self._cfg.hermes_root) if self._cfg.hermes_root else None
        return read_settings(self.gateway_runner, source, profile_home(profile_id, root))

    def _profile_home(self, profile_id: str) -> Path:
        from .profiles import profile_home
        root = Path(self._cfg.hermes_root) if self._cfg.hermes_root else None
        return profile_home(profile_id, root)

    def _hermes_voice_for(self, profile_id: str) -> dict:
        """Which voice this agent's Hermes settings use (docs/voice.md §2); read only."""
        from gateway.run import _profile_runtime_scope
        from tools.tts_tool import _get_provider, _load_tts_config, check_tts_requirements
        with _profile_runtime_scope(self._profile_home(profile_id), hydrate_secrets=True):
            provider = _get_provider(_load_tts_config())
            return {"provider": provider, "available": bool(check_tts_requirements())}

    def _speak_as(self, profile_id: str, text: str) -> Path:
        """A reply spoken in this agent's Hermes voice, as an audio file (Hermes' own text_to_speech)."""
        import json as _json
        from gateway.run import _profile_runtime_scope
        from tools.tts_tool import text_to_speech_tool
        with _profile_runtime_scope(self._profile_home(profile_id), hydrate_secrets=True):
            result = _json.loads(text_to_speech_tool(text))
        if not result.get("success") or not result.get("file_path"):
            raise RuntimeError(result.get("error") or "no audio")
        return Path(result["file_path"])

    @property
    def name(self) -> str:
        return "Lekora"

    # -- AgentBridge: phone -> agent -----------------------------------------
    async def deliver_to_agent(self, profile_id: str, text: str, message_id: str,
                               files: Optional[list[dict]] = None) -> None:
        if not self._message_handler:
            return
        # Routes were refreshed when the gateway checked this profile (offered_profiles),
        # so Hermes stamps the routed profile here. Never deliver to a different agent.
        source = self.build_source(
            chat_id=profile_id, chat_name=profile_id, chat_type="dm",
            user_id="lekora-owner", user_name="Lekora")
        check_routed(source, profile_id)
        event = MessageEvent(
            text=text, message_type=MessageType.TEXT, source=source,
            message_id=message_id, timestamp=datetime.datetime.now())
        if files:
            # Photos and files (docs/files.md): into Hermes' own media cache, as Telegram does.
            media = await asyncio.to_thread(inbound_media, text, files, _hermes_cache)
            event.text = media.text
            event.message_type = MessageType(media.message_kind)
            event.media_urls = media.media_urls
            event.media_types = media.media_types
            event.media_text_inlined = media.media_text_inlined
        await self.handle_message(event)

    # -- lifecycle -----------------------------------------------------------
    async def connect(self, *, is_reconnect: bool = False) -> bool:
        # Lekora serves every agent from the default profile. Hermes also starts a copy in
        # any other profile whose settings enable it (e.g. an agent cloned from default);
        # that copy stays idle so it can't take another port and break pairing codes.
        other = named_profile_in_scope(getattr(self, "_owner_profile", None))
        if other is not None:
            logger.info("Lekora: runs from the default profile only; the copy in profile %r stays idle", other)
            self._mark_connected()
            return True
        self._service = LekoraService(
            self, config=self._cfg, hermes_version=_hermes_version(),
            profiles_provider=self.offered_profiles, resolvers=_hermes_resolvers(),
            commands_provider=self._commands_for, settings_reader=self._settings_for,
            hermes_voice=self._hermes_voice_for, speaker=self._speak_as)
        self.offered_profiles()  # startup self-check: logs if only the default agent can be offered
        try:
            port = await self._service.start()
        except UnsupportedHermesVersion as exc:
            logger.error("Lekora: %s", exc)
            self._set_fatal_error("unsupported_hermes", str(exc), retryable=False)
            return False
        except LekoraAlreadyRunning as exc:
            logger.warning("Lekora: %s; this copy stays idle", exc)
            self._service = None
            self._mark_connected()
            return True
        except Exception as exc:
            logger.error("Lekora: failed to start: %s", exc)
            self._set_fatal_error("start_failed", str(exc), retryable=True)
            return False
        hermes_streaming.install(self.gateway_runner)  # streaming on for Lekora only, in memory
        global _ACTIVE
        _ACTIVE = (self, asyncio.get_running_loop())  # for the lekora_send_file tool
        self._mark_connected()
        logger.info("Lekora: listening on port %s", port)
        self._wire_plugin_handlers(None)
        return True

    async def disconnect(self) -> None:
        global _ACTIVE
        if _ACTIVE is not None and _ACTIVE[0] is self:
            _ACTIVE = None
        self._mark_disconnected()
        if self._service is not None:
            await self._service.stop()
            self._service = None

    # -- files from the agent (docs/files.md) --------------------------------------
    # Hermes sends MEDIA: files (from its image, speech and other tools) through these.
    async def _send_local_file(self, chat_id: str, path: str, caption: Optional[str] = None,
                               file_name: Optional[str] = None) -> SendResult:
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        safe = self.validate_media_delivery_path(path)
        if safe is None:
            return SendResult(success=False, error="That file can't be sent")
        try:
            seq = await self._service.handle_agent_file(chat_id, Path(safe), caption or "", file_name)
        except Exception as exc:
            return SendResult(success=False, error=getattr(exc, "reason", None) or str(exc))
        return SendResult(success=True, message_id=str(seq))

    async def send_image_file(self, chat_id: str, image_path: str, caption: Optional[str] = None,
                              reply_to: Optional[str] = None, metadata=None, **kwargs) -> SendResult:
        return await self._send_local_file(chat_id, image_path, caption)

    async def send_document(self, chat_id: str, file_path: str, caption: Optional[str] = None,
                            file_name: Optional[str] = None, reply_to: Optional[str] = None,
                            metadata=None, **kwargs) -> SendResult:
        return await self._send_local_file(chat_id, file_path, caption, file_name)

    async def send_video(self, chat_id: str, video_path: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata=None, **kwargs) -> SendResult:
        return await self._send_local_file(chat_id, video_path, caption)

    async def send_voice(self, chat_id: str, audio_path: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata=None, **kwargs) -> SendResult:
        return await self._send_local_file(chat_id, audio_path, caption)

    async def send_image(self, chat_id: str, image_url: str, caption: Optional[str] = None,
                         reply_to: Optional[str] = None, metadata=None) -> SendResult:
        local = _local_path(image_url)
        if local is not None:
            return await self._send_local_file(chat_id, local, caption)
        return await super().send_image(chat_id, image_url, caption, reply_to, metadata)  # a link stays a link

    async def send_animation(self, chat_id: str, animation_url: str, caption: Optional[str] = None,
                             reply_to: Optional[str] = None, metadata=None) -> SendResult:
        local = _local_path(animation_url)
        if local is not None:
            return await self._send_local_file(chat_id, local, caption)
        return await super().send_animation(chat_id, animation_url, caption, reply_to, metadata)

    async def _tool_deliver(self, chat_id: str, path: str, caption: str, name: Optional[str]) -> None:
        """For the lekora_send_file tool (on the gateway's loop); raises with a reason."""
        if self._service is None:
            raise RuntimeError("Lekora is not running")
        await self._service.handle_agent_file(chat_id, Path(path), caption, name)

    # -- agent -> phone ------------------------------------------------------
    async def send(self, chat_id: str, content: str, reply_to: Optional[str] = None,
                   metadata: Optional[dict[str, Any]] = None):
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        if await self._service.take_transcript(chat_id, content):
            return SendResult(success=True, message_id="transcript")  # shown under the voice note
        try:
            message_id = await self._live.send(
                chat_id, content, expect_edits=bool((metadata or {}).get("expect_edits")))
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=message_id)

    async def edit_message(self, chat_id: str, message_id: str, content: str, *,
                           finalize: bool = False, metadata=None) -> SendResult:
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        if str(message_id).startswith(CARD_MESSAGE_PREFIX):
            # Hermes edits an approval card when nobody answered in time: nothing ran.
            ok = await self._service.prompts.approval_timed_out(str(message_id)[len(CARD_MESSAGE_PREFIX):])
            return SendResult(success=ok, message_id=str(message_id), error=None if ok else "Unknown card")
        try:
            ok = await self._live.edit(chat_id, str(message_id), content, finalize)
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        if not ok:
            return SendResult(success=False, error="Unknown message")
        return SendResult(success=True, message_id=str(message_id))

    # -- approvals and questions (docs/prompts.md) -----------------------------
    async def _send_exec_approval_prompt(self, prompt) -> SendResult:
        """Hermes' button hook for approvals: an approval card on the phone."""
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        try:
            message_id = await self._service.prompts.ask_approval(
                str(prompt.chat_id), str(prompt.session_key), prompt.command, prompt.description,
                list(prompt.choices), smart_denied=bool(prompt.smart_denied))
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=message_id)

    async def send_clarify(self, chat_id: str, question: str, choices: Optional[list], clarify_id: str,
                           session_key: str, metadata: Optional[dict[str, Any]] = None) -> SendResult:
        """A question card; the phone's answer resolves it through Hermes."""
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        multi = False
        options = list(choices) if choices else None
        try:
            from tools.clarify_gateway import get_pending
            entry = get_pending(clarify_id)
            multi = bool(getattr(entry, "multi_select", False))
            # Answers must match Hermes' own option texts exactly.
            options = list(getattr(entry, "choices", None) or options or []) or None
        except Exception:
            pass
        try:
            message_id = await self._service.prompts.ask_question(
                str(chat_id), str(session_key), question, options, clarify_id, multi_select=multi)
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=message_id)

    async def send_slash_confirm(self, chat_id: str, title: str, message: str, session_key: str,
                                 confirm_id: str, metadata: Optional[dict[str, Any]] = None) -> SendResult:
        """Confirming a slash command such as /new: a card with Approve / Always / Cancel."""
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        try:
            message_id = await self._service.prompts.ask_confirm(
                str(chat_id), str(session_key), title, message, str(confirm_id))
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=message_id)

    async def send_model_picker(self, chat_id: str, providers: list, current_model: str, current_provider: str,
                                session_key: str, on_model_selected, metadata=None) -> SendResult:
        """Hermes' /model picker hook: a card listing the models this agent can switch to."""
        if self._service is None or not providers:
            return SendResult(success=False, error="Lekora is not running" if self._service is None else "No models")
        try:
            message_id = await self._service.prompts.ask_model(
                str(chat_id), str(session_key), list(providers), current_model, current_provider, on_model_selected)
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=message_id)

    async def send_choice_picker(self, chat_id: str, title: str, choices: list, session_key: str,
                                 on_choice_selected, metadata=None) -> SendResult:
        """Hermes' choice picker hook (/reasoning, /fast, …): a card with one button per option."""
        if self._service is None:
            return SendResult(success=False, error="Lekora is not running")
        try:
            message_id = await self._service.prompts.ask_choice(
                str(chat_id), str(session_key), title, list(choices), on_choice_selected)
        except Exception as exc:
            return SendResult(success=False, error=str(exc))
        return SendResult(success=True, message_id=message_id)

    async def retire_clarify_card(self, clarify_id: str, notice: str) -> None:
        if self._service is not None:
            await self._service.prompts.question_retired(clarify_id)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        """Hermes calls this every ~2 s while an agent works: tell the phone, with what
        it is doing when Hermes knows ("Searching the web…")."""
        gateway = self._service.gateway if self._service is not None else None
        if gateway is not None:
            status = (getattr(self, "_status_text", None) or {}).get(str(chat_id))
            await gateway.publish_typing(str(chat_id), True, status)

    async def stop_typing(self, chat_id: str, metadata=None) -> None:
        gateway = self._service.gateway if self._service is not None else None
        if gateway is not None:
            await gateway.publish_typing(str(chat_id), False)

    async def on_processing_complete(self, event, outcome) -> None:
        """The reply is finished: save anything still live, and stop the working indicator."""
        await super().on_processing_complete(event, outcome)
        chat_id = str(getattr(getattr(event, "source", None), "chat_id", "") or "")
        if chat_id and self._service is not None:
            await self._live.turn_ended(chat_id)
            await self._service.prompts.turn_ended(chat_id)
            await self.stop_typing(chat_id)

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
        # Lekora's own display defaults: stream (see hermes_streaming.py) and show tool
        # activity in the working indicator instead of as extra chat messages.
        display_overrides={"streaming": hermes_streaming.STREAMING_MARK, "tool_progress": "off"},
        pii_safe=False,
    )
    # Agents send files with a real tool (rule 7), offered only in Lekora chats (docs/files.md).
    try:
        from tools.registry import no_cache_check_fn
        check = no_cache_check_fn(_lekora_session)  # per chat: never reuse another platform's answer
    except ImportError:
        check = _lekora_session
    ctx.register_tool(name=TOOL_NAME, toolset=TOOLSET, schema=TOOL_SCHEMA, handler=_send_file_handler,
                      check_fn=check, description=TOOL_SCHEMA["description"], emoji="📎")
