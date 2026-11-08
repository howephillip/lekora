"""Minimal RFC 6455 WebSocket server on asyncio, standard library only.

Why: the plugin runs inside Hermes's own Python environment, where we cannot
assume third-party packages. This implements just what Lekora needs: the
opening handshake, text/binary messages (with fragmentation), ping/pong,
close, a size limit and a server-side heartbeat.
"""

from __future__ import annotations

import asyncio
import ssl as _ssl
import base64
import contextlib
import hashlib
import logging
import struct
from typing import Awaitable, Callable, Optional, Union

log = logging.getLogger(__name__)

_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
MAX_MESSAGE_BYTES = 1 << 20
MAX_HEADER_BYTES = 8192
HANDSHAKE_TIMEOUT = 5.0

OP_CONT, OP_TEXT, OP_BINARY, OP_CLOSE, OP_PING, OP_PONG = 0x0, 0x1, 0x2, 0x8, 0x9, 0xA


class ConnectionClosed(Exception):
    def __init__(self, code: int = 1006, reason: str = "") -> None:
        super().__init__(f"connection closed ({code}) {reason}".strip())
        self.code, self.reason = code, reason


class _ProtocolError(Exception):
    def __init__(self, code: int, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


def _accept_key(key: str) -> str:
    return base64.b64encode(hashlib.sha1(key.encode("ascii") + _GUID).digest()).decode("ascii")


class ServerConnection:
    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                 ping_interval: Optional[float], ping_timeout: float,
                 max_size: int = MAX_MESSAGE_BYTES) -> None:
        self._r, self._w = reader, writer
        self._max = max_size
        self._send_lock = asyncio.Lock()
        self._inbox: asyncio.Queue = asyncio.Queue()
        self._closed: Optional[ConnectionClosed] = None
        self._close_sent = False
        self._pong = asyncio.Event()
        self.remote_address = writer.get_extra_info("peername")
        self._tasks = [asyncio.create_task(self._read_loop())]
        if ping_interval:
            self._tasks.append(asyncio.create_task(self._heartbeat(ping_interval, ping_timeout)))

    # ---- public API --------------------------------------------------------

    async def recv(self) -> Union[str, bytes]:
        item = await self._inbox.get()
        if isinstance(item, ConnectionClosed):
            self._inbox.put_nowait(item)  # later calls keep raising
            raise item
        return item

    async def send(self, data: Union[str, bytes]) -> None:
        if self._closed or self._close_sent:
            raise self._closed or ConnectionClosed(1006)
        if isinstance(data, str):
            await self._write_frame(OP_TEXT, data.encode("utf-8"))
        else:
            await self._write_frame(OP_BINARY, bytes(data))

    async def close(self, code: int = 1000, reason: str = "") -> None:
        if not self._close_sent:
            self._close_sent = True
            with contextlib.suppress(Exception):
                await self._write_frame(
                    OP_CLOSE, struct.pack(">H", code) + reason.encode("utf-8")[:120], force=True)
        await self._finish(ConnectionClosed(code, reason))

    # ---- internals ---------------------------------------------------------

    async def _reject(self, code: int, reason: str) -> None:
        """Close after a protocol error, without losing the close frame.

        The error is often found mid-message (e.g. a too-big header), with the rest still
        arriving. Closing a socket that has unread data makes the OS send a reset, which can
        destroy the close frame in flight, so the peer would see 1006 instead of the real code.
        So: send the close frame, discard what the peer is still sending (bounded in time and
        size), then close."""
        if not self._close_sent:
            self._close_sent = True
            with contextlib.suppress(Exception):
                await self._write_frame(
                    OP_CLOSE, struct.pack(">H", code) + reason.encode("utf-8")[:120], force=True)
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self._discard_incoming(4 * self._max), 1.0)
        await self._finish(ConnectionClosed(code, reason))

    async def _discard_incoming(self, limit: int) -> None:
        total = 0
        while total < limit:
            chunk = await self._r.read(65536)
            if not chunk:
                return
            total += len(chunk)

    async def _write_frame(self, opcode: int, payload: bytes, force: bool = False) -> None:
        n = len(payload)
        if n < 126:
            header = struct.pack(">BB", 0x80 | opcode, n)
        elif n < 1 << 16:
            header = struct.pack(">BBH", 0x80 | opcode, 126, n)
        else:
            header = struct.pack(">BBQ", 0x80 | opcode, 127, n)
        async with self._send_lock:
            if self._w.is_closing():
                raise self._closed or ConnectionClosed(1006)
            try:
                self._w.write(header + payload)
                await self._w.drain()
            except (ConnectionError, OSError) as exc:
                raise ConnectionClosed(1006, str(exc)) from exc

    async def _finish(self, exc: ConnectionClosed) -> None:
        if self._closed is None:
            self._closed = exc
            self._inbox.put_nowait(exc)
        current = asyncio.current_task()
        for t in self._tasks:
            if t is not current:
                t.cancel()
        if not self._w.is_closing():
            with contextlib.suppress(Exception):
                self._w.close()
        with contextlib.suppress(Exception):
            await asyncio.wait_for(self._w.wait_closed(), 2)

    async def _read_frame(self) -> tuple[bool, int, bytes]:
        b1, b2 = await self._r.readexactly(2)
        fin, rsv, opcode = bool(b1 & 0x80), b1 & 0x70, b1 & 0x0F
        if rsv:
            raise _ProtocolError(1002, "reserved bits set")
        if not b2 & 0x80:
            raise _ProtocolError(1002, "client frames must be masked")
        n = b2 & 0x7F
        if n == 126:
            (n,) = struct.unpack(">H", await self._r.readexactly(2))
        elif n == 127:
            (n,) = struct.unpack(">Q", await self._r.readexactly(8))
        if opcode >= 0x8 and (n > 125 or not fin):
            raise _ProtocolError(1002, "bad control frame")
        if n > self._max:
            raise _ProtocolError(1009, "message too big")
        mask = await self._r.readexactly(4)
        data = bytearray(await self._r.readexactly(n))
        for i in range(n):
            data[i] ^= mask[i & 3]
        return fin, opcode, bytes(data)

    async def _read_loop(self) -> None:
        parts: list[bytes] = []
        msg_op: Optional[int] = None
        size = 0
        try:
            while True:
                fin, op, data = await self._read_frame()
                if op == OP_PING:
                    with contextlib.suppress(ConnectionClosed):
                        await self._write_frame(OP_PONG, data)
                elif op == OP_PONG:
                    self._pong.set()
                elif op == OP_CLOSE:
                    code = struct.unpack(">H", data[:2])[0] if len(data) >= 2 else 1005
                    reason = data[2:].decode("utf-8", "replace")
                    if not self._close_sent:
                        self._close_sent = True
                        with contextlib.suppress(Exception):
                            await self._write_frame(OP_CLOSE, data[:2], force=True)
                    await self._finish(ConnectionClosed(code, reason))
                    return
                elif op in (OP_TEXT, OP_BINARY, OP_CONT):
                    if op == OP_CONT:
                        if msg_op is None:
                            raise _ProtocolError(1002, "unexpected continuation")
                    else:
                        if msg_op is not None:
                            raise _ProtocolError(1002, "expected continuation")
                        msg_op = op
                    parts.append(data)
                    size += len(data)
                    if size > self._max:
                        raise _ProtocolError(1009, "message too big")
                    if fin:
                        payload = b"".join(parts)
                        if msg_op == OP_TEXT:
                            try:
                                self._inbox.put_nowait(payload.decode("utf-8"))
                            except UnicodeDecodeError:
                                raise _ProtocolError(1007, "invalid UTF-8")
                        else:
                            self._inbox.put_nowait(payload)
                        parts, msg_op, size = [], None, 0
                else:
                    raise _ProtocolError(1002, "unknown opcode")
        except _ProtocolError as err:
            await self._reject(err.code, err.reason)
        except (asyncio.IncompleteReadError, ConnectionError, OSError):
            await self._finish(ConnectionClosed(1006, "connection lost"))
        except asyncio.CancelledError:
            raise

    async def _heartbeat(self, interval: float, timeout: float) -> None:
        try:
            while True:
                await asyncio.sleep(interval)
                self._pong.clear()
                await self._write_frame(OP_PING, b"")
                try:
                    await asyncio.wait_for(self._pong.wait(), timeout)
                except asyncio.TimeoutError:
                    await self.close(1011, "keepalive ping timeout")
                    return
        except (ConnectionClosed, asyncio.CancelledError):
            pass


