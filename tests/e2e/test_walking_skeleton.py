"""End-to-end walking skeleton against a mock Hermes agent.

Plays the part of the phone exactly as the iOS app does: parse the invite link
printed by `hermes lekora pair`, pair, say hello, send "Ping", expect
"Pong from Hermes", then survive a host restart.

Run:  plugin/.venv/bin/pytest tests/e2e -c plugin/pytest.ini
"""

import asyncio
import io
import json
import re
import uuid
from urllib.parse import parse_qs, urlparse

import pytest
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

from lekora.pairing import run_pair
from lekora.plugin import LekoraConfig, LekoraService

pytestmark = pytest.mark.asyncio


class MockHermesAgent:
    """Stands in for a Hermes agent profile."""

    def __init__(self):
        self.service = None
        self.seen = []

    async def deliver_to_agent(self, profile_id, text, message_id):
        self.seen.append((profile_id, text))
        reply = "Pong from Hermes" if text == "Ping" else f"You said: {text}"
        await self.service.handle_agent_reply(profile_id, reply)


def envelope(instance_id, type_, data, profile_id=None):
    e = {"v": 1, "id": str(uuid.uuid4()), "type": type_, "instance_id": instance_id,
         "ts": "2026-11-07T12:00:00Z", "data": data}
    if profile_id:
        e["profile_id"] = profile_id
    return json.dumps(e)


async def recv(ws, timeout=3):
    return json.loads(await asyncio.wait_for(ws.recv(), timeout))


async def start(db_path):
    agent = MockHermesAgent()
    cfg = LekoraConfig(db_path=str(db_path), listen_host="127.0.0.1",
                       instance_name="Test Host", extra_hosts=["127.0.0.1"])
    svc = LekoraService(agent, cfg, hermes_version="0.22.5")
    agent.service = svc
    await svc.start()
    return svc, agent


def read_invite_like_the_app(printed: str):
    uri = re.search(r"lekora-pair://\S+", printed).group(0)
    q = parse_qs(urlparse(uri).query)  # same decoding as URLComponents.queryItems
    return q["token"][0], q["instance_id"][0], q["endpoints"][0].split(",")


async def login(url, instance_id, creds, last_seq):
    ws = await connect(url)
    await ws.send(envelope(instance_id, "hello", {
        "device_id": creds["device_id"], "device_token": creds["device_token"],
        "last_seq": last_seq, "client_version": "1.0.0", "proto_version": 1}))
    return ws, await recv(ws)


async def test_pair_ping_pong_restart_and_catchup(tmp_path):
    db = tmp_path / "lekora.db"
    svc, agent = await start(db)
    port = svc.gateway.port
    try:
        # 1. `hermes lekora pair`
        printed = io.StringIO()
        assert run_pair(svc.store, printed, extra_hosts=["127.0.0.1"],
                        listening=lambda p: True) == 0
        token, instance_id, endpoints = read_invite_like_the_app(printed.getvalue())
        assert instance_id == svc.store.instance_id
        url = next(e for e in endpoints if "127.0.0.1" in e)
        assert url == f"ws://127.0.0.1:{port}"

        # 2. phone pairs
        ws = await connect(url)
        await ws.send(envelope(instance_id, "pair.request", {
            "pairing_token": token, "device_name": "Test iPhone",
            "client_version": "1.0.0", "supported_proto_versions": [1]}))
        pair = await recv(ws)
        assert pair["type"] == "pair.response" and pair["data"]["status"] == "ok"
        creds = pair["data"]
        assert url in creds["endpoints"]

        # 3. handshake on the same socket, as the app does
        await ws.send(envelope(instance_id, "hello", {
            "device_id": creds["device_id"], "device_token": creds["device_token"],
            "last_seq": 0, "client_version": "1.0.0", "proto_version": 1}))
        ack = await recv(ws)
        assert ack["type"] == "hello.ack" and ack["data"]["current_seq"] == 0
        assert [p["profile_id"] for p in ack["data"]["profiles"]] == ["assistant"]

        # 4. Ping -> Pong from Hermes
        await ws.send(envelope(instance_id, "chat.send", {"text": "Ping"}, "assistant"))
        pong = await recv(ws)
        assert pong["type"] == "chat.message" and pong["profile_id"] == "assistant"
        assert pong["data"]["text"] == "Pong from Hermes" and pong["data"]["role"] == "assistant"
        assert agent.seen == [("assistant", "Ping")]
        await ws.close()

        # 5. recorded with consecutive sequence numbers
        events = svc.store.fetch_events_since(0)
        assert [e.seq for e in events] == [1, 2]
        assert [e.payload["text"] for e in events] == ["Ping", "Pong from Hermes"]
        assert all(e.instance_id == instance_id and e.profile_id == "assistant" for e in events)
        assert pong["data"]["seq"] == 2

        # 6. the invite is single use
        ws2 = await connect(url)
        await ws2.send(envelope(instance_id, "pair.request", {
            "pairing_token": token, "device_name": "Other", "supported_proto_versions": [1]}))
        assert (await recv(ws2))["data"]["code"] == "TOKEN_INVALID"
    finally:
        await svc.stop()

    # 7. host restart: same port, same identity, no re-pairing
    svc2, agent2 = await start(db)
    try:
        assert svc2.gateway.port == port
        assert svc2.store.instance_id == instance_id

        # phone that saw nothing yet catches up on everything
        ws, ack = await login(url, instance_id, creds, last_seq=0)
        assert ack["type"] == "hello.ack" and ack["data"]["current_seq"] == 2
        replay = [await recv(ws), await recv(ws)]
        assert [m["data"]["seq"] for m in replay] == [1, 2]
        assert replay[1]["data"]["text"] == "Pong from Hermes"
        await ws.close()

        # phone that was up to date gets nothing replayed, and keeps chatting
        ws, ack = await login(url, instance_id, creds, last_seq=2)
        await ws.send(envelope(instance_id, "chat.send", {"text": "Ping"}, "assistant"))
        again = await recv(ws)
        assert again["data"]["seq"] == 4 and again["data"]["text"] == "Pong from Hermes"
        await ws.close()

        # a wrong credential is refused
        bad = dict(creds, device_token=creds["device_token"] + "x")
        ws, err = await login(url, instance_id, bad, last_seq=0)
        assert err["type"] == "error" and err["data"]["code"] == "AUTH_FAILED"
        with pytest.raises(ConnectionClosed):
            await ws.recv()
    finally:
        await svc2.stop()
