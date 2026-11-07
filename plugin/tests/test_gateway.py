import asyncio
import json
import uuid

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from lekora.gateway import Gateway

PROFILES = [
    {"profile_id": "assistant", "name": "Hermes Assistant", "avatar": "sparkles"},
    {"profile_id": "coder", "name": "Coder", "avatar": "terminal"},
]


@pytest.fixture
async def gw(store):
    holder = {}

    async def dispatch(profile_id, text, message_id):
        if text == "Ping":
            await holder["gw"].publish_message(profile_id, "Pong from Hermes")
        elif text == "Boom":
            raise RuntimeError("agent down")

    g = Gateway(store, dispatch, lambda: PROFILES,
                endpoints=lambda p: [f"ws://127.0.0.1:{p}"],
                host="127.0.0.1", auth_timeout=0.4)
    holder["gw"] = g
    await g.start()
    yield g
    await g.stop()


def env(store, type_, data, profile_id=None, msg_id=None):
    e = {"v": 1, "id": msg_id or str(uuid.uuid4()), "type": type_,
         "instance_id": store.instance_id, "ts": "2026-11-07T12:00:00Z", "data": data}
    if profile_id:
        e["profile_id"] = profile_id
    return json.dumps(e)


async def open_ws(gw):
    return await connect(f"ws://127.0.0.1:{gw.port}")


async def recv(ws, timeout=2):
    return json.loads(await asyncio.wait_for(ws.recv(), timeout))


async def pair(gw, store):
    token = store.create_invite()
    ws = await open_ws(gw)
    await ws.send(env(store, "pair.request", {
        "pairing_token": token, "device_name": "iPhone",
        "client_version": "1.0.0", "supported_proto_versions": [1]}, msg_id="p1"))
    resp = await recv(ws)
    return ws, resp


async def hello(gw, store, device_id, device_token, last_seq=0):
    ws = await open_ws(gw)
    await ws.send(env(store, "hello", {
        "device_id": device_id, "device_token": device_token,
        "last_seq": last_seq, "client_version": "1.0.0", "proto_version": 1},
        msg_id="h1"))
    return ws


async def test_pair_flow(gw, store):
    ws, resp = await pair(gw, store)
    assert resp["type"] == "pair.response" and resp["id"] == "p1"
    d = resp["data"]
    assert d["status"] == "ok" and d["proto_version"] == 1
    assert d["device_id"].startswith("dev_") and d["device_token"]
    assert d["endpoints"] == [f"ws://127.0.0.1:{gw.port}"]
    assert store.verify_device_token(d["device_id"], d["device_token"])
    await ws.close()


async def test_pair_socket_can_continue_with_hello(gw, store):
    """The iOS client sends hello on the same socket right after pairing."""
    ws, resp = await pair(gw, store)
    d = resp["data"]
    await ws.send(env(store, "hello", {
        "device_id": d["device_id"], "device_token": d["device_token"],
        "last_seq": 0, "client_version": "1.0.0", "proto_version": 1}, msg_id="h1"))
    ack = await recv(ws)
    assert ack["type"] == "hello.ack" and ack["data"]["profiles"] == PROFILES
    await ws.close()


async def test_invite_cannot_be_reused(gw, store):
    token = store.create_invite()
    for expected in ("pair.response", "error"):
        ws = await open_ws(gw)
        await ws.send(env(store, "pair.request", {
            "pairing_token": token, "device_name": "x",
            "client_version": "1", "supported_proto_versions": [1]}))
        r = await recv(ws)
        assert r["type"] == expected
        if expected == "error":
            assert r["data"]["code"] == "TOKEN_INVALID"
        await ws.close()


async def test_expired_invite(gw, store, clock):
    token = store.create_invite()
    clock.advance(minutes=31)
    ws = await open_ws(gw)
    await ws.send(env(store, "pair.request", {
        "pairing_token": token, "supported_proto_versions": [1]}))
    r = await recv(ws)
    assert r["data"]["code"] == "TOKEN_EXPIRED"
    with pytest.raises(ConnectionClosed):
        await ws.recv()


async def test_incompatible_pair_version(gw, store):
    token = store.create_invite()
    ws = await open_ws(gw)
    await ws.send(env(store, "pair.request", {
        "pairing_token": token, "supported_proto_versions": [2]}))
    assert (await recv(ws))["data"]["code"] == "INCOMPATIBLE_VERSION"
    # token must not be burned by a version mismatch
    store.consume_invite(token)


async def test_hello_and_replay(gw, store):
    device_id, tok = store.register_device("iPhone", "1")
    for i in range(3):
        store.append_event("assistant", "chat.message", {"role": "assistant", "text": f"m{i}"})
    ws = await hello(gw, store, device_id, tok, last_seq=1)
    ack = await recv(ws)
    assert ack["type"] == "hello.ack"
    assert ack["data"]["current_seq"] == 3 and ack["id"] == "h1"
    replayed = [await recv(ws), await recv(ws)]
    assert [m["data"]["seq"] for m in replayed] == [2, 3]
    assert [m["data"]["text"] for m in replayed] == ["m1", "m2"]
    assert all(m["type"] == "chat.message" and m["profile_id"] == "assistant" for m in replayed)
    await ws.close()


