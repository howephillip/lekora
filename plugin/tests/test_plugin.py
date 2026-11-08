import asyncio
import json
import uuid

import pytest
from websockets.asyncio.client import connect

from lekora import plugin
from lekora.plugin import (LekoraConfig, LekoraService, UnsupportedHermesVersion,
                           check_hermes_version)


class FakeHermes:
    """Stands in for Hermes: answers 'Ping' with 'Pong from Hermes'."""

    def __init__(self):
        self.service = None
        self.received = []

    async def deliver_to_agent(self, profile_id, text, message_id):
        self.received.append((profile_id, text, message_id))
        if text == "Ping":
            await self.service.handle_agent_reply(profile_id, "Pong from Hermes")


def env(store, type_, data, profile_id=None):
    e = {"v": 1, "id": str(uuid.uuid4()), "type": type_, "instance_id": store.instance_id,
         "ts": "2026-11-07T12:00:00Z", "data": data}
    if profile_id:
        e["profile_id"] = profile_id
    return json.dumps(e)


@pytest.mark.parametrize("v", ["0.22.0", "0.22.5", "0.30.1", "v0.23", "0.99.9"])
def test_supported_versions(v):
    check_hermes_version(v)


@pytest.mark.parametrize("v", ["0.21.9", "1.0.0", "2.3", "0.0.0", "banana", "", None])
def test_unsupported_versions_give_plain_message(v):
    with pytest.raises(UnsupportedHermesVersion) as e:
        check_hermes_version(v)
    assert "Lekora has not started" in str(e.value)


def test_config_defaults_and_overrides():
    d = LekoraConfig.from_extra(None)
    assert d.listen_host == "0.0.0.0" and d.profiles is None  # None: discover real profiles
    assert [p["profile_id"] for p in d.current_profiles()] == ["default"]
    c = LekoraConfig.from_extra({
        "db_path": "/x/y.db", "extra_hosts": ["h.example.com"], "instance_name": "Home",
        "profiles": [{"profile_id": "coder", "name": "Coder"}, {"profile_id": "assistant"}]})
    assert c.db_path == "/x/y.db" and c.extra_hosts == ["h.example.com"]
    assert [p["profile_id"] for p in c.profiles] == ["coder", "assistant"]
    assert c.profiles[1]["name"] == "assistant"


async def test_unsupported_hermes_halts_before_any_side_effects(tmp_path):
    db = tmp_path / "lekora.db"
    svc = LekoraService(FakeHermes(), LekoraConfig(db_path=str(db)), hermes_version="0.1.0")
    with pytest.raises(UnsupportedHermesVersion):
        await svc.start()
    assert not db.exists() and svc.gateway is None


async def test_end_to_end_through_service(tmp_path):
    hermes = FakeHermes()
    cfg = LekoraConfig(db_path=str(tmp_path / "lekora.db"), listen_host="127.0.0.1",
                       instance_name="Home Server",
                       profiles=[{"profile_id": "coder", "name": "Coder", "avatar": "terminal"}])
    svc = LekoraService(hermes, cfg, hermes_version="0.22.5", auth_timeout=1)
    hermes.service = svc
    port = await svc.start()
    try:
        token = svc.store.create_invite()
        ws = await connect(f"ws://127.0.0.1:{port}")
        await ws.send(env(svc.store, "pair.request", {
            "pairing_token": token, "device_name": "iPhone",
            "client_version": "1", "supported_proto_versions": [1]}))
        pr = json.loads(await ws.recv())
        assert pr["data"]["instance_name"] == "Home Server"
        assert f":{port}" in pr["data"]["endpoints"][0] or pr["data"]["endpoints"] == []
        await ws.send(env(svc.store, "hello", {
            "device_id": pr["data"]["device_id"],
            "device_token": pr["data"]["device_token"], "last_seq": 0, "proto_version": 1}))
        ack = json.loads(await ws.recv())
        assert ack["data"]["profiles"] == cfg.profiles
        await ws.send(env(svc.store, "chat.send", {"text": "Ping"}, profile_id="coder"))
        msg = json.loads(await asyncio.wait_for(ws.recv(), 2))
        assert msg["data"]["text"] == "Pong from Hermes" and msg["profile_id"] == "coder"
        assert hermes.received[0][:2] == ("coder", "Ping")
        await ws.close()
    finally:
        await svc.stop()
    assert svc.gateway is None


async def test_reply_before_start_is_an_error():
    svc = LekoraService(FakeHermes(), check_version=False)
    with pytest.raises(RuntimeError):
        await svc.handle_agent_reply("assistant", "hi")


async def test_restart_keeps_identity_and_port(tmp_path):
    cfg = LekoraConfig(db_path=str(tmp_path / "lekora.db"), listen_host="127.0.0.1")
    a = LekoraService(FakeHermes(), cfg, check_version=False)
    port = await a.start()
    inst = a.store.instance_id
    await a.stop()
    b = LekoraService(FakeHermes(), cfg, check_version=False)
    assert await b.start() == port and b.store.instance_id == inst
    await b.stop()
