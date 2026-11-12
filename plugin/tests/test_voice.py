"""Voice notes (docs/voice.md)."""

import asyncio

from lekora.hermes_files import inbound_media, transcript_from_echo
from tests.test_files import ask, fgw, file_store, phone, upload  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv


async def send_voice(ws, store, fid, msg_id="v1"):
    await ws.send(env(store, "chat.send", {"text": "", "files": [fid],
                                           "voice": {"duration": 3.456, "waveform": [0.1, 2, -1, 0.5]}},
                      profile_id="coder", msg_id=msg_id))
    return await recv(ws)


async def test_a_voice_note_reaches_hermes_and_gets_its_transcript(fgw, store):
    ws = await phone(fgw, store)
    other = await phone(fgw, store)
    rec = await upload(ws, store, "Voice note.m4a", b"m4a audio", "audio/mp4")
    echo = await send_voice(ws, store, rec["file_id"])
    assert echo["data"]["voice"] == {"duration": 3.46, "waveform": [0.1, 1.0, 0.0, 0.5]}
    await recv(other)
    for _ in range(50):
        if fgw.received:
            break
        await asyncio.sleep(0.02)
    assert fgw.received[0][2][0]["voice"] is True, "Hermes is told it's a voice note"

    assert await fgw.attach_transcript("coder", "Book ramen for two") is True
    updated = await recv(other)
    assert updated["data"]["seq"] == echo["data"]["seq"] and updated["data"]["transcript"] == "Book ramen for two"
    assert updated["data"]["rev"] > echo["data"]["rev"], "a new change number: phones away get it too"
    assert await fgw.attach_transcript("coder", "again") is False, "only once per voice note"
    await ws.close()
    await other.close()


async def test_voice_needs_one_recording(fgw, store):
    ws = await phone(fgw, store)
    pdf = await upload(ws, store, "r.pdf", b"%PDF", "application/pdf")
    got = await send_voice(ws, store, pdf["file_id"])
    assert got["data"]["code"] == "INVALID_FILE"
    await ws.close()


def test_transcript_echo_is_recognised():
    assert transcript_from_echo('🎙️ "Hello there"') == "Hello there"
    assert transcript_from_echo("🎙 “Bonjour”") == "Bonjour"
    assert transcript_from_echo('🎙️ "two\nlines"') == "two\nlines"
    assert transcript_from_echo("Hello") is None
    assert transcript_from_echo('Here: 🎙️ "x"') is None


def test_voice_goes_to_hermes_as_voice(tmp_path):
    rec = tmp_path / "v.m4a"
    rec.write_bytes(b"aac")
    media = inbound_media("", [{"path": str(rec), "name": "v.m4a", "mime": "audio/mp4", "voice": True}],
                          lambda d, n, m: ("/cache/v.m4a", "audio/mp4", "audio"))
    assert media.message_kind == "voice" and media.media_types == ["audio/mp4"]
    assert media.media_text_inlined == [False]


async def test_service_takes_only_transcripts(tmp_path, fake_hermes_root):
    from lekora.plugin import LekoraConfig, LekoraService
    from tests.test_plugin import FakeHermes
    cfg = LekoraConfig(db_path=str(tmp_path / "lekora.db"), listen_host="127.0.0.1",
                       hermes_root=str(fake_hermes_root),
                       profiles=[{"profile_id": "coder", "name": "Coder", "avatar": "terminal"}])
    svc = LekoraService(FakeHermes(), cfg, hermes_version="0.22.5")
    await svc.start()
    try:
        assert await svc.take_transcript("coder", '🎙️ "hi"') is False, "no voice note waiting: shown as usual"
        assert await svc.take_transcript("coder", "Just text") is False
    finally:
        await svc.stop()
