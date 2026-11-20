"""Group chats run by Lekora (docs/group-chats.md)."""

import asyncio

import pytest

from lekora.artifacts import Artifacts
from lekora.groups import MAX_ROUNDS, Groups, is_pass, may_be_pass
from tests.test_gateway import PROFILES, env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev

MEMBERS = ["assistant", "coder"]


class Turns:
    """Stands in for handing a turn to an agent in Hermes."""

    def __init__(self):
        self.given = []  # (hermes chat, profile, text, files)
        self.notes = {}  # profile -> its group instruction

    async def __call__(self, chat, profile, text, message_id, files, note):
        self.given.append((chat, profile, text, files))
        self.notes[profile] = note

    def to(self, profile):
        return [t for t in self.given if t[1] == profile]


@pytest.fixture
def turns():
    return Turns()


@pytest.fixture
def groups(gw, store, turns):
    g = Groups(store, lambda: PROFILES, deliver=turns, changed=gw.publish_groups_changed, user_name=lambda: "Sam")
    gw.groups = g
    return g


async def phone(gw, store):
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    ack = await recv(ws)
    return ws, ack


async def ask(ws, store, type_, data, profile=None, msg_id="r1"):
    await ws.send(env(store, type_, data, profile_id=profile, msg_id=msg_id))
    return [m for m in await drain(ws) if m.get("id") == msg_id][0]


async def settle():
    for _ in range(5):
        await asyncio.sleep(0.02)


# ---- making groups ----------------------------------------------------------------

async def test_create_rename_change_members_and_delete(gw, store, groups):
    ws, _ = await phone(gw, store)
    made = await ask(ws, store, "group.create", {"name": "  Trip   planning ", "members": MEMBERS})
    group = made["data"]["group"]
    assert made["type"] == "group.create.result" and group["name"] == "Trip planning" and group["members"] == MEMBERS
    listed = await ask(ws, store, "groups.list", {}, msg_id="r2")
    assert [g["group_id"] for g in listed["data"]["groups"]] == [group["group_id"]]
    renamed = await ask(ws, store, "group.update", {"group_id": group["group_id"], "name": "Trip"}, msg_id="r3")
    assert renamed["data"]["group"]["name"] == "Trip"
    gone = await ask(ws, store, "group.delete", {"group_id": group["group_id"]}, msg_id="r4")
    assert gone["data"]["group_id"] == group["group_id"] and store.list_groups() == []


async def test_every_phone_hears_about_changes(gw, store, groups):
    ws, _ = await phone(gw, store)
    await groups.create("Trip", MEMBERS)
    changed = [m for m in await drain(ws) if m["type"] == "groups.changed"]
    assert changed and changed[-1]["data"]["groups"][0]["name"] == "Trip"


@pytest.mark.parametrize("name,members,code", [
    ("", MEMBERS, "INVALID_GROUP"), ("Solo", ["coder"], "INVALID_GROUP"), ("X", ["coder", "nobody"], "INVALID_GROUP")])
async def test_bad_groups_are_refused(gw, store, groups, name, members, code):
    ws, _ = await phone(gw, store)
    got = await ask(ws, store, "group.create", {"name": name, "members": members})
    assert got["type"] == "error" and got["data"]["code"] == code


async def test_a_deleted_agent_leaves_its_groups(gw, store, groups):
    g = await groups.create("Trip", MEMBERS)
    await groups.agent_removed("coder")
    assert store.get_group(g["group_id"])["members"] == ["assistant"]


# ---- talking ----------------------------------------------------------------------

async def group_key(groups):
    g = await groups.create("Trip", MEMBERS)
    return g["group_id"], groups.key(g["group_id"])


