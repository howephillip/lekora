import json
import stat

import pytest

from lekora.profile_admin import ProfileAdmin, ProfileAdminError, profile_id_for_name


@pytest.fixture
def admin(store, fake_hermes_root, fake_cli, clock):
    return ProfileAdmin(store, hermes_root=lambda: fake_hermes_root, run_cli=fake_cli, clock=clock)


def make_profile(root, name):
    home = root / "profiles" / name
    home.mkdir(parents=True)
    (home / "config.yaml").write_text("model: x\n")
    return home


async def expect(code, coro):
    with pytest.raises(ProfileAdminError) as e:
        await coro
    assert e.value.code == code
    return e.value


# ---- names -------------------------------------------------------------------

@pytest.mark.parametrize("name,expected", [
    ("Research Assistant", "research-assistant"),
    ("  Bruce  ", "bruce"),
    ("Q3 / Finance!!", "q3-finance"),
    ("a" * 80, "a" * 64),
    ("!!!", ""),
])
def test_profile_id_for_name(name, expected):
    assert profile_id_for_name(name) == expected


# ---- create ------------------------------------------------------------------

async def test_create_clones_default_and_returns_the_agent(admin, fake_cli):
    created = await admin.create("Research Assistant", "Finds sources")
    assert created == {"profile_id": "research-assistant", "name": "Research assistant",
                       "avatar": "sparkles", "description": "Finds sources"}
    assert fake_cli.calls == [["profile", "create", "research-assistant", "--clone-from", "default",
                               "--no-alias", "--description", "Finds sources"]]


async def test_create_without_description(admin, fake_cli):
    await admin.create("Bruce")
    assert "--description" not in fake_cli.calls[0]


async def test_create_refuses_bad_and_existing_names(admin, fake_hermes_root, fake_cli):
    await expect("INVALID_NAME", admin.create("   "))
    await expect("INVALID_NAME", admin.create("!!!"))
    await expect("PROFILE_EXISTS", admin.create("Default"))
    make_profile(fake_hermes_root, "bruce")
    await expect("PROFILE_EXISTS", admin.create("Bruce"))
    assert fake_cli.calls == []  # Hermes never asked


async def test_create_reports_hermes_failure(admin, fake_cli):
    fake_cli.fail["create"] = (1, "Cloning...\nError: disk full\n")
    err = await expect("PROFILE_OP_FAILED", admin.create("Bruce"))
    assert "disk full" in err.reason


# ---- delete safeguards ---------------------------------------------------------

async def test_delete_never_default(admin, fake_cli):
    await expect("CANNOT_DELETE_DEFAULT", admin.delete("default", "default"))
    assert fake_cli.calls == []


async def test_delete_needs_exact_confirmation(admin, fake_hermes_root, fake_cli):
    make_profile(fake_hermes_root, "bruce")
    await expect("CONFIRMATION_REQUIRED", admin.delete("bruce", None))
    await expect("CONFIRMATION_REQUIRED", admin.delete("bruce", "Bruce"))
    assert fake_cli.calls == []
    assert (fake_hermes_root / "profiles" / "bruce").is_dir()


async def test_delete_unknown(admin):
    await expect("UNKNOWN_PROFILE", admin.delete("ghost", "ghost"))


async def test_delete_backs_up_first_then_deletes(admin, store, fake_hermes_root, fake_cli):
    make_profile(fake_hermes_root, "bruce")
    store.append_event("bruce", "chat.message", {"role": "user", "text": "hi bruce"})
    store.append_event("default", "chat.message", {"role": "user", "text": "hi home"})

    backup = await admin.delete("bruce", "bruce")

    assert [c[1] for c in fake_cli.calls] == ["export", "delete"]  # export strictly before delete
    assert fake_cli.calls[1] == ["profile", "delete", "bruce", "--yes"]
    assert backup == "lekora-backups/profiles/bruce-20261107-120000.tar.gz"
    backups = fake_hermes_root / "lekora-backups" / "profiles"
    assert (fake_hermes_root / backup).read_bytes() == b"archive"
    chat = json.loads((backups / "bruce-20261107-120000-lekora-chat.json").read_text())
    assert [e["payload"]["text"] for e in chat["events"]] == ["hi bruce"]
    assert stat.S_IMODE(backups.stat().st_mode) == 0o700  # contains the profile's keys
    assert not (fake_hermes_root / "profiles" / "bruce").exists()
    # Lekora's own history for bruce is gone (it's in the backup); default's is untouched.
    assert [e.profile_id for e in store.fetch_events_since(0)] == ["default"]


async def test_failed_backup_deletes_nothing(admin, store, fake_hermes_root, fake_cli):
    make_profile(fake_hermes_root, "bruce")
    store.append_event("bruce", "chat.message", {"role": "user", "text": "keep me"})
    fake_cli.fail["export"] = (1, "Error: no space left\n")
    err = await expect("BACKUP_FAILED", admin.delete("bruce", "bruce"))
    assert "nothing was deleted" in err.reason and "no space" in err.reason
    assert [c[1] for c in fake_cli.calls] == ["export"]  # delete never ran
    assert (fake_hermes_root / "profiles" / "bruce").is_dir()
    assert len(store.events_for_profile("bruce")) == 1


async def test_empty_backup_deletes_nothing(admin, fake_hermes_root, fake_cli):
    make_profile(fake_hermes_root, "bruce")
    fake_cli.empty_export = True
    await expect("BACKUP_FAILED", admin.delete("bruce", "bruce"))
    assert (fake_hermes_root / "profiles" / "bruce").is_dir()


async def test_failed_hermes_delete_keeps_chat_history_and_backup(admin, store, fake_hermes_root, fake_cli):
    make_profile(fake_hermes_root, "bruce")
    store.append_event("bruce", "chat.message", {"role": "user", "text": "keep me"})
    fake_cli.fail["delete"] = (1, "Error: profile in use\n")
    err = await expect("PROFILE_OP_FAILED", admin.delete("bruce", "bruce"))
    assert "backup kept" in err.reason
    assert len(store.events_for_profile("bruce")) == 1
    assert any((fake_hermes_root / "lekora-backups" / "profiles").glob("bruce-*.tar.gz"))


async def test_seq_never_goes_backwards_after_delete(admin, store, fake_hermes_root):
    make_profile(fake_hermes_root, "bruce")
    store.append_event("default", "chat.message", {"role": "user", "text": "1"})
    store.append_event("bruce", "chat.message", {"role": "user", "text": "2"})
    await admin.delete("bruce", "bruce")
    assert store.current_seq() == 2
    assert store.append_event("default", "chat.message", {"role": "user", "text": "3"}) == 3