async def test_bad_and_revoked_token_rejected(gw, store):
    device_id, tok = store.register_device()
    ws = await hello(gw, store, device_id, tok + "x")
    assert (await recv(ws))["data"]["code"] == "AUTH_FAILED"
    with pytest.raises(ConnectionClosed):
        await ws.recv()
    store.revoke_device(device_id)
    ws = await hello(gw, store, device_id, tok)
    assert (await recv(ws))["data"]["code"] == "AUTH_FAILED"


async def test_ping_pong(gw, store):
    device_id, tok = store.register_device()
    ws = await hello(gw, store, device_id, tok)
    await recv(ws)  # hello.ack
    await ws.send(env(store, "chat.send", {"text": "Ping"}, profile_id="assistant"))
    msg = await recv(ws)
    assert msg["type"] == "chat.message" and msg["profile_id"] == "assistant"
    assert msg["data"]["text"] == "Pong from Hermes"
    assert msg["data"]["role"] == "assistant"
    assert msg["data"]["seq"] == 2  # seq 1 is the stored "Ping"
    events = store.fetch_events_since(0)
    assert [(e.seq, e.payload["role"], e.payload["text"]) for e in events] == [
        (1, "user", "Ping"), (2, "assistant", "Pong from Hermes")]
    await ws.close()


async def test_chat_goes_to_other_devices_too(gw, store):
    a_id, a_tok = store.register_device("a")
    b_id, b_tok = store.register_device("b")
    a = await hello(gw, store, a_id, a_tok)
    b = await hello(gw, store, b_id, b_tok)
    await recv(a); await recv(b)
    await a.send(env(store, "chat.send", {"text": "Ping"}, profile_id="coder"))
    got_b = [await recv(b), await recv(b)]
    assert [m["data"]["role"] for m in got_b] == ["user", "assistant"]
    got_a = await recv(a)
    assert got_a["data"]["role"] == "assistant"  # sender is not echoed its own text
    await a.close(); await b.close()


async def test_duplicate_chat_id_is_ignored(gw, store):
    device_id, tok = store.register_device()
    ws = await hello(gw, store, device_id, tok)
    await recv(ws)
    for _ in range(2):
        await ws.send(env(store, "chat.send", {"text": "Ping"},
                          profile_id="assistant", msg_id="same"))
    await recv(ws)
    await asyncio.sleep(0.2)
    assert len(store.fetch_events_since(0)) == 2


async def test_unknown_profile_and_empty_text(gw, store):
    device_id, tok = store.register_device()
    ws = await hello(gw, store, device_id, tok)
    await recv(ws)
    await ws.send(env(store, "chat.send", {"text": "hi"}, profile_id="main"))
    assert (await recv(ws))["data"]["code"] == "UNKNOWN_PROFILE"
    await ws.send(env(store, "chat.send", {"text": "  "}, profile_id="assistant"))
    assert (await recv(ws))["data"]["code"] == "INVALID_MESSAGE"
    await ws.send(env(store, "chat.send", {"text": "Ping"}, profile_id="assistant"))
    assert (await recv(ws))["data"]["text"] == "Pong from Hermes"  # still usable
    await ws.close()


async def test_agent_failure_reports_error(gw, store):
    device_id, tok = store.register_device()
    ws = await hello(gw, store, device_id, tok)
    await recv(ws)
    await ws.send(env(store, "chat.send", {"text": "Boom"}, profile_id="assistant"))
    err = await recv(ws)
    assert err["data"]["code"] == "AGENT_ERROR" and err["data"]["recoverable"] is True
    await ws.close()


async def test_chat_before_auth_rejected(gw, store):
    ws = await open_ws(gw)
    await ws.send(env(store, "chat.send", {"text": "Ping"}, profile_id="assistant"))
    assert (await recv(ws))["data"]["code"] == "AUTH_FAILED"
    with pytest.raises(ConnectionClosed):
        await ws.recv()
    assert store.fetch_events_since(0) == []


async def test_unauthenticated_connection_times_out(gw):
    ws = await open_ws(gw)
    with pytest.raises(ConnectionClosed) as exc:
        await asyncio.wait_for(ws.recv(), 3)
    assert exc.value.rcvd.code == 1008


async def test_garbage_and_wrong_instance(gw, store):
    ws = await open_ws(gw)
    await ws.send("not json")
    assert (await recv(ws))["data"]["code"] == "INVALID_MESSAGE"
    ws = await open_ws(gw)
    bad = json.loads(env(store, "hello", {}))
    bad["instance_id"] = "inst_other"
    await ws.send(json.dumps(bad))
    assert (await recv(ws))["data"]["code"] == "INVALID_MESSAGE"


async def test_port_persisted_and_reused_after_restart(store):
    async def noop(*a): ...
    g1 = Gateway(store, noop, lambda: PROFILES, host="127.0.0.1")
    port = await g1.start()
    assert store.get_persisted_port() == port
    await g1.stop()
    g2 = Gateway(store, noop, lambda: PROFILES, host="127.0.0.1")
    assert await g2.start() == port
    await g2.stop()


async def test_busy_saved_port_falls_back_and_updates(store):
    async def noop(*a): ...
    blocker = Gateway(store.__class__(":memory:"), noop, lambda: PROFILES, host="127.0.0.1")
    busy = await blocker.start()
    store.set_persisted_port(busy)
    g = Gateway(store, noop, lambda: PROFILES, host="127.0.0.1")
    port = await g.start()
    assert port != busy and store.get_persisted_port() == port
    await g.stop(); await blocker.stop()
