import sqlite3

import pytest

from lekora.store import Store, TokenExpired, TokenInvalid, default_db_path


def test_schema_tables_and_instance_id_columns(store, db_path):
    db = sqlite3.connect(db_path)
    tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    assert {"instance_metadata", "pairing_invites", "paired_devices", "events"} <= tables
    for t in ("pairing_invites", "paired_devices", "events"):
        cols = {r[1] for r in db.execute(f"PRAGMA table_info({t})")}
        assert "instance_id" in cols


def test_instance_id_stable_across_reopen(db_path, clock):
    a = Store(db_path, clock=clock)
    first = a.instance_id
    a.close()
    b = Store(db_path, clock=clock)
    assert b.instance_id == first and first.startswith("inst_")
    b.close()


def test_port_persistence(db_path, clock):
    a = Store(db_path, clock=clock)
    assert a.get_persisted_port() is None
    a.set_persisted_port(49152)
    a.set_persisted_port(50000)  # update, not duplicate
    a.close()
    b = Store(db_path, clock=clock)
    assert b.get_persisted_port() == 50000
    b.close()


def test_invite_single_use(store):
    token = store.create_invite()
    store.consume_invite(token, client_ip="10.0.0.5")
    with pytest.raises(TokenInvalid):
        store.consume_invite(token)


def test_invite_unknown_token(store):
    with pytest.raises(TokenInvalid):
        store.consume_invite("nope")


def test_invite_expires_after_30_minutes(store, clock):
    token = store.create_invite()
    clock.advance(minutes=29, seconds=59)
    # still valid just before the boundary
    other = store.create_invite()
    store.consume_invite(token)
    clock.advance(minutes=31)
    with pytest.raises(TokenExpired):
        store.consume_invite(other)


def test_expired_invite_not_consumed(store, clock):
    token = store.create_invite()
    clock.advance(minutes=30)
    with pytest.raises(TokenExpired):
        store.consume_invite(token)


def test_tokens_stored_only_as_hashes(store, db_path):
    invite = store.create_invite()
    device_id, dev_token = store.register_device("iPhone", "1.0.0")
    raw = sqlite3.connect(db_path)
    dump = "\n".join(raw.iterdump())
    assert invite not in dump
    assert dev_token not in dump


def test_device_token_verification(store):
    device_id, token = store.register_device("iPhone", "1.0.0")
    assert device_id.startswith("dev_") and token.startswith("sec_")
    assert store.verify_device_token(device_id, token)
    assert not store.verify_device_token(device_id, token + "x")
    assert not store.verify_device_token("dev_unknown", token)


def test_revoked_device_rejected(store):
    device_id, token = store.register_device()
    assert store.revoke_device(device_id)
    assert not store.verify_device_token(device_id, token)
    assert not store.revoke_device(device_id)  # already revoked


def test_events_monotonic_and_replay(store):
    assert store.current_seq() == 0
    seqs = [store.append_event("assistant", "chat.message", {"text": str(i)}) for i in range(5)]
    assert seqs == [1, 2, 3, 4, 5]
    assert store.current_seq() == 5
    since = store.fetch_events_since(2)
    assert [e.seq for e in since] == [3, 4, 5]
    assert since[0].payload == {"text": "2"}
    assert since[0].profile_id == "assistant"
    assert store.fetch_events_since(5) == []


def test_events_survive_reopen_and_seq_continues(db_path, clock):
    a = Store(db_path, clock=clock)
    a.append_event("coder", "chat.message", {"text": "x"})
    a.close()
    b = Store(db_path, clock=clock)
    assert b.append_event("coder", "chat.message", {"text": "y"}) == 2
    b.close()


def test_db_path_env_override(monkeypatch, tmp_path):
    monkeypatch.setenv("LEKORA_DB_PATH", str(tmp_path / "x.db"))
    assert default_db_path() == tmp_path / "x.db"
    monkeypatch.delenv("LEKORA_DB_PATH")
    assert default_db_path().name == "lekora.db"
    assert default_db_path().parent.name == ".hermes"


def test_list_devices_empty(store):
    assert store.list_devices() == []


def test_list_devices_fields_and_order(store, clock):
    first_id, _ = store.register_device("iPhone", "1.0.0")
    clock.advance(minutes=5)
    second_id, _ = store.register_device("iPad", "1.1.0")
    devices = store.list_devices()
    assert [d.device_id for d in devices] == [first_id, second_id]  # oldest first
    first = devices[0]
    assert (first.device_name, first.client_version) == ("iPhone", "1.0.0")
    assert first.paired_at == first.last_seen_at == "2026-11-07T12:00:00Z"
    assert first.revoked_at is None and first.active


def test_list_devices_shows_revoked_and_last_seen(store, clock):
    device_id, token = store.register_device("iPhone")
    clock.advance(hours=1)
    assert store.verify_device_token(device_id, token)  # a reconnect updates last seen
    clock.advance(minutes=1)
    store.revoke_device(device_id)
    (device,) = store.list_devices()
    assert device.last_seen_at == "2026-11-07T13:00:00Z"
    assert device.revoked_at == "2026-11-07T13:01:00Z"
    assert not device.active


def test_is_device_active(store):
    device_id, _ = store.register_device()
    assert store.is_device_active(device_id)
    store.revoke_device(device_id)
    assert not store.is_device_active(device_id)
    assert not store.is_device_active("dev_unknown")


def test_revoke_from_another_connection_is_seen(db_path, clock):
    # `hermes lekora devices --revoke` runs in its own process with its own connection.
    gateway_store = Store(db_path, clock=clock)
    cli_store = Store(db_path, clock=clock)
    try:
        device_id, _ = gateway_store.register_device("iPhone")
        assert cli_store.revoke_device(device_id)
        assert not gateway_store.is_device_active(device_id)
    finally:
        gateway_store.close()
        cli_store.close()
