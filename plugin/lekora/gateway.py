"""Async WebSocket gateway: pairing, reconnect/replay, and chat dispatch.

The gateway knows nothing about Hermes. It is given:
  * ``dispatch(profile_id, text, message_id)``: called for each ``chat.send``;
  * ``profiles()``: the profile list advertised in ``hello.ack`` (all equal);
  * ``endpoints(port)``: the candidate URLs advertised in ``pair.response``.
Agent replies come back through :meth:`Gateway.publish_message`.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import logging
import time
import uuid
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

Dispatch = Callable[[str, str, str], Awaitable[None]]
ProfilesProvider = Callable[[], list[dict]]
EndpointsProvider = Callable[[int], list[str]]


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


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
                      at: Optional[str] = None, card: Optional[dict] = None) -> dict:
        data: dict[str, Any] = {"seq": seq, "role": role, "text": text, "rev": rev}
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
            ev.payload.get("client_id"), at=ev.created_at, card=ev.payload.get("card")),
            profile_id=ev.profile_id)

    # ---- publishing (agent -> phones) --------------------------------------

    async def publish_message(self, profile_id: str, text: str,
                              role: str = "assistant", draft_id: Optional[str] = None) -> int:
        """Record a message as an event and push it to every connected phone."""
        seq = self.store.append_event(
            profile_id, "chat.message", {"role": role, "text": text})
        await self._broadcast(self.store.get_event(seq), draft_id=draft_id)
        return seq

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
        await self._broadcast_ephemeral(self._envelope(
            "chat.draft", {"draft_id": draft_id, "text": text}, profile_id=profile_id))

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
            ev.payload.get("client_id"), draft_id, at=ev.created_at, card=ev.payload.get("card")),
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
        elif type_ == "commands.list":
            await self._commands_list(conn, msg_id, env.get("profile_id"))
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
        if not isinstance(text, str) or not text.strip():
            raise _Reject("INVALID_MESSAGE", "chat.send needs non-empty text",
                          True, False, msg_id)
        if msg_id:  # commands are idempotent: ignore a repeated id
            if msg_id in conn.seen_ids:
                return
            conn.seen_ids[msg_id] = None
            while len(conn.seen_ids) > SEEN_IDS_LIMIT:
                conn.seen_ids.popitem(last=False)
        payload = {"role": "user", "text": text}
        if msg_id:
            payload["client_id"] = msg_id
        seq = self.store.append_event(profile_id, "chat.message", payload)
        # Every phone gets it, the sender too: client_id tells it which bubble now has this seq.
        await self._broadcast(self.store.get_event(seq))
        if self.prompts is not None:  # a typed /approve or reply answers waiting cards
            await self.prompts.user_message(profile_id, text)
        task = asyncio.create_task(self._run_dispatch(conn, msg_id, profile_id, text))
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
                                       at=e.created_at, card=e.payload.get("card"))
                    for e in events]
        await self._send(conn, self._envelope(
            "history.page", {"messages": messages, "has_more": has_more},
            msg_id=msg_id, profile_id=profile_id))

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
        await self._send(conn, self._envelope(
            "prompt.respond.ack", {"card_id": card_id, "status": status},
            msg_id=msg_id, profile_id=profile_id))

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

    async def broadcast_profiles(self) -> None:
        """Tell every connected phone the agent list changed."""
        payload = self._envelope("profiles.changed", {"profiles": self._profiles()})
        for conn in list(self._conns):
            if not conn.authed or not self.store.is_device_active(conn.device_id):
                continue
            with contextlib.suppress(ConnectionClosed):
                await self._send(conn, payload)

    async def _run_dispatch(self, conn: _Conn, msg_id: Optional[str],
                            profile_id: str, text: str) -> None:
        try:
            await self._dispatch(profile_id, text, msg_id or str(uuid.uuid4()))
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
