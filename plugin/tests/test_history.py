"""Chat history and read state (docs/chat-history.md)."""

import asyncio
import json
import sqlite3

import pytest
from websockets.exceptions import ConnectionClosed

from lekora import gateway as gateway_mod
from lekora.store import Store
from tests.test_gateway import PROFILES, env, gw, hello, recv, open_ws  # noqa: F401  (gw fixture)


def msg(store, profile, text, role="assistant"):
    return store.append_event(profile, "chat.message", {"role": role, "text": text})


async def hello_rev(gw, store, device_id, tok, since_rev, last_seq=0):
    ws = await open_ws(gw)
    await ws.send(env(store, "hello", {
        "device_id": device_id, "device_token": tok, "last_seq": last_seq,
        "since_rev": since_rev, "client_version": "1.0.0", "proto_version": 1}, msg_id="h1"))
    return ws


async def drain(ws, timeout=0.3):
    out = []
    while True:
        try:
            out.append(json.loads(await asyncio.wait_for(ws.recv(), timeout)))
        except (asyncio.TimeoutError, ConnectionClosed):
            return out


# ---- store -----------------------------------------------------------------------

def test_change_numbers_go_up_on_append_and_correction(store):
    a = msg(store, "assistant", "one")
    b = msg(store, "assistant", "two")
    assert [e.rev for e in store.fetch_events_since(0)] == [1, 2]
    store.update_event_text(a, "one, corrected")
    assert store.get_event(a).rev == 3 and store.current_rev() == 3
    changed = store.messages_changed_since(2, 10)
    assert [(e.seq, e.payload["text"]) for e in changed] == [(a, "one, corrected")]
    assert store.get_event(b).rev == 2


def test_change_numbers_never_reused_after_agent_deleted(store):
    msg(store, "bruce", "x"); msg(store, "bruce", "y")
    store.delete_profile_events("bruce")
    assert msg(store, "assistant", "z") == 3
    assert store.get_event(3).rev == 3


