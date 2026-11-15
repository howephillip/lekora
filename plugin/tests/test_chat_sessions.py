"""Past chats: the chat grouped by Hermes' own conversations (docs/chats.md)."""

import asyncio
from datetime import datetime, timezone

from lekora.chat_sessions import ChatSessions
from tests.test_files import ask, fgw, file_store, phone  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv
from tests.test_voice_replies import until


def ts(iso):
    return datetime.fromisoformat(iso).replace(tzinfo=timezone.utc).timestamp()


class FakeHermes:
    def __init__(self):
        self.now = "s_old"
        self.sent = []
        self.sessions = [
            {"id": "s_new", "title": "Tickets", "preview": '"Find tickets"', "started_at": ts("2026-11-13T10:00:00"), "last_active": ts("2026-11-13T11:00:00")},
            {"id": "s_old", "title": None, "preview": "Hey", "started_at": ts("2026-11-12T09:00:00"), "ended_at": ts("2026-11-13T10:00:00")},
        ]

    def list(self, profile, limit):
        return {"current": self.now, "sessions": self.sessions}

    async def command(self, profile, text):
        self.sent.append((profile, text))


def setup(fgw, store, hermes):
    fgw.chats = ChatSessions(store, hermes.list, lambda p: hermes.now, send_command=hermes.command)
    store.session_tagger = fgw.chats.current


async def test_messages_belong_to_the_conversation_they_were_saved_in(fgw, store):
    hermes = FakeHermes()
    setup(fgw, store, hermes)
    seq = store.append_event("coder", "chat.message", {"role": "user", "text": "hi"})
    assert store.get_event(seq).payload["session"] == "s_old", "tagged with the conversation it was said in"
    hermes.now = "s_new"
    seq2 = store.append_event("coder", "chat.message", {"role": "assistant", "text": "new chat"})
    assert store.get_event(seq2).payload["session"] == "s_new"

    # Older messages, saved before tagging: placed by time.
    chats = fgw.chats
    assert chats.session_of("coder", {}, "2026-11-12T12:00:00Z") == "s_old"
    assert chats.session_of("coder", {}, "2026-11-13T10:30:00Z") == "s_new"
    assert chats.session_of("coder", {}, "2026-11-01T00:00:00Z") is None, "before any conversation Hermes has"


async def test_the_phone_lists_reads_and_continues_past_chats(fgw, store):
    hermes = FakeHermes()
    setup(fgw, store, hermes)
    store.append_event("coder", "chat.message", {"role": "user", "text": "old one"})
    hermes.now = "s_new"
    store.append_event("coder", "chat.message", {"role": "user", "text": "new one"})
    ws = await phone(fgw, store)
    got = await ask(ws, store, "chats.list", {})
    data = got["data"]
    assert data["current"] == "s_new"
    by_id = {c["session_id"]: c for c in data["chats"]}
    assert by_id["s_new"]["title"] == "Tickets" and by_id["s_new"]["current"] is True
    assert by_id["s_old"]["messages"] == 1 and by_id["s_old"]["preview"] == "Hey"

    got = await ask(ws, store, "chat.history", {"session_id": "s_old"})
    assert [m["text"] for m in got["data"]["messages"]] == ["old one"]
    assert got["data"]["messages"][0]["session"] == "s_old"

    got = await ask(ws, store, "chat.resume", {"session_id": "s_old"})
    assert got["type"] == "chat.resume.result"
    assert hermes.sent == [("coder", "/resume s_old")], "Hermes' own /resume"

    got = await ask(ws, store, "chat.resume", {"session_id": "s_someone_else"})
    assert got["data"]["code"] == "UNKNOWN_CHAT", "only this agent's own chats"
    await ws.close()


async def test_live_messages_carry_their_conversation(fgw, store):
    hermes = FakeHermes()
    setup(fgw, store, hermes)
    ws = await phone(fgw, store)
    await fgw.publish_message("coder", "hello")
    message = (await until(ws, "chat.message"))[0]["data"]
    assert message["session"] == "s_old"
    await ws.close()


async def test_empty_chats_are_left_out(fgw, store):
    hermes = FakeHermes()
    hermes.sessions.insert(1, {"id": "s_empty", "started_at": ts("2026-11-13T09:00:00")})
    setup(fgw, store, hermes)
    hermes.now = "s_empty"
    store.append_event("coder", "chat.message", {"role": "system", "text": "New session started."})
    hermes.now = "s_new"
    store.append_event("coder", "chat.message", {"role": "user", "text": "hi"})
    ids = [c["session_id"] for c in fgw.chats.list("coder")["chats"]]
    assert "s_empty" not in ids and "s_new" in ids, "a chat with only Hermes' notice isn't listed"
