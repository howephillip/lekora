import asyncio
import base64
import os
import struct

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from lekora import ws


async def echo(conn):
    try:
        while True:
            await conn.send(await conn.recv())
    except ws.ConnectionClosed:
        pass


@pytest.fixture
async def server():
    s = await ws.serve(echo, "127.0.0.1", 0, ping_interval=None)
    yield s, s.sockets[0].getsockname()[1]
    s.close()
    await s.wait_closed()


def masked(opcode, payload, fin=True, mask=True):
    b1 = (0x80 if fin else 0) | opcode
    n = len(payload)
    head = bytes([b1, (0x80 if mask else 0) | n]) if n < 126 else bytes([b1, (0x80 if mask else 0) | 126]) + struct.pack(">H", n)
    if not mask:
        return head + payload
    key = os.urandom(4)
    return head + key + bytes(b ^ key[i & 3] for i, b in enumerate(payload))


async def raw_connect(port, extra_headers=""):
    r, w = await asyncio.open_connection("127.0.0.1", port)
    key = base64.b64encode(os.urandom(16)).decode()
    w.write((f"GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
             f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{extra_headers}\r\n").encode())
    head = await r.readuntil(b"\r\n\r\n")
    return r, w, head


async def read_frame(r):
    b1, b2 = await r.readexactly(2)
    n = b2 & 0x7F
    if n == 126:
        (n,) = struct.unpack(">H", await r.readexactly(2))
    return b1 & 0x0F, await r.readexactly(n)


async def test_interop_text_binary_and_large(server):
    _, port = server
    async with connect(f"ws://127.0.0.1:{port}") as c:
        await c.send("héllo ✓")
        assert await c.recv() == "héllo ✓"
        await c.send(b"\x00\x01")
        assert await c.recv() == b"\x00\x01"
        big = "x" * 70000  # uses 64-bit length frames + client fragmentation of nothing
        await c.send(big)
        assert await c.recv() == big
        await c.ping()  # server answers with pong (library awaits it)


async def test_accept_key_matches_rfc_example():
    assert ws._accept_key("dGhlIHNhbXBsZSBub25jZQ==") == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="


async def test_fragmented_message_reassembled(server):
    _, port = server
    r, w, head = await raw_connect(port)
    assert b"101 Switching Protocols" in head
    w.write(masked(ws.OP_TEXT, b"Hel", fin=False) + masked(ws.OP_PING, b"p") + masked(ws.OP_CONT, b"lo"))
    op, data = await read_frame(r)
    assert (op, data) == (ws.OP_PONG, b"p")
    op, data = await read_frame(r)
    assert (op, data) == (ws.OP_TEXT, b"Hello")
    w.close()


@pytest.mark.parametrize("frame,code", [
    (masked(ws.OP_TEXT, b"hi", mask=False), 1002),          # unmasked client frame
    (masked(ws.OP_TEXT, b"\xff\xfe"), 1007),                # invalid UTF-8
    (masked(ws.OP_CONT, b"x"), 1002),                       # continuation with nothing before
    (masked(0x3, b"x"), 1002),                              # unknown opcode
    (masked(ws.OP_PING, b"x", fin=False), 1002),            # fragmented control frame
])
async def test_protocol_violations_close_with_code(server, frame, code):
    _, port = server
    r, w, _ = await raw_connect(port)
    w.write(frame)
    op, data = await asyncio.wait_for(read_frame(r), 2)
    assert op == ws.OP_CLOSE and struct.unpack(">H", data[:2])[0] == code
    w.close()


async def test_oversized_message_rejected():
    s = await ws.serve(echo, "127.0.0.1", 0, ping_interval=None)
    port = s.sockets[0].getsockname()[1]
    try:
        c = await connect(f"ws://127.0.0.1:{port}", max_size=None)
        with pytest.raises(ConnectionClosed) as e:
            await c.send("x" * (ws.MAX_MESSAGE_BYTES + 1))
            await asyncio.wait_for(c.recv(), 3)
        assert e.value.rcvd is not None and e.value.rcvd.code == 1009
    finally:
        s.close()
        await s.wait_closed()


async def test_browser_origin_rejected(server):
    _, port = server
    r, w, head = await raw_connect(port, "Origin: http://evil.example\r\n")
    assert b"403" in head.split(b"\r\n")[0]
    w.close()


async def test_plain_http_gets_426(server):
    _, port = server
    r, w = await asyncio.open_connection("127.0.0.1", port)
    w.write(b"GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    assert b"426" in (await r.readuntil(b"\r\n\r\n")).split(b"\r\n")[0]
    w.close()


async def test_stalled_handshake_dropped(monkeypatch):
    monkeypatch.setattr(ws, "HANDSHAKE_TIMEOUT", 0.2)
    s = await ws.serve(echo, "127.0.0.1", 0, ping_interval=None)
    port = s.sockets[0].getsockname()[1]
    try:
        r, w = await asyncio.open_connection("127.0.0.1", port)
        w.write(b"GET / HT")  # never finishes
        assert await asyncio.wait_for(r.read(), 2) == b""  # server closed it
    finally:
        s.close()
        await s.wait_closed()


async def test_heartbeat_closes_silent_client():
    s = await ws.serve(echo, "127.0.0.1", 0, ping_interval=0.1, ping_timeout=0.2)
    port = s.sockets[0].getsockname()[1]
    try:
        r, w, _ = await raw_connect(port)  # raw client never answers pings
        op, _ = await asyncio.wait_for(read_frame(r), 2)
        assert op == ws.OP_PING
        while True:
            op, data = await asyncio.wait_for(read_frame(r), 2)
            if op == ws.OP_CLOSE:
                assert struct.unpack(">H", data[:2])[0] == 1011
                break
    finally:
        s.close()
        await s.wait_closed()


async def test_server_shutdown_closes_clients(server):
    s, port = server
    c = await connect(f"ws://127.0.0.1:{port}")
    s.close()
    await asyncio.wait_for(s.wait_closed(), 3)
    with pytest.raises(Exception):
        await asyncio.wait_for(c.recv(), 2)
