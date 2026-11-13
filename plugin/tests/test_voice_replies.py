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


def make(fgw, store, file_store, tmp_path, mode="always", available=True, style="tts", audio=b"ID3 "):
    spoken = []

    def synthesize(profile, script):
        spoken.append(script)
        out = tmp_path / f"s{len(spoken)}.mp3"
        out.write_bytes(audio + script.encode())
        return [out]

    def rewrite(profile, text, instructions):
        rewrites.append(instructions)
        return f"[warmly] {text}"

    rewrites = []
    fgw.rewrites = rewrites

    settings = VoiceSettings(store, file_store, hermes_voice=lambda p: {"available": available, "provider": "fish"},
                             speak=synthesize)
    settings.set("coder", {"speak": mode, "style": style})
    fgw.voice = settings
    fgw.voice_replies = VoiceReplies(fgw, settings, synthesize, rewrite, persona=lambda p, preset=None: f"Preset {preset}." if preset else "Coder: terse and dry.")
    return spoken


async def until(ws, kind, count=1):
    got = []
    while len(got) < count:
        msg = await recv(ws, timeout=3)
        if msg["type"] == kind:
            got.append(msg)
    return got


async def saved_spoken(store, seq):
    for _ in range(150):
        event = store.get_event(seq)
        if event.payload.get("spoken") is not None:
            return event
        await asyncio.sleep(0.02)
    return store.get_event(seq)


LONG = "Sure! I booked ramen for two at seven tonight. The place is called Ichiran. See you there."


async def test_a_streamed_reply_is_a_voice_note_from_the_first_word(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path)
    ws = await phone(fgw, store)
    await fgw.publish_draft("coder", "live-1", "Sure!")
    told = (await until(ws, "voice.reply"))[0]
    assert told["data"] == {"message_id": "live-1", "style": "tts"}, "phones know before any audio"
    await fgw.publish_draft("coder", "live-1", "Sure! I booked ramen for two at seven tonight. The")
    first = (await until(ws, "voice.segment"))[0]
    assert first["data"]["index"] == 0
    seq = await fgw.publish_message("coder", LONG, draft_id="live-1")
    saved = [m for m in await until(ws, "chat.message")][0]
    assert saved["data"]["voicing"] == "tts", "saved as a voice note, never text first"
    event = await saved_spoken(store, seq)
    assert spoken[0] == "Sure! I booked ramen for two at seven tonight.", "short sentences go with the next"
    assert " ".join(spoken) == "Sure! I booked ramen for two at seven tonight. The place is called Ichiran. See you there."
    assert len(event.payload["spoken"]) == len(spoken) and event.payload["voicing"] == "tts"
    assert event.payload["text"] == LONG, "the text stays as its transcript"
    await ws.close()


async def test_a_reply_saved_at_once_is_a_voice_note_too(fgw, store, file_store, tmp_path):
    make(fgw, store, file_store, tmp_path)
    ws = await phone(fgw, store)
    seq = await fgw.publish_message("coder", LONG)
    saved = (await until(ws, "chat.message"))[0]["data"]
    assert saved["voicing"] == "tts"
    segment = (await until(ws, "voice.segment"))[0]["data"]
    assert segment["message_id"] == saved["voice_key"], "the phone can match its parts"
    assert (await saved_spoken(store, seq)).payload["spoken"]
    await ws.close()


async def test_personality_rewrites_then_speaks(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path, style="personality")
    ws = await phone(fgw, store)
    seq = await fgw.publish_message("coder", LONG)
    assert (await until(ws, "voice.reply"))[0]["data"]["style"] == "personality"
    event = await saved_spoken(store, seq)
    assert all(s.startswith("[warmly] ") for s in spoken), "the voice script, not the plain text"
    assert event.payload["voicing"] == "personality" and event.payload["text"] == LONG, "visible text unchanged"
    assert "Coder: terse and dry." in fgw.rewrites[0], "sounds like the agent's own Hermes personality"
    await ws.close()


async def test_audio_iphone_cant_play_is_explained(fgw, store, file_store, tmp_path, monkeypatch):
    import shutil
    monkeypatch.setattr(shutil, "which", lambda name: None)  # no ffmpeg on this machine
    make(fgw, store, file_store, tmp_path, audio=b"OggS")
    ws = await phone(fgw, store)
    seq = await fgw.publish_message("coder", LONG)
    problems = [m for m in await until(ws, "voice.reply", 2) if m["data"].get("problem")]
    assert "iPhone can't play" in problems[0]["data"]["problem"]
    event = await saved_spoken(store, seq)
    assert event.payload["spoken"] == [] and "ffmpeg" in event.payload["voice_problem"]
    await ws.close()


async def test_off_or_no_hermes_voice_means_text(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path, mode="off")
    seq = await fgw.publish_message("coder", "Plain reply.")
    await asyncio.sleep(0.1)
    assert spoken == [] and "voicing" not in store.get_event(seq).payload
    spoken = make(fgw, store, file_store, tmp_path, mode="always", available=False)
    seq = await fgw.publish_message("coder", "Still text.")
    await asyncio.sleep(0.1)
    assert spoken == [] and "voicing" not in store.get_event(seq).payload


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
    got = (await until(ws, "chat.message"))[0]
    assert got["data"]["seq"] == seq and got["data"]["text"] == "Hello."
    await asyncio.sleep(0.2)
    assert store.get_event(seq).payload.get("spoken") == [], "no audio: the phone shows the text"
    await ws.close()


async def test_personality_can_be_one_of_hermes_personalities(fgw, store, file_store, tmp_path):
    make(fgw, store, file_store, tmp_path, style="personality")
    fgw.voice.set("coder", {"speak": "always", "style": "personality", "style_source": "preset", "style_preset": "hype",
                            "fillers": 2})
    seq = await fgw.publish_message("coder", LONG)
    await saved_spoken(store, seq)
    assert "Preset hype." in fgw.rewrites[0] and "Hermes' \"hype\" personality" in fgw.rewrites[0]
    assert "filler words freely" in fgw.rewrites[0]
