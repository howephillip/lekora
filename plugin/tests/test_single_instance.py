"""Regression for 2026-11-08: a second Lekora copy (started in a cloned agent's profile)
took a new port and overwrote the saved one, so new pairing codes didn't work."""

import pytest

from lekora.instance_lock import InstanceLock, LekoraAlreadyRunning
from lekora.plugin import LekoraConfig, LekoraService
from lekora.profiles import named_profile_in_scope


class FakeHermes:
    async def deliver_to_agent(self, profile_id, text, message_id):
        pass


def service(db):
    return LekoraService(FakeHermes(), LekoraConfig(db_path=str(db), listen_host="127.0.0.1"),
                         check_version=False)


async def test_second_copy_cannot_start_or_change_the_saved_port(tmp_path):
    db = tmp_path / "lekora.db"
    first, second = service(db), service(db)
    port = await first.start()
    try:
        with pytest.raises(LekoraAlreadyRunning):
            await second.start()
        assert first.store.get_persisted_port() == port   # not overwritten
        assert second.gateway is None                      # never listened
    finally:
        await first.stop()


async def test_lock_is_released_on_stop(tmp_path):
    db = tmp_path / "lekora.db"
    first = service(db)
    port = await first.start()
    await first.stop()
    second = service(db)
    assert await second.start() == port  # takes over the same port after a clean stop
    await second.stop()


def test_lock_is_exclusive_and_reusable(tmp_path):
    a, b = InstanceLock(tmp_path / "x.lock"), InstanceLock(tmp_path / "x.lock")
    a.acquire()
    with pytest.raises(LekoraAlreadyRunning):
        b.acquire()
    a.release()
    b.acquire()
    b.release()


def test_named_profile_detection():
    assert named_profile_in_scope("dingo") == "dingo"   # Hermes' owner tag
    assert named_profile_in_scope("default") is None
    assert named_profile_in_scope(None) is None          # no Hermes here: treated as default
