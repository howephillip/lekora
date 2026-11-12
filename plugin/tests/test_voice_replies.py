"""Voice mode: replies as voice notes in the agent's Hermes voice, streamed (docs/voice.md §2)."""

import asyncio

from lekora.voice_replies import VoiceReplies, next_sentences, spoken_text
from lekora.voice_settings import VoiceSettings
from tests.test_files import ask, fgw, file_store, phone, upload  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv
from tests.test_history import drain


def test_sentences_as_they_come():
    said, upto = next_sentences("Sure! I booked", 0, False)
    assert said == ["Sure!"]
    said, upto = next_sentences("Sure! I booked ramen. See", upto, False)
    assert said == ["I booked ramen."]
    said, upto = next_sentences("Sure! I booked ramen. See you", upto, True)
    assert said == ["See you"]
    assert next_sentences("Run:\n```\na. b. c\n", 0, False)[0] == ["Run:"]
    assert spoken_text("**Bold** [site](https://x.com) `x`") == "Bold site x"


def make(fgw, store, file_store, tmp_path, mode="always", available=True):
    spoken = []

    def synthesize(profile, sentence):
        spoken.append(sentence)
        out = tmp_path / f"s{len(spoken)}.mp3"
        out.write_bytes(b"ID3 " + sentence.encode())
        return [out]

    settings = VoiceSettings(store, file_store, hermes_voice=lambda p: {"available": available, "provider": "fish"},
                             speak=synthesize)
    settings.set("coder", {"speak": mode})
    fgw.voice = settings
    fgw.voice_replies = VoiceReplies(fgw, settings, synthesize)
    return spoken


async def segments(ws, count):
    got = []
    while len(got) < count:
        msg = await recv(ws, timeout=3)
        if msg["type"] == "voice.segment":
            got.append(msg)
    return got


async def test_a_streamed_reply_is_spoken_then_becomes_a_voice_note(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path)
    ws = await phone(fgw, store)
    await fgw.publish_draft("coder", "live-1", "Sure! I booked")
    first = await segments(ws, 1)
    assert first[0]["data"]["message_id"] == "live-1" and first[0]["data"]["index"] == 0, "the first sentence plays at once"
    await fgw.publish_draft("coder", "live-1", "Sure! I booked ramen for two. See")
    await segments(ws, 1)
    seq = await fgw.publish_message("coder", "Sure! I booked ramen for two. See you there", draft_id="live-1")
    await segments(ws, 1)
    for _ in range(100):
        event = store.get_event(seq)
        if event.payload.get("spoken"):
            break
        await asyncio.sleep(0.02)
    assert spoken == ["Sure!", "I booked ramen for two.", "See you there"], "each sentence once"
    assert [p["name"] for p in event.payload["spoken"]] == ["Voice reply part 1.mp3", "Voice reply part 2.mp3",
                                                           "Voice reply part 3.mp3"]
    assert event.payload["text"] == "Sure! I booked ramen for two. See you there", "the text stays as its transcript"
    await ws.close()


async def test_off_or_no_hermes_voice_means_text(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path, mode="off")
    seq = await fgw.publish_message("coder", "Plain reply.")
    await asyncio.sleep(0.1)
    assert spoken == [] and "spoken" not in store.get_event(seq).payload
    spoken = make(fgw, store, file_store, tmp_path, mode="always", available=False)
    await fgw.publish_message("coder", "Still text.")
    await asyncio.sleep(0.1)
    assert spoken == []


async def test_voice_notes_mode_answers_voice_with_voice(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path, mode="voice_notes")
    ws = await phone(fgw, store)
    await ws.send(env(store, "chat.send", {"text": "typed"}, profile_id="coder", msg_id="t1"))
    await drain(ws)
    await fgw.publish_message("coder", "Text back.")
    await asyncio.sleep(0.1)
    assert spoken == []
    await drain(ws)
    rec = await upload(ws, store, "v.m4a", b"aac", "audio/mp4")
    await ws.send(env(store, "chat.send", {"text": "", "files": [rec["file_id"]], "voice": {"duration": 1, "waveform": []}},
                      profile_id="coder", msg_id="v1"))
    await drain(ws)
    await fgw.publish_message("coder", "Voice back.")
    for _ in range(50):
        if spoken:
            break
        await asyncio.sleep(0.02)
    assert spoken == ["Voice back."]
    await ws.close()


async def test_speech_trouble_never_stops_the_reply(fgw, store, file_store, tmp_path):
    make(fgw, store, file_store, tmp_path)

    def broken(profile, sentence):
        raise RuntimeError("provider down")

    fgw.voice_replies.synthesize = broken
    ws = await phone(fgw, store)
    seq = await fgw.publish_message("coder", "Hello.")
    got = await recv(ws)
    assert got["data"]["seq"] == seq and got["data"]["text"] == "Hello."
    await asyncio.sleep(0.1)
    assert "spoken" not in store.get_event(seq).payload, "stays a text reply"
    await ws.close()