async def test_no_mention_is_everyone_and_each_gets_its_own_chat(gw, store, groups, turns):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await ws.send(env(store, "chat.send", {"text": "Where should we go?"}, profile_id=key, msg_id="m1"))
    await settle()
    assert sorted((t[0], t[1]) for t in turns.given) == [(f"g.{gid}.assistant", "assistant"), (f"g.{gid}.coder", "coder")]
    text = turns.to("coder")[0][2]
    assert text.startswith('[Group chat "Trip" in Lekora. You are @coder. Also here: @assistant (Hermes Assistant) and Sam (the user).]')
    assert text.endswith("Sam: Where should we go?")


@pytest.mark.parametrize("text,who", [
    ("@coder can you build it?", ["coder"]), ("@Coder, thoughts?", ["coder"]),
    ("@HermesAssistant hi", ["assistant"]), ("@all hello", MEMBERS), ("@everyone hello", MEMBERS),
    ("ask @nobody", MEMBERS)])
async def test_mentions_pick_who_answers(gw, store, groups, turns, text, who):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await ws.send(env(store, "chat.send", {"text": text}, profile_id=key, msg_id="m1"))
    await settle()
    assert sorted(t[1] for t in turns.given) == sorted(who)


async def test_replies_show_with_who_said_them_and_the_others_catch_up(gw, store, groups, turns):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await ws.send(env(store, "chat.send", {"text": "@assistant plan it"}, profile_id=key, msg_id="m1"))
    await settle()
    await gw.publish_message(f"g.{gid}.assistant", "Day 1: museum")
    got = [m for m in await drain(ws) if m["type"] == "chat.message" and m["data"].get("speaker")]
    assert got[-1]["profile_id"] == key and got[-1]["data"]["speaker"] == "assistant"
    await ws.send(env(store, "chat.send", {"text": "@coder book it"}, profile_id=key, msg_id="m2"))
    await settle()
    caught_up = turns.to("coder")[0][2]
    assert "Sam: @assistant plan it" in caught_up and "@assistant (Hermes Assistant): Day 1: museum" in caught_up
    assert caught_up.endswith("Sam: @coder book it")
    # The assistant isn't handed its own words, nor what it already had.
    await ws.send(env(store, "chat.send", {"text": "@assistant thanks"}, profile_id=key, msg_id="m3"))
    await settle()
    again = turns.to("assistant")[-1][2]
    assert "Day 1: museum" not in again and "plan it" not in again and "Sam: @coder book it" in again


async def test_a_pass_is_never_shown(gw, store, groups, turns):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await gw.publish_draft(f"g.{gid}.coder", "d1", "(pa")
    assert await gw.publish_message(f"g.{gid}.coder", "(pass)", draft_id="d1") == 0
    msgs = await drain(ws)
    assert not [m for m in msgs if m["type"] == "chat.draft" and m["data"].get("text")]
    assert not [m for m in msgs if m["type"] == "chat.message"]
    await gw.publish_draft(f"g.{gid}.coder", "d2", "Sure, I can")
    draft = [m for m in await drain(ws) if m["type"] == "chat.draft"][0]
    assert draft["profile_id"] == key and draft["data"]["speaker"] == "coder"


def test_pass_words():
    assert is_pass(" (pass) ") and is_pass("PASS") and not is_pass("(pass) but also")
    assert may_be_pass("(pa") and may_be_pass("") and not may_be_pass("Sure")


async def test_an_agent_can_bring_another_in_within_the_guard(gw, store, groups, turns):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await ws.send(env(store, "chat.send", {"text": "@assistant start"}, profile_id=key, msg_id="m1"))
    await settle()
    await gw.publish_message(f"g.{gid}.assistant", "@coder can you check the code?")
    await settle()
    assert len(turns.to("coder")) == 1 and "@coder can you check the code?" in turns.to("coder")[0][2]
    # They keep pulling each other in: it stops after the round limit.
    await gw.publish_message(f"g.{gid}.coder", "@assistant your turn")      # round 2
    await settle()
    await gw.publish_message(f"g.{gid}.assistant", "@coder back to you")    # round 3
    await settle()
    await gw.publish_message(f"g.{gid}.coder", "@assistant and again")      # would be round 4: no
    await settle()
    assert len(turns.given) - 1 == MAX_ROUNDS  # minus the user's own message's turn


