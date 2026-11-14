"""Async WebSocket gateway: pairing, reconnect/replay, and chat dispatch.

The gateway knows nothing about Hermes. It is given:
  * ``dispatch(profile_id, text, message_id)``: called for each ``chat.send``;
  * ``profiles()``: the profile list advertised in ``hello.ack`` (all equal);
  * ``endpoints(port)``: the candidate URLs advertised in ``pair.response``.
Agent replies come back through :meth:`Gateway.publish_message`.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
import hashlib
import json
import logging
import time
import uuid
from pathlib import Path
from collections import OrderedDict
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import TYPE_CHECKING, Any, Awaitable, Callable, Optional

from .store import Store, TokenExpired, TokenInvalid
from .ws import ConnectionClosed, ServerConnection, serve

if TYPE_CHECKING:
    from .profile_admin import ProfileAdmin
    from .prompts import Prompts

log = logging.getLogger(__name__)

PROTO_VERSION = 1
AUTH_TIMEOUT_SECONDS = 5.0
HEARTBEAT_SECONDS = 30.0
SEEN_IDS_LIMIT = 512
# Chat history (docs/chat-history.md)
RECENT_PER_PROFILE = 50   # a phone with no cache gets each agent's newest 50 messages
MAX_CHANGES_REPLAY = 1000  # more changes than this waiting: send the recent ones instead
PAGE_LIMIT = 100           # history.fetch page size cap

# (profile_id, text, message_id[, files=[{path, name, mime}]])
Dispatch = Callable[..., Awaitable[None]]
ProfilesProvider = Callable[[], list[dict]]
EndpointsProvider = Callable[[int], list[str]]


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


MAX_INSTANCE_NAME = 40
MAX_USER_NAME = 80


@dataclass(eq=False)  # identity hashing: connections live in a set
class _Conn:
    ws: ServerConnection
    device_id: Optional[str] = None
    # Highest change number (rev) this phone already has; live messages at or below it
    # were delivered by the replay and are not sent twice.
    sent_rev: int = 0
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    seen_ids: "OrderedDict[str, None]" = field(default_factory=OrderedDict)

    @property
    def authed(self) -> bool:
        return self.device_id is not None


class _Reject(Exception):
    def __init__(self, code: str, reason: str, recoverable: bool, close: bool,
                 msg_id: Optional[str] = None) -> None:
        self.code, self.reason, self.recoverable = code, reason, recoverable
        self.close, self.msg_id = close, msg_id


class Gateway:
    def __init__(
        self,
        store: Store,
        dispatch: Dispatch,
        profiles: ProfilesProvider,
        endpoints: EndpointsProvider = lambda port: [],
        host: str = "0.0.0.0",
        auth_timeout: float = AUTH_TIMEOUT_SECONDS,
        profile_admin: Optional["ProfileAdmin"] = None,
        ssl_context: Optional[Any] = None,
    ) -> None:
        # wss:// when set (always, from LekoraService); plain ws:// only in low-level tests.
        self._ssl = ssl_context
        self.store = store
        # Creates/deletes Hermes profiles (docs/agent-lifecycle.md); None = not offered.
        self._profile_admin = profile_admin
        # Stored files (docs/files.md); set by LekoraService. None = files not offered.
        self.files: Optional[Any] = None
        # Each agent's voice settings and Hermes' voice (docs/voice.md §2); set by LekoraService.
        self.voice: Optional[Any] = None
        self.voice_replies: Optional[Any] = None
        # An agent's tools in Lekora chats (docs/agent-tools.md); set by LekoraService.
        self.tools: Optional[Any] = None
        # The voice note waiting for Hermes' transcript, per chat (docs/voice.md).
        self._awaiting_transcript: dict[str, int] = {}
        self._dispatch = dispatch
        self._profiles = profiles
        self._endpoints = endpoints
        self.host = host
        self.auth_timeout = auth_timeout
        self.port: Optional[int] = None
        self._server = None
        self._conns: set[_Conn] = set()
        self._tasks: set[asyncio.Task] = set()
        # Approval and question cards (docs/prompts.md); set by LekoraService.
        self.prompts: Optional["Prompts"] = None
        # An agent's slash commands (docs/slash-commands.md); set by LekoraService.
        self.commands_provider: Optional[Callable[[str], list[dict]]] = None
        # Model picker details: catalog, hosts, routing (docs/model-picker.md); set by LekoraService.
        self.models: Optional[Any] = None
        # Per-chat settings (docs/chat-settings.md); set by LekoraService.
        self.settings: Optional[Any] = None

    # ---- lifecycle ---------------------------------------------------------

    async def start(self) -> int:
        """Bind (saved port first, else any free port) and persist the port."""
        saved = self.store.get_persisted_port()
        server = None
        if saved:
            try:
                server = await self._serve(saved)
            except OSError:
                log.warning("Saved port %s is busy; choosing a new one", saved)
        if server is None:
            server = await self._serve(0)
        self._server = server
        self.port = server.sockets[0].getsockname()[1]
        if self.port != saved:
            self.store.set_persisted_port(self.port)
        log.info("Lekora gateway listening on port %s", self.port)
        return self.port

    async def _serve(self, port: int):
        return await serve(
            self._handle, self.host, port,
            ping_interval=HEARTBEAT_SECONDS, ping_timeout=20, ssl=self._ssl,
        )

    async def stop(self) -> None:
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None
        for t in list(self._tasks):
            t.cancel()

    # ---- envelopes ---------------------------------------------------------

    def _envelope(self, type_: str, data: dict, msg_id: Optional[str] = None,
                  profile_id: Optional[str] = None) -> str:
        env: dict[str, Any] = {
            "v": PROTO_VERSION,
            "id": msg_id or str(uuid.uuid4()),
            "type": type_,
            "instance_id": self.store.instance_id,
            "ts": _now(),
            "data": data,
        }
        if profile_id is not None:
            env["profile_id"] = profile_id
        return json.dumps(env)

    async def _send(self, conn: _Conn, text: str) -> None:
        async with conn.lock:
            await conn.ws.send(text)

    @staticmethod
    def _message_data(seq: int, role: str, text: str, rev: int,
                      client_id: Optional[str] = None, draft_id: Optional[str] = None,
                      at: Optional[str] = None, card: Optional[dict] = None,
                      files: Optional[list] = None, voice: Optional[dict] = None,
                      transcript: Optional[str] = None, spoken: Optional[list] = None,
                      voicing: Optional[str] = None, voice_problem: Optional[str] = None,
                      voice_key: Optional[str] = None, spoken_text: Optional[str] = None) -> dict:
        data: dict[str, Any] = {"seq": seq, "role": role, "text": text, "rev": rev}
        if files:
            data["files"] = files  # photos and files with the message (docs/files.md)
        if voice:
            data["voice"] = voice  # a voice note: {duration, waveform} (docs/voice.md)
        if transcript:
            data["transcript"] = transcript  # what Hermes heard
        if spoken:
            data["spoken"] = spoken  # voice mode: the reply in the agent's Hermes voice, in parts
        if voicing:
            data["voicing"] = voicing  # voice mode: a voice note (tts | personality), from the first word
        if voice_problem:
            data["voice_problem"] = voice_problem
        if voice_key:
            data["voice_key"] = voice_key
        if spoken_text:
            data["spoken_text"] = spoken_text
        if card:
            data["card"] = card  # an approval or question card (docs/prompts.md)
        if at:
            data["at"] = at  # when it was saved (UTC, ISO 8601): the phone shows times
        if client_id:
            data["client_id"] = client_id  # the chat.send id: the sender matches its own bubble
        if draft_id:
            data["draft_id"] = draft_id  # replaces the phone's live bubble with this message
        return data

    def _event_json(self, ev) -> str:
        return self._envelope("chat.message", self._message_data(
            ev.seq, ev.payload.get("role", "assistant"), ev.payload.get("text", ""), ev.rev,
            ev.payload.get("client_id"), at=ev.created_at, card=ev.payload.get("card"),
            files=ev.payload.get("files"), voice=ev.payload.get("voice"),
            transcript=ev.payload.get("transcript"), spoken=ev.payload.get("spoken"),
            voicing=ev.payload.get("voicing"), voice_problem=ev.payload.get("voice_problem"),
            voice_key=ev.payload.get("voice_key"), spoken_text=ev.payload.get("spoken_text")),
            profile_id=ev.profile_id)

    # ---- publishing (agent -> phones) --------------------------------------

    async def publish_message(self, profile_id: str, text: str,
                              role: str = "assistant", draft_id: Optional[str] = None) -> int:
        """Record a message as an event and push it to every connected phone."""
        payload: dict[str, Any] = {"role": role, "text": text}
        key = draft_id
        if role == "assistant" and self.voice_replies is not None and text.strip():
            # Voice mode: decided before it's saved, so it never shows as text first.
            key = draft_id or f"reply-{uuid.uuid4().hex[:12]}"
            try:
                style = await self.voice_replies.begin(profile_id, key)
            except Exception:
                log.exception("Lekora: voice reply failed")
                style = None
            if style:
                payload["voicing"] = style
                if key != draft_id:
                    payload["voice_key"] = key  # the id its spoken parts arrive under
        seq = self.store.append_event(profile_id, "chat.message", payload)
        await self._broadcast(self.store.get_event(seq), draft_id=draft_id)
        if role == "assistant" and self.voice_replies is not None and key is not None:
            await self._follow_reply(profile_id, key, text, True, seq)
        return seq

    async def _follow_reply(self, profile_id: str, key: str, text: str, final: bool, seq: Optional[int] = None) -> None:
        """Voice mode (docs/voice.md §2): never let speech trouble stop a reply."""
        try:
            await self.voice_replies.reply_text(profile_id, key, text, final, seq)
        except Exception:
            log.exception("Lekora: voice reply failed")

    async def publish_voice_segment(self, profile_id: str, key: str, index: int, file: dict,
                                    script: Optional[str] = None, inline: Optional[Path] = None) -> None:
        """A spoken part of a reply in voice mode, for phones to play at once (not stored:
        the saved message gets them all as ``spoken``). ``script``: the words it says, when
        they differ from the reply's text (personality voice)."""
        data: dict[str, Any] = {"message_id": key, "index": index, "file": file}
        if script:
            data["script"] = script
        if inline is not None:
            # A small part comes with the segment, so the phone can play it without fetching.
            from .voice_replies import INLINE_AUDIO_BYTES
            try:
                if inline.stat().st_size <= INLINE_AUDIO_BYTES:
                    data["data"] = base64.b64encode(await asyncio.to_thread(inline.read_bytes)).decode("ascii")
            except OSError:
                pass
        await self._broadcast_ephemeral(self._envelope("voice.segment", data, profile_id=profile_id))

    async def publish_voice_stream(self, profile_id: str, key: str, index: int, number: int, rate: int,
                                   pcm: bytes, last: bool = False) -> None:
        """Direct voice (docs/voice.md §4): sound for part ``index`` of a reply as it's made
        (16-bit mono PCM at ``rate``), for phones in a hands-free call to play at once."""
        data: dict[str, Any] = {"message_id": key, "index": index, "chunk": number, "rate": rate,
                                "data": base64.b64encode(pcm).decode("ascii")}
        if last:
            data["last"] = True
        await self._broadcast_ephemeral(self._envelope("voice.stream", data, profile_id=profile_id))

    async def publish_voice_reply(self, profile_id: str, key: str, style: str, problem: Optional[str] = None,
                                  streaming: bool = False) -> None:
        """Voice mode: this reply is (being made into) a voice note; or why its audio can't play."""
        data: dict[str, Any] = {"message_id": key, "style": style}
        if problem:
            data["problem"] = problem
        if streaming:
            data["streaming"] = True  # its sound also comes as voice.stream (docs/voice.md §4)
        await self._broadcast_ephemeral(self._envelope("voice.reply", data, profile_id=profile_id))

    async def attach_spoken(self, seq: int, parts: list[dict], style: str = "tts",
                            problem: Optional[str] = None, spoken_text: Optional[str] = None) -> None:
        """Voice mode: the saved reply becomes a voice note (its text stays as the transcript)."""
        event = self.store.get_event(seq)
        if event is None:
            return
        payload = dict(event.payload, spoken=parts, voicing=style)
        if problem:
            payload["voice_problem"] = problem
        if spoken_text:
            payload["spoken_text"] = spoken_text  # personality voice: what you hear (the text is what was written)
        updated = self.store.update_event_payload(seq, payload)
        if updated is not None:
            await self._broadcast(updated)

    async def publish_card(self, profile_id: str, role: str, text: str, card: dict) -> int:
        """Save an approval or question card as a chat message and send it to every phone."""
        seq = self.store.append_event(profile_id, "chat.message", {"role": role, "text": text, "card": card})
        await self._broadcast(self.store.get_event(seq))
        return seq

    async def update_card(self, seq: int, card: dict, text: Optional[str] = None) -> None:
        """A card's new state (answered, timed out…): saved with a new change number, resent."""
        event = self.store.get_event(seq)
        if event is None:
            return
        payload = dict(event.payload, card=card)
        if text is not None:
            payload["text"] = text
        updated = self.store.update_event_payload(seq, payload)
        if updated is not None:
            await self._broadcast(updated)

    async def update_message(self, seq: int, text: str) -> bool:
        """Change a saved message (Hermes corrected it after it was sealed). Phones receive
        it again with the same seq and replace the text; replays carry the new text."""
        event = self.store.update_event_text(seq, text)
        if event is None:
            return False
        await self._broadcast(event)  # a new change number, so it's never skipped
        return True

    async def publish_draft(self, profile_id: str, draft_id: str, text: str) -> None:
        """Live text of a reply being written (full text so far). Not stored or replayed."""
        if text and self.voice_replies is not None:
            # Voice or text is decided before phones see the first words, so a phone never
            # starts reading a voice reply with the iPhone voice (owner, 2026-11-13: both at once).
            try:
                await self.voice_replies.begin(profile_id, draft_id)
            except Exception:
                log.exception("Lekora: voice reply failed")
        await self._broadcast_ephemeral(self._envelope(
            "chat.draft", {"draft_id": draft_id, "text": text}, profile_id=profile_id))
        if text and self.voice_replies is not None:
            await self._follow_reply(profile_id, draft_id, text, False)

    async def publish_typing(self, profile_id: str, active: bool, status: Optional[str] = None) -> None:
        """Whether an agent is working, and on what. Not stored or replayed."""
        data: dict[str, Any] = {"active": active}
        if active and status:
            data["status"] = status
        await self._broadcast_ephemeral(self._envelope("chat.typing", data, profile_id=profile_id))

    async def _broadcast_ephemeral(self, payload: str) -> None:
        for conn in list(self._conns):
            if not conn.authed or not self.store.is_device_active(conn.device_id):
                continue
            with contextlib.suppress(ConnectionClosed):
                await self._send(conn, payload)

    async def _broadcast(self, ev, draft_id: Optional[str] = None) -> None:
        if ev is None:
            return
        payload = self._envelope("chat.message", self._message_data(
            ev.seq, ev.payload.get("role", "assistant"), ev.payload.get("text", ""), ev.rev,
            ev.payload.get("client_id"), draft_id, at=ev.created_at, card=ev.payload.get("card"),
            files=ev.payload.get("files"), voice=ev.payload.get("voice"),
            transcript=ev.payload.get("transcript"), spoken=ev.payload.get("spoken"),
            voicing=ev.payload.get("voicing"), voice_problem=ev.payload.get("voice_problem"),
            voice_key=ev.payload.get("voice_key"), spoken_text=ev.payload.get("spoken_text")),
            profile_id=ev.profile_id)
        for conn in list(self._conns):
            if not conn.authed:
                continue
            try:
                if not self.store.is_device_active(conn.device_id):
                    # Revoked from the CLI while connected: send nothing more, drop it.
                    await conn.ws.close(1008, "AUTH_FAILED")
                    continue
                async with conn.lock:
                    if ev.rev <= conn.sent_rev:
                        continue  # already delivered by the replay
                    await conn.ws.send(payload)
                    conn.sent_rev = ev.rev
            except ConnectionClosed:
                pass

    # ---- connection handling -----------------------------------------------

    async def _handle(self, ws: ServerConnection) -> None:
        conn = _Conn(ws)
        self._conns.add(conn)
        deadline = time.monotonic() + self.auth_timeout
        try:
            while True:
                if conn.authed:
                    raw = await ws.recv()
                else:
                    remaining = deadline - time.monotonic()
                    try:
                        raw = await asyncio.wait_for(ws.recv(), max(remaining, 0))
                    except asyncio.TimeoutError:
                        await ws.close(1008, "authentication timeout")
                        return
                try:
                    await self._process(conn, raw)
                except _Reject as r:
                    await self._send(conn, self._envelope(
                        "error",
                        {"code": r.code, "reason": r.reason, "recoverable": r.recoverable},
                        msg_id=r.msg_id))
                    if r.close:
                        await ws.close(1008, r.code)
                        return
        except ConnectionClosed:
            pass
        finally:
            self._conns.discard(conn)

    async def _process(self, conn: _Conn, raw: Any) -> None:
        if isinstance(raw, bytes):
            raise _Reject("INVALID_MESSAGE", "Binary frames are not supported",
                          True, not conn.authed)
        try:
            env = json.loads(raw)
            type_, msg_id, data = env["type"], env.get("id"), env.get("data") or {}
            if not isinstance(type_, str) or not isinstance(data, dict):
                raise ValueError
        except (ValueError, KeyError, TypeError):
            raise _Reject("INVALID_MESSAGE", "Malformed message", True, not conn.authed)

        if env.get("v", PROTO_VERSION) != PROTO_VERSION:
            raise _Reject("INCOMPATIBLE_VERSION", "Unsupported protocol version",
                          False, True, msg_id)
        if env.get("instance_id") != self.store.instance_id:
            raise _Reject("INVALID_MESSAGE", "instance_id does not match this host",
                          False, True, msg_id)

        if type_ == "pair.request":
            await self._pair(conn, msg_id, data)
        elif type_ == "hello":
            await self._hello(conn, msg_id, data)
        elif type_ == "device.unpair":
            await self._unpair(conn, msg_id, data)
        elif not conn.authed:
            raise _Reject("AUTH_FAILED", "Authenticate with pair.request or hello first",
                          False, True, msg_id)
        elif not self.store.is_device_active(conn.device_id):
            # Revoked (e.g. `hermes lekora devices --revoke`) while this socket was open.
            raise _Reject("AUTH_FAILED", "This device was removed from the host; pair again",
                          False, True, msg_id)
        elif type_ == "chat.send":
            await self._chat_send(conn, msg_id, env.get("profile_id"), data)
        elif type_ == "history.fetch":
            await self._history_fetch(conn, msg_id, env.get("profile_id"), data)
        elif type_ == "chat.read":
            await self._chat_read(conn, env.get("profile_id"), data)
        elif type_ in ("settings.get", "settings.set", "settings.action"):
            await self._settings_request(conn, msg_id, type_, env.get("profile_id"), data)
        elif type_ in ("models.catalog", "models.hosts", "models.routing.set"):
            await self._models_request(conn, msg_id, type_, env.get("profile_id"), data)
        elif type_ == "commands.list":
            await self._commands_list(conn, msg_id, env.get("profile_id"))
        elif type_ in ("file.upload.begin", "file.upload.chunk", "file.upload.end", "file.read", "files.usage"):
            await self._file_request(conn, msg_id, type_, env.get("profile_id"), data)
        elif type_ in ("agent.tools.get", "agent.tools.set"):
            await self._tools_request(conn, msg_id, type_, env.get("profile_id"), data)
        elif type_ in ("voice.settings.get", "voice.settings.set", "voice.speak",
                       "voice.direct.get", "voice.direct.set", "voice.direct.test"):
            await self._voice_request(conn, msg_id, type_, env.get("profile_id"), data)
        elif type_ == "instance.rename":
            await self._instance_rename(conn, msg_id, data)
        elif type_ == "user.name.set":
            await self._user_name_set(conn, msg_id, data)
        elif type_ == "voice.log":
            # A hands-free call's diagnostics from the phone (never what was said).
            line = " ".join(str(data.get("line") or "").split())[:300]
            if line:
                log.info("Lekora phone call (%s): %s", env.get("profile_id"), line)
        elif type_ == "voice.timing":
            if self.voice_replies is not None:
                self.voice_replies.phone_timing(env.get("profile_id"), data)
        elif type_ == "prompt.respond":
            await self._prompt_respond(conn, msg_id, env.get("profile_id"), data)
        elif type_ in ("profile.create", "profile.delete"):
            if self._profile_admin is None:
                raise _Reject("PROFILE_ADMIN_UNAVAILABLE",
                              "Agents can't be added or deleted from the phone on this host",
                              True, False, msg_id)
            # Runs in the background: cloning or backing up a profile takes seconds, and
            # this connection must keep reading (pings, other messages) meanwhile.
            self._spawn(self._profile_op(conn, msg_id, type_, data))
        else:
            raise _Reject("INVALID_MESSAGE", f"Unknown message type: {type_}",
                          True, False, msg_id)

    # ---- handlers ----------------------------------------------------------

    async def _pair(self, conn: _Conn, msg_id: Optional[str], data: dict) -> None:
        versions = data.get("supported_proto_versions") or []
        if PROTO_VERSION not in versions:
            raise _Reject("INCOMPATIBLE_VERSION",
                          "This host speaks protocol version 1", False, True, msg_id)
        token = data.get("pairing_token")
        if not isinstance(token, str):
            raise _Reject("TOKEN_INVALID", "Missing pairing token", False, True, msg_id)
        peer = conn.ws.remote_address
        try:
            self.store.consume_invite(token, client_ip=peer[0] if peer else None)
        except TokenExpired:
            raise _Reject("TOKEN_EXPIRED", "Pairing code expired; create a new one",
                          False, True, msg_id)
        except TokenInvalid:
            raise _Reject("TOKEN_INVALID", "Pairing code is invalid or already used",
                          False, True, msg_id)
        device_id, device_token = self.store.register_device(
            str(data.get("device_name", "")), str(data.get("client_version", "")))
        conn.device_id = device_id
        await self._send(conn, self._envelope("pair.response", {
            "status": "ok",
            "proto_version": PROTO_VERSION,
            "device_id": device_id,
            "device_token": device_token,
            "instance_name": self.store.get_instance_name(),
            "endpoints": self._endpoints(self.port or 0),
        }, msg_id=msg_id))

    async def _unpair(self, conn: _Conn, msg_id: Optional[str], data: dict) -> None:
        """The app's "Forget Host": revoke this device, then close its sockets.

        Carries its own credentials (like ``hello``) so the app can send it on a fresh
        socket without a replay, whether or not it is currently connected."""
        device_id, token = data.get("device_id"), data.get("device_token")
        if not (isinstance(device_id, str) and isinstance(token, str)
                and self.store.verify_device_token(device_id, token)):
            raise _Reject("AUTH_FAILED", "Invalid or revoked device token",
                          False, True, msg_id)
        self.store.revoke_device(device_id)
        await self._send(conn, self._envelope(
            "device.unpair.ack", {"status": "ok", "device_id": device_id}, msg_id=msg_id))
        for other in list(self._conns):
            if other is not conn and other.device_id == device_id:
                try:
                    await other.ws.close(1000, "device unpaired")
                except ConnectionClosed:
                    pass
        await conn.ws.close(1000, "device unpaired")

    async def _hello(self, conn: _Conn, msg_id: Optional[str], data: dict) -> None:
        if data.get("proto_version", PROTO_VERSION) != PROTO_VERSION:
            raise _Reject("INCOMPATIBLE_VERSION",
                          "This host speaks protocol version 1", False, True, msg_id)
        device_id, token = data.get("device_id"), data.get("device_token")
        if not (isinstance(device_id, str) and isinstance(token, str)
                and self.store.verify_device_token(device_id, token)):
            raise _Reject("AUTH_FAILED", "Invalid or revoked device token",
                          False, True, msg_id)
        def number(key: str) -> Optional[int]:
            try:
                return max(int(data[key]), 0) if key in data else None
            except (TypeError, ValueError):
                return 0
        last_seq, since_rev = number("last_seq") or 0, number("since_rev")
        conn.device_id = device_id
        profiles = self._profiles()
        ack: dict[str, Any] = {
            "status": "ok",
            "current_seq": self.store.current_seq(),
            "instance_name": self.store.get_instance_name(),
            "user_name": self.store.get_user_name(),
            "profiles": profiles,
        }
        # No await between reading the store and choosing what to send, so nothing saved
        # meanwhile can slip between the replay and the live messages.
        rev_now = self.store.current_rev()
        if since_rev is None:  # an app from before chat history: everything after last_seq
            replay = [e for e in self.store.fetch_events_since(last_seq)
                      if e.event_type == "chat.message"]
        else:
            replay = []
            if since_rev > 0:
                replay = self.store.messages_changed_since(since_rev, MAX_CHANGES_REPLAY + 1)
            if since_rev > 0 and len(replay) <= MAX_CHANGES_REPLAY:
                ack["replay"] = "changes"
            else:
                ack["replay"] = "recent"
                replay = self.store.recent_messages(RECENT_PER_PROFILE)
            ack["rev"] = rev_now
            ack["message_times"] = True  # messages carry "at" (docs/agents-home.md)
            ack["read"] = {p["profile_id"]: self.store.read_marker(p["profile_id"]) for p in profiles}
        # Hold the connection lock so live broadcasts queue behind the replay.
        async with conn.lock:
            conn.sent_rev = max([rev_now] + [e.rev for e in replay])
            await conn.ws.send(self._envelope("hello.ack", ack, msg_id=msg_id))
            for ev in replay:
                await conn.ws.send(self._event_json(ev))

    async def _chat_send(self, conn: _Conn, msg_id: Optional[str],
                         profile_id: Any, data: dict) -> None:
        known = {p["profile_id"] for p in self._profiles()}
        if not isinstance(profile_id, str) or profile_id not in known:
            raise _Reject("UNKNOWN_PROFILE", "Unknown profile", True, False, msg_id)
        text = data.get("text")
        if text is None and data.get("files"):
            text = ""
        file_ids = data.get("files") or []
        if not isinstance(text, str) or (not text.strip() and not file_ids):
            raise _Reject("INVALID_MESSAGE", "chat.send needs non-empty text",
                          True, False, msg_id)
        files = self._message_files(profile_id, file_ids, msg_id)
        voice = self._voice_details(data.get("voice"), files, msg_id)
        if msg_id:  # commands are idempotent: ignore a repeated id
            if msg_id in conn.seen_ids:
                return
            conn.seen_ids[msg_id] = None
            while len(conn.seen_ids) > SEEN_IDS_LIMIT:
                conn.seen_ids.popitem(last=False)
        payload: dict[str, Any] = {"role": "user", "text": text}
        if files:
            payload["files"] = [self.files.describe(row) for row in files]  # type: ignore[union-attr]
        if voice:
            payload["voice"] = voice
        if msg_id:
            payload["client_id"] = msg_id
        seq = self.store.append_event(profile_id, "chat.message", payload)
        # Every phone gets it, the sender too: client_id tells it which bubble now has this seq.
        await self._broadcast(self.store.get_event(seq))
        if self.prompts is not None:  # a typed /approve or reply answers waiting cards
            await self.prompts.user_message(profile_id, text)
        attachments = [{"path": str(self.files.path_of(row)), "name": row["name"], "mime": row["mime"]}  # type: ignore[union-attr]
                       for row in files]
        if voice:
            attachments[0]["voice"] = True  # Hermes transcribes it (docs/voice.md)
            self._awaiting_transcript[profile_id] = seq
        if self.voice_replies is not None:
            self.voice_replies.user_message(profile_id, bool(voice), bool(data.get("hands_free")))
        task = asyncio.create_task(self._run_dispatch(conn, msg_id, profile_id, text, attachments,
                                                      spoken=bool(data.get("hands_free")) and not voice,
                                                      in_call=bool(data.get("hands_free"))))
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    def _known_profile(self, profile_id: Any, msg_id: Optional[str]) -> str:
        known = {p["profile_id"] for p in self._profiles()}
        if not isinstance(profile_id, str) or profile_id not in known:
            raise _Reject("UNKNOWN_PROFILE", "Unknown profile", True, False, msg_id)
        return profile_id

    async def _history_fetch(self, conn: _Conn, msg_id: Optional[str],
                             profile_id: Any, data: dict) -> None:
        """A page of one agent's older messages (the phone scrolled up)."""
        profile_id = self._known_profile(profile_id, msg_id)
        try:
            before = data.get("before_seq")
            before = int(before) if before is not None else None
            limit = min(max(int(data.get("limit", PAGE_LIMIT)), 1), PAGE_LIMIT)
        except (TypeError, ValueError):
            raise _Reject("INVALID_MESSAGE", "history.fetch needs numbers", True, False, msg_id)
        events, has_more = self.store.messages_before(profile_id, before, limit)
        messages = [self._message_data(e.seq, e.payload.get("role", "assistant"),
                                       e.payload.get("text", ""), e.rev, e.payload.get("client_id"),
                                       at=e.created_at, card=e.payload.get("card"), files=e.payload.get("files"),
                                       voice=e.payload.get("voice"), transcript=e.payload.get("transcript"),
                                       spoken=e.payload.get("spoken"), voicing=e.payload.get("voicing"),
                                       voice_problem=e.payload.get("voice_problem"), voice_key=e.payload.get("voice_key"),
                                       spoken_text=e.payload.get("spoken_text"))
                    for e in events]
        await self._send(conn, self._envelope(
            "history.page", {"messages": messages, "has_more": has_more},
            msg_id=msg_id, profile_id=profile_id))

    async def _settings_request(self, conn: _Conn, msg_id: Optional[str], type_: str,
                                profile_id: Any, data: dict) -> None:
        """Read or change a chat's settings (docs/chat-settings.md)."""
        from .chat_settings import SettingsError
        profile_id = self._known_profile(profile_id, msg_id)
        if self.settings is None:
            raise _Reject("UNAVAILABLE", "Chat settings aren't available on this host", True, False, msg_id)
        try:
            if type_ == "settings.get":
                result = await asyncio.to_thread(self.settings.read, profile_id)
            elif type_ == "settings.set":
                current = await asyncio.to_thread(self.settings.read, profile_id)
                result = await self.settings.change(profile_id, str(data.get("key") or ""), data.get("value"), current)
            else:
                result = await self.settings.act(profile_id, str(data.get("action") or ""))
        except SettingsError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)
        except Exception:
            log.exception("Lekora: %s failed", type_)
            raise _Reject("UNAVAILABLE", "Couldn't reach Hermes' settings right now", True, False, msg_id)
        await self._send(conn, self._envelope(type_ + ".result", result, msg_id=msg_id, profile_id=profile_id))

    async def _models_request(self, conn: _Conn, msg_id: Optional[str], type_: str,
                              profile_id: Any, data: dict) -> None:
        """The model picker's details (docs/model-picker.md). Network and disk: off the loop."""
        from .routing_config import RoutingError
        profile_id = self._known_profile(profile_id, msg_id)
        if self.models is None:
            raise _Reject("UNAVAILABLE", "Model details aren't available on this host", True, False, msg_id)
        model = data.get("model")
        try:
            if type_ == "models.catalog":
                provider = str(data.get("provider") or "")
                ids = [str(m) for m in (data.get("models") or [])][:200]
                result = await asyncio.to_thread(self.models.catalog, provider, ids)
            elif not isinstance(model, str) or not model:
                raise _Reject("INVALID_MESSAGE", "Which model?", True, False, msg_id)
            elif type_ == "models.hosts":
                result = await asyncio.to_thread(self.models.hosts, profile_id, model)
            else:
                hosts = data.get("hosts") if isinstance(data.get("hosts"), list) else []
                result = await asyncio.to_thread(self.models.set_routing, profile_id, model,
                                                 str(data.get("mode") or ""), [str(h) for h in hosts],
                                                 bool(data.get("no_training")))
        except RoutingError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)
        except _Reject:
            raise
        except Exception:
            log.exception("Lekora: %s failed", type_)
            raise _Reject("UNAVAILABLE", "Couldn't get that from OpenRouter or Hermes right now", True, False, msg_id)
        await self._send(conn, self._envelope(type_ + ".result", result, msg_id=msg_id, profile_id=profile_id))

    async def _commands_list(self, conn: _Conn, msg_id: Optional[str], profile_id: Any) -> None:
        """The slash commands this agent can use, read from Hermes (docs/slash-commands.md)."""
        profile_id = self._known_profile(profile_id, msg_id)
        commands: list[dict] = []
        if self.commands_provider is not None:
            try:
                commands = await asyncio.wait_for(
                    asyncio.to_thread(self.commands_provider, profile_id), timeout=10)
            except Exception:
                log.exception("Lekora: could not list commands for %s", profile_id)
                commands = []
        fingerprint = hashlib.sha256(json.dumps(commands, sort_keys=True).encode()).hexdigest()[:16]
        await self._send(conn, self._envelope(
            "commands.list.result", {"commands": commands, "fingerprint": fingerprint},
            msg_id=msg_id, profile_id=profile_id))

    async def _prompt_respond(self, conn: _Conn, msg_id: Optional[str], profile_id: Any, data: dict) -> None:
        """The phone answered an approval or question card (docs/prompts.md)."""
        from .prompts import PromptError
        if self.prompts is None:
            raise _Reject("UNKNOWN_CARD", "This host has no cards to answer", True, False, msg_id)
        profile_id = self._known_profile(profile_id, msg_id)
        try:
            card_id, status = await self.prompts.respond(profile_id, data)
        except PromptError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)
        ack: dict[str, Any] = {"card_id": card_id, "status": status}
        if status == "needs_confirmation" and self.prompts.last_warning:
            ack["message"] = self.prompts.last_warning  # e.g. why a model is flagged as expensive
        await self._send(conn, self._envelope("prompt.respond.ack", ack, msg_id=msg_id, profile_id=profile_id))

    async def _chat_read(self, conn: _Conn, profile_id: Any, data: dict) -> None:
        """A phone read an agent's chat up to ``seq``: remember it, tell the other phones."""
        if not isinstance(profile_id, str):
            return
        try:
            seq = int(data.get("seq"))
        except (TypeError, ValueError):
            return
        if not self.store.mark_read(profile_id, seq):
            return
        payload = self._envelope("chat.read", {"seq": self.store.read_marker(profile_id)},
                                 profile_id=profile_id)
        for other in list(self._conns):
            if other is conn or not other.authed or not self.store.is_device_active(other.device_id):
                continue
            with contextlib.suppress(ConnectionClosed):
                await self._send(other, payload)

    def _spawn(self, coro) -> None:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def _profile_op(self, conn: _Conn, msg_id: Optional[str], type_: str, data: dict) -> None:
        from .profile_admin import ProfileAdminError
        try:
            if type_ == "profile.create":
                created = await self._profile_admin.create(data.get("name"), data.get("description"))
                ack = self._envelope("profile.create.ack", {"status": "ok", "profile": created}, msg_id=msg_id)
            else:
                profile_id = data.get("profile_id")
                backup = await self._profile_admin.delete(profile_id, data.get("confirm"))
                ack = self._envelope("profile.delete.ack",
                                     {"status": "ok", "profile_id": profile_id, "backup": backup},
                                     msg_id=msg_id)
        except ProfileAdminError as exc:
            reply = self._envelope("error", {"code": exc.code, "reason": exc.reason, "recoverable": True},
                                   msg_id=msg_id)
            with contextlib.suppress(ConnectionClosed):
                await self._send(conn, reply)
            return
        except Exception:
            log.exception("Profile operation failed")
            reply = self._envelope("error", {"code": "PROFILE_OP_FAILED",
                                             "reason": "The agent change failed on the host",
                                             "recoverable": True}, msg_id=msg_id)
            with contextlib.suppress(ConnectionClosed):
                await self._send(conn, reply)
            return
        with contextlib.suppress(ConnectionClosed):
            await self._send(conn, ack)
        await self.broadcast_profiles()

    @staticmethod
    def _voice_details(voice: Any, files: list[dict], msg_id: Optional[str]) -> Optional[dict]:
        """A voice note's length and waveform (docs/voice.md); needs exactly one audio file."""
        if not voice:
            return None
        if not isinstance(voice, dict) or len(files) != 1 or not str(files[0]["mime"]).startswith("audio/"):
            raise _Reject("INVALID_FILE", "A voice note is one recording", True, False, msg_id)
        try:
            duration = round(max(float(voice.get("duration") or 0), 0.0), 2)
            waveform = [round(min(max(float(v), 0.0), 1.0), 3) for v in (voice.get("waveform") or [])][:64]
        except (TypeError, ValueError):
            raise _Reject("INVALID_FILE", "A voice note's details were damaged", True, False, msg_id)
        return {"duration": duration, "waveform": waveform}

    async def attach_transcript(self, profile_id: str, text: str) -> bool:
        """Hermes' transcript of the latest voice note in this chat goes on that message
        (every phone updated) instead of showing as its own line. False if none is waiting."""
        seq = self._awaiting_transcript.pop(profile_id, None)
        event = self.store.get_event(seq) if seq is not None else None
        if event is None or not event.payload.get("voice"):
            return False
        updated = self.store.update_event_payload(seq, dict(event.payload, transcript=text))
        if updated is not None:
            await self._broadcast(updated)
        return True

    def _message_files(self, profile_id: str, file_ids: Any, msg_id: Optional[str]) -> list[dict]:
        """The uploaded files a chat.send refers to (docs/files.md)."""
        from .files import MAX_FILES_PER_MESSAGE, FileError
        if not file_ids:
            return []
        if self.files is None:
            raise _Reject("UNAVAILABLE", "Files aren't available on this host", True, False, msg_id)
        if not isinstance(file_ids, list) or len(file_ids) > MAX_FILES_PER_MESSAGE:
            raise _Reject("INVALID_FILE", f"Up to {MAX_FILES_PER_MESSAGE} files per message", True, False, msg_id)
        try:
            return [self.files.ready(str(f), profile_id) for f in file_ids]
        except FileError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)

    async def _file_request(self, conn: _Conn, msg_id: Optional[str], type_: str,
                            profile_id: Any, data: dict) -> None:
        """Uploads in pieces, reading files back, and the space used (docs/files.md).
        Disk work runs off the event loop."""
        from .files import FileError
        if self.files is None:
            raise _Reject("UNAVAILABLE", "Files aren't available on this host", True, False, msg_id)
        files = self.files
        try:
            if type_ == "files.usage":
                result = await asyncio.to_thread(files.usage)
            elif type_ == "file.read":
                result = await asyncio.to_thread(files.read_chunk, data.get("file_id"), data.get("offset"))
            else:
                profile_id = self._known_profile(profile_id, msg_id)
                if type_ == "file.upload.begin":
                    result = await asyncio.to_thread(files.begin_upload, profile_id, str(data.get("name") or ""),
                                                     data.get("mime"), data.get("size"))
                elif type_ == "file.upload.chunk":
                    received = await asyncio.to_thread(files.write_chunk, profile_id, data.get("file_id"),
                                                       data.get("offset"), data.get("data"))
                    result = {"file_id": data.get("file_id"), "received": received}
                else:
                    result = {"file": await asyncio.to_thread(files.finish_upload, profile_id, data.get("file_id"))}
        except FileError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)
        except OSError:
            log.exception("Lekora: %s failed", type_)
            raise _Reject("UNAVAILABLE", "Couldn't store the file on this host", True, False, msg_id)
        await self._send(conn, self._envelope(type_ + ".result", result, msg_id=msg_id, profile_id=profile_id))

    async def publish_files(self, profile_id: str, files: list[dict], text: str = "") -> int:
        """Files from the agent, as one chat message (with its caption, if any)."""
        seq = self.store.append_event(profile_id, "chat.message",
                                      {"role": "assistant", "text": text, "files": files})
        await self._broadcast(self.store.get_event(seq))
        return seq

    async def _tools_request(self, conn: _Conn, msg_id: Optional[str], type_: str,
                             profile_id: Any, data: dict) -> None:
        """Which Hermes tools an agent has in Lekora chats (docs/agent-tools.md)."""
        from .agent_tools import ToolsError
        profile_id = self._known_profile(profile_id, msg_id)
        if self.tools is None:
            raise _Reject("UNAVAILABLE", "Tools can't be changed from the phone on this Hermes instance", True, False, msg_id)
        try:
            if type_ == "agent.tools.get":
                result = await self.tools.get(profile_id)
            else:
                result = await self.tools.set(profile_id, data.get("changes"))
        except ToolsError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)
        except Exception:
            log.exception("Lekora: %s failed", type_)
            raise _Reject("UNAVAILABLE", "Couldn't read this agent's tools from Hermes", True, False, msg_id)
        await self._send(conn, self._envelope(type_ + ".result", result, msg_id=msg_id, profile_id=profile_id))

    async def _voice_request(self, conn: _Conn, msg_id: Optional[str], type_: str,
                             profile_id: Any, data: dict) -> None:
        """An agent's voice settings, and its replies in Hermes' voice (docs/voice.md §2)."""
        from .voice_settings import VoiceError
        profile_id = self._known_profile(profile_id, msg_id)
        if self.voice is None:
            raise _Reject("UNAVAILABLE", "Voice settings aren't available on this host", True, False, msg_id)
        voice = self.voice
        if type_.startswith("voice.direct."):
            await self._direct_voice_request(conn, msg_id, type_, profile_id, data)
            return
        try:
            if type_ == "voice.settings.get":
                result = await asyncio.to_thread(voice.get, profile_id)
            elif type_ == "voice.settings.set":
                settings = voice.set(profile_id, data.get("settings"))
                result = {"settings": settings}
                # Every other phone uses the new voice straight away.
                payload = self._envelope("voice.settings.changed", result, profile_id=profile_id)
                for other in list(self._conns):
                    if other is conn or not other.authed or not self.store.is_device_active(other.device_id):
                        continue
                    with contextlib.suppress(ConnectionClosed):
                        await self._send(other, payload)
            else:
                try:
                    seq = int(data.get("seq"))
                except (TypeError, ValueError):
                    raise _Reject("INVALID_MESSAGE", "Which reply?", True, False, msg_id)
                event = self.store.get_event(seq)
                if event is None or event.profile_id != profile_id or event.payload.get("role") != "assistant" \
                        or not str(event.payload.get("text") or "").strip():
                    raise _Reject("UNKNOWN_MESSAGE", "That reply isn't here", True, False, msg_id)
                parts = await asyncio.to_thread(voice.speak, profile_id, seq, event.payload["text"])
                result = {"seq": seq, "file": parts[0], "files": parts}
        except VoiceError as exc:
            raise _Reject(exc.code, exc.reason, True, False, msg_id)
        await self._send(conn, self._envelope(type_ + ".result", result, msg_id=msg_id, profile_id=profile_id))

    async def _direct_voice_request(self, conn: _Conn, msg_id: Optional[str], type_: str,
                                    profile_id: str, data: dict) -> None:
        """Direct voice settings and a test (docs/voice.md §4). Keys are never sent back."""
        from .direct_voice import DirectVoiceError
        direct = getattr(self.voice_replies, "direct", None)
        if direct is None:
            raise _Reject("UNAVAILABLE", "Direct voice isn't available on this host", True, False, msg_id)
        if type_ == "voice.direct.get":
            result = await asyncio.to_thread(direct.describe, profile_id)
        elif type_ == "voice.direct.set":
            result = await asyncio.to_thread(direct.set, profile_id, data.get("settings"), data.get("key"))
        else:
            try:
                result = {"file": await self._direct_voice_test(profile_id, direct, str(data.get("text") or ""))}
            except DirectVoiceError as exc:
                raise _Reject(exc.code, exc.reason, True, False, msg_id)
        await self._send(conn, self._envelope(type_ + ".result", result, msg_id=msg_id, profile_id=profile_id))

    async def _direct_voice_test(self, profile_id: str, direct: Any, text: str) -> dict:
        """A short sample in the chosen direct voice, as a file to play."""
        from .direct_voice import DirectVoiceError
        from .voice_replies import _write_audio
        found = await asyncio.to_thread(direct.resolve, profile_id)
        if found is None:
            raise DirectVoiceError("VOICE_NOT_STREAMING",
                                   "This choice can't stream here, so replies are made the usual way.")
        _, speak = found

        def make() -> tuple[int, bytes]:
            rate, chunks = speak(" ".join(text.split())[:300] or "Hi! This is how I'll sound in our calls.")
            return rate, b"".join(chunks)
        rate, pcm = await asyncio.to_thread(make)
        if not pcm:
            raise DirectVoiceError("VOICE_FAILED", "The voice service sent no sound.")
        path = await asyncio.to_thread(_write_audio, rate, pcm)
        return await asyncio.to_thread(self.files.add_agent_file, profile_id, path, f"Voice sample{path.suffix}")  # type: ignore[union-attr]

    async def _instance_rename(self, conn: _Conn, msg_id: Optional[str], data: dict) -> None:
        """Rename this computer as the app shows it (docs/multiple-instances.md)."""
        name = " ".join(str(data.get("name") or "").split())
        if not name or len(name) > MAX_INSTANCE_NAME or any(ord(c) < 32 for c in name):
            raise _Reject("INVALID_NAME", f"Use 1 to {MAX_INSTANCE_NAME} characters", True, False, msg_id)
        self.store.rename_instance(name)
        await self._send(conn, self._envelope("instance.rename.result", {"instance_name": name}, msg_id=msg_id))
        # Every other phone shows the new name straight away.
        payload = self._envelope("instance.changed", {"instance_name": name,
                                                      "user_name": self.store.get_user_name()})
        for other in list(self._conns):
            if other is conn or not other.authed or not self.store.is_device_active(other.device_id):
                continue
            with contextlib.suppress(ConnectionClosed):
                await self._send(other, payload)

    async def _user_name_set(self, conn: _Conn, msg_id: Optional[str], data: dict) -> None:
        """What this instance's agents call you (docs/your-name.md); "" clears it."""
        name = " ".join(str(data.get("name") or "").split())
        if len(name) > MAX_USER_NAME or any(ord(c) < 32 for c in name):
            raise _Reject("INVALID_NAME", f"Use up to {MAX_USER_NAME} characters", True, False, msg_id)
        self.store.set_user_name(name)
        await self._send(conn, self._envelope("user.name.set.result", {"user_name": name}, msg_id=msg_id))
        payload = self._envelope("instance.changed", {"instance_name": self.store.get_instance_name(),
                                                      "user_name": name})
        for other in list(self._conns):
            if other is conn or not other.authed or not self.store.is_device_active(other.device_id):
                continue
            with contextlib.suppress(ConnectionClosed):
                await self._send(other, payload)

    async def broadcast_profiles(self) -> None:
        """Tell every connected phone the agent list changed."""
        payload = self._envelope("profiles.changed", {"profiles": self._profiles()})
        for conn in list(self._conns):
            if not conn.authed or not self.store.is_device_active(conn.device_id):
                continue
            with contextlib.suppress(ConnectionClosed):
                await self._send(conn, payload)

    async def _run_dispatch(self, conn: _Conn, msg_id: Optional[str],
                            profile_id: str, text: str, files: Optional[list] = None,
                            spoken: bool = False, in_call: bool = False) -> None:
        try:
            extra: dict[str, Any] = {}
            if files:  # only when needed: bridges from before take (profile, text, id)
                extra["files"] = files
            if spoken:
                # Said aloud in a call (recognised on the phone): Hermes' own voice turn.
                extra["spoken"] = True
            if self.voice_replies is not None:
                try:
                    instructions = await self.voice_replies.turn_instructions(profile_id)
                except Exception:
                    log.exception("Lekora: couldn't prepare personality voice")
                    instructions = None
                if in_call:
                    # A hands-free call (docs/voice.md §3): it's a spoken conversation.
                    from .voice_replies import CALL_NOTE
                    instructions = "\n\n".join(part for part in (CALL_NOTE, instructions) if part)
                if instructions:
                    extra["instructions"] = instructions  # personality voice (docs/voice.md §2)
            await self._dispatch(profile_id, text, msg_id or str(uuid.uuid4()), **extra)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("Agent dispatch failed")
            try:
                await self._send(conn, self._envelope(
                    "error",
                    {"code": "AGENT_ERROR", "reason": "The agent could not take this message",
                     "recoverable": True},
                    msg_id=msg_id))
            except ConnectionClosed:
                pass