def test_existing_database_is_upgraded(tmp_path, clock):
    """A lekora.db from before chat history: rev backfilled, old messages count as read."""
    path = tmp_path / "old.db"
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE instance_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO instance_metadata VALUES ('instance_id', 'inst_old');
        CREATE TABLE events (seq INTEGER PRIMARY KEY AUTOINCREMENT, instance_id TEXT NOT NULL,
            profile_id TEXT NOT NULL, event_type TEXT NOT NULL, payload_json TEXT NOT NULL,
            created_at TEXT);
        INSERT INTO events (instance_id, profile_id, event_type, payload_json)
            VALUES ('inst_old', 'bruce', 'chat.message', '{"role":"assistant","text":"old"}'),
                   ('inst_old', 'bruce', 'chat.message', '{"role":"assistant","text":"older"}');
    """)
    db.commit(); db.close()
    s = Store(path, clock=clock)
    assert [e.rev for e in s.fetch_events_since(0)] == [1, 2]
    assert s.current_rev() == 2
    assert s.read_marker("bruce") == 2          # already read
    new = msg(s, "bruce", "new")
    assert s.get_event(new).rev == 3 and s.read_marker("bruce") == 2   # the new one is unread
    s.close()
    s = Store(path, clock=clock)                 # reopening changes nothing
    assert s.read_marker("bruce") == 2 and s.current_rev() == 3
    s.close()


def test_fresh_install_starts_with_nothing_read(store):
    assert store.read_marker("assistant") == 0


def test_read_marker_only_moves_forward(store):
    for i in range(5):
        msg(store, "assistant", f"m{i}")
    assert store.mark_read("assistant", 3)
    assert not store.mark_read("assistant", 2)
    assert store.read_marker("assistant") == 3
    assert store.mark_read("assistant", 999)     # capped at the newest message
    assert store.read_marker("assistant") == 5
    store.delete_profile_events("assistant")
    assert store.read_marker("assistant") == 0   # removed with the agent


def test_pages_of_older_messages(store):
    for i in range(1, 8):
        msg(store, "assistant" if i % 2 else "coder", f"m{i}")   # assistant: 1,3,5,7
    page, more = store.messages_before("assistant", 7, 2)
    assert [e.seq for e in page] == [3, 5] and more
    page, more = store.messages_before("assistant", 3, 2)
    assert [e.seq for e in page] == [1] and not more
    page, more = store.messages_before("assistant", None, 10)
    assert [e.seq for e in page] == [1, 3, 5, 7] and not more


def test_recent_messages_per_agent(store):
    for i in range(1, 8):
        msg(store, "assistant" if i % 2 else "coder", f"m{i}")
    assert [e.seq for e in store.recent_messages(2)] == [4, 5, 6, 7]


# ---- hello replay -------------------------------------------------------------------

async def test_phone_without_cache_gets_recent_messages(gw, store, monkeypatch):
    monkeypatch.setattr(gateway_mod, "RECENT_PER_PROFILE", 2)
    device_id, tok = store.register_device()
    for i in range(1, 8):
        msg(store, "assistant" if i % 2 else "coder", f"m{i}")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    ack = await recv(ws)
    assert ack["data"]["replay"] == "recent" and ack["data"]["rev"] == 7
    assert ack["data"]["message_times"] is True
    assert ack["data"]["read"] == {"assistant": 0, "coder": 0}
    got = await drain(ws)
    assert [m["data"]["seq"] for m in got] == [4, 5, 6, 7]
    assert all("rev" in m["data"] and "at" in m["data"] for m in got)
    await ws.close()


async def test_phone_with_cache_gets_changes_including_corrections(gw, store):
    device_id, tok = store.register_device()
    a = msg(store, "assistant", "first")
    msg(store, "assistant", "second")
    seen = store.current_rev()
    store.update_event_text(a, "first, corrected")   # made while the phone was away
    msg(store, "coder", "third")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=seen)
    ack = await recv(ws)
    assert ack["data"]["replay"] == "changes"
    got = await drain(ws)
    assert [(m["data"]["seq"], m["data"]["text"]) for m in got] == [(a, "first, corrected"), (3, "third")]
    await ws.close()


async def test_too_many_changes_falls_back_to_recent(gw, store, monkeypatch):
    monkeypatch.setattr(gateway_mod, "MAX_CHANGES_REPLAY", 3)
    monkeypatch.setattr(gateway_mod, "RECENT_PER_PROFILE", 2)
    device_id, tok = store.register_device()
    msg(store, "assistant", "seen")
    for i in range(5):
        msg(store, "assistant", f"new{i}")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=1)
    ack = await recv(ws)
    assert ack["data"]["replay"] == "recent"
    assert [m["data"]["text"] for m in await drain(ws)] == ["new3", "new4"]
    await ws.close()


async def test_old_app_without_since_rev_keeps_old_replay(gw, store):
    device_id, tok = store.register_device()
    for i in range(3):
        msg(store, "assistant", f"m{i}")
    ws = await hello(gw, store, device_id, tok, last_seq=1)
    ack = await recv(ws)
    assert "replay" not in ack["data"]
    assert [m["data"]["seq"] for m in await drain(ws)] == [2, 3]
    await ws.close()


async def test_live_messages_are_not_sent_twice_after_replay(gw, store):
    device_id, tok = store.register_device()
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(ws)
    seq = await gw.publish_message("assistant", "live")
    got = await drain(ws)
    assert [m["data"]["seq"] for m in got] == [seq]
    await ws.close()


# ---- history.fetch --------------------------------------------------------------

async def test_history_fetch_returns_a_page(gw, store):
    device_id, tok = store.register_device()
    for i in range(1, 6):
        msg(store, "assistant", f"m{i}")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)
    await ws.send(env(store, "history.fetch", {"before_seq": 4, "limit": 2},
                      profile_id="assistant", msg_id="f1"))
    page = await recv(ws)
    assert page["type"] == "history.page" and page["id"] == "f1" and page["profile_id"] == "assistant"
    assert [m["seq"] for m in page["data"]["messages"]] == [2, 3]
    assert all(m["at"] == "2026-11-07T12:00:00Z" for m in page["data"]["messages"])
    assert page["data"]["has_more"] is True
    await ws.send(env(store, "history.fetch", {"before_seq": 2}, profile_id="assistant", msg_id="f2"))
    page = await recv(ws)
    assert [m["text"] for m in page["data"]["messages"]] == ["m1"] and page["data"]["has_more"] is False
    await ws.send(env(store, "history.fetch", {}, profile_id="nobody", msg_id="f3"))
    err = await recv(ws)
    assert err["type"] == "error" and err["data"]["code"] == "UNKNOWN_PROFILE" and err["id"] == "f3"
    await ws.close()


# ---- chat.read ------------------------------------------------------------------

async def test_reading_on_one_phone_clears_it_on_the_others(gw, store):
    a_id, a_tok = store.register_device("a")
    b_id, b_tok = store.register_device("b")
    for i in range(3):
        msg(store, "coder", f"m{i}")
    a = await hello_rev(gw, store, a_id, a_tok, since_rev=store.current_rev())
    b = await hello_rev(gw, store, b_id, b_tok, since_rev=store.current_rev())
    assert (await recv(a))["data"]["read"]["coder"] == 0
    await recv(b)
    await a.send(env(store, "chat.read", {"seq": 3}, profile_id="coder"))
    note = await recv(b)
    assert note["type"] == "chat.read" and note["profile_id"] == "coder" and note["data"] == {"seq": 3}
    assert await drain(a) == []                       # the reader isn't told about itself
    await a.send(env(store, "chat.read", {"seq": 2}, profile_id="coder"))   # backwards: ignored
    assert await drain(b) == []
    assert store.read_marker("coder") == 3
    await a.close(); await b.close()
    c = await hello_rev(gw, store, a_id, a_tok, since_rev=store.current_rev())
    assert (await recv(c))["data"]["read"]["coder"] == 3   # a new connection learns it too
    await c.close()


async def test_user_messages_replay_with_their_client_id(gw, store):
    device_id, tok = store.register_device()
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(ws)
    await ws.send(env(store, "chat.send", {"text": "Hello"}, profile_id="coder", msg_id="c-9"))
    echo = await recv(ws)
    assert echo["data"]["client_id"] == "c-9" and echo["data"]["seq"] == 1
    await ws.close()
    again = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(again)
    assert (await recv(again))["data"]["client_id"] == "c-9"
    await again.close()