Handler = Callable[[ServerConnection], Awaitable[None]]


class WSServer:
    def __init__(self, server: asyncio.AbstractServer) -> None:
        self._server = server
        self._conns: set[ServerConnection] = set()

    @property
    def sockets(self):
        return self._server.sockets

    def close(self) -> None:
        self._server.close()

    async def wait_closed(self) -> None:
        for c in list(self._conns):
            with contextlib.suppress(Exception):
                await c.close(1001, "server shutting down")
        await self._server.wait_closed()


async def _handshake(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> bool:
    def reply(status: str, extra: str = "") -> None:
        writer.write(f"HTTP/1.1 {status}\r\nConnection: close\r\nContent-Length: 0\r\n{extra}\r\n"
                     .encode("ascii"))

    try:
        raw = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), HANDSHAKE_TIMEOUT)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
        return False
    if len(raw) > MAX_HEADER_BYTES:
        reply("431 Request Header Fields Too Large")
        return False
    lines = raw.decode("latin1").split("\r\n")
    request = lines[0].split(" ")
    headers = {}
    for line in lines[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            headers[k.strip().lower()] = v.strip()
    if len(request) != 3 or request[0] != "GET":
        reply("400 Bad Request")
        return False
    if (headers.get("upgrade", "").lower() != "websocket"
            or "upgrade" not in headers.get("connection", "").lower()
            or not headers.get("sec-websocket-key")):
        reply("426 Upgrade Required", "Upgrade: websocket\r\n")
        return False
    if headers.get("sec-websocket-version") != "13":
        reply("426 Upgrade Required", "Sec-WebSocket-Version: 13\r\n")
        return False
    if "origin" in headers:  # browsers always send Origin; the native app never does
        reply("403 Forbidden")
        return False
    writer.write(
        ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
         f"Sec-WebSocket-Accept: {_accept_key(headers['sec-websocket-key'])}\r\n\r\n").encode("ascii"))
    await writer.drain()
    return True


async def serve(handler: Handler, host: str, port: int,
                ping_interval: Optional[float] = 30.0, ping_timeout: float = 20.0,
                ssl: Optional["_ssl.SSLContext"] = None) -> WSServer:
    """``ssl``: serve wss:// (TLS) instead of plain ws://."""
    holder: dict = {}

    async def on_client(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        conn: Optional[ServerConnection] = None
        try:
            if not await _handshake(reader, writer):
                with contextlib.suppress(Exception):
                    await writer.drain()
                return
            conn = ServerConnection(reader, writer, ping_interval, ping_timeout)
            holder["srv"]._conns.add(conn)
            await handler(conn)
        except asyncio.CancelledError:
            raise
        except Exception:
            log.exception("WebSocket handler failed")
        finally:
            if conn is not None:
                holder["srv"]._conns.discard(conn)
                with contextlib.suppress(Exception):
                    await conn.close(1000 if conn._closed is None else conn._closed.code)
            elif not writer.is_closing():
                writer.close()

    server = await asyncio.start_server(on_client, host, port, limit=MAX_HEADER_BYTES * 2, ssl=ssl)
    holder["srv"] = WSServer(server)
    return holder["srv"]