async def test_typing_and_cards_in_a_group_say_who(gw, store, groups):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await gw.publish_typing(f"g.{gid}.coder", True, "Searching")
    typing = [m for m in await drain(ws) if m["type"] == "chat.typing"][0]
    assert typing["profile_id"] == key and typing["data"]["speaker"] == "coder"
    seq = await gw.publish_card(f"g.{gid}.coder", "approval", "Wants to run ls", {"id": "c1", "kind": "approval"})
    ev = store.get_event(seq)
    assert ev.profile_id == key and ev.payload["speaker"] == "coder"


async def test_artifacts_made_in_a_group_belong_to_the_group(gw, store, groups):
    gid, key = await group_key(groups)
    gw.artifacts = Artifacts(store, gw.publish_artifact_message, gw.publish_artifact_changed)
    gw.artifacts.key = gw.phone_key
    made = await gw.artifacts.create(f"g.{gid}.coder", "Plan", "markdown", "# Plan")
    assert [a["artifact_id"] for a in gw.artifacts.list(key)] == [made["artifact_id"]]
    assert gw.artifacts.read(key, made["artifact_id"])["content"] == "# Plan"
    # The agent itself still reaches it from its own chat of the group.
    await gw.artifacts.update(f"g.{gid}.coder", made["artifact_id"], "# Plan v2")
    card = [e for e in store.events_for_profile(key) if e.payload.get("artifact")][-1]
    assert card.payload["speaker"] == "coder"


async def test_history_and_read_markers_work_for_a_group(gw, store, groups):
    gid, key = await group_key(groups)
    await gw.publish_message(f"g.{gid}.coder", "Hello")
    ws, ack = await phone(gw, store)
    assert key in ack["data"]["read"]
    page = await ask(ws, store, "history.fetch", {"limit": 10}, profile=key)
    assert page["type"] == "history.page" and page["data"]["messages"][0]["speaker"] == "coder"


async def test_voice_notes_wait_for_later_in_groups(gw, store, groups):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    got = await ask(ws, store, "chat.send", {"text": "", "voice": {"duration": 1, "waveform": []}, "files": ["f_x"]},
                    profile=key, msg_id="m1")
    assert got["type"] == "error" and got["data"]["code"] == "UNAVAILABLE"


async def test_a_new_member_starts_from_now(gw, store, groups, turns):
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await ws.send(env(store, "chat.send", {"text": "old news"}, profile_id=key, msg_id="m1"))
    await settle()
    PROFILES.append({"profile_id": "writer", "name": "Writer", "avatar": "pencil"})
    try:
        await groups.update(gid, members=MEMBERS + ["writer"])
        assert store.get_group(gid)["seen"].get("writer") is None
        await ws.send(env(store, "chat.send", {"text": "@writer hello"}, profile_id=key, msg_id="m2"))
        await settle()
        assert "Sam: @writer hello" in turns.to("writer")[0][2]
    finally:
        PROFILES.pop()


async def test_each_member_is_told_it_is_in_a_group(gw, store, groups, turns):
    """Only in groups (owner, 2026-11-20): the per-turn chat instruction, never the user's message."""
    gid, key = await group_key(groups)
    ws, _ = await phone(gw, store)
    await ws.send(env(store, "chat.send", {"text": "hi all"}, profile_id=key, msg_id="m1"))
    await settle()
    note = turns.notes["coder"]
    assert note.startswith('GROUP CHAT (Lekora): you are @coder in the group chat "Trip" with @assistant (Hermes Assistant) and Sam')
    assert "(pass)" in note and "@assistant" in note
    assert "GROUP CHAT" not in turns.to("coder")[0][2]  # the message itself stays the conversation
