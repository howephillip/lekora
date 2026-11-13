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


    settings = VoiceSettings(store, file_store, hermes_voice=lambda p: {"available": available, "provider": "fish"},
                             speak=synthesize)
    settings.set("coder", {"speak": mode, "style": style})
    fgw.voice = settings
    fgw.voice_replies = VoiceReplies(fgw, settings, synthesize,
                                     persona=lambda p, preset=None: f"Preset {preset}." if preset else "Coder: terse and dry.")
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
    assert first["data"]["index"] == 0 and "script" not in first["data"], "the words are the reply's own"
    seq = await fgw.publish_message("coder", LONG, draft_id="live-1")
    saved = [m for m in await until(ws, "chat.message")][0]
    assert saved["data"]["voicing"] == "tts", "saved as a voice note, never text first"
    event = await saved_spoken(store, seq)
    assert spoken[0] == "Sure!", "the first sentence is spoken at once (the first sound is what you wait for)"
    assert spoken[1] == "I booked ramen for two at seven tonight.", "later short sentences go with the next"
    assert "data" in first["data"], "a small first part comes with the segment: no fetch before it plays"
    assert " ".join(spoken) == "Sure! I booked ramen for two at seven tonight. The place is called Ichiran. See you there."
    assert len(event.payload["spoken"]) == len(spoken) and event.payload["voicing"] == "tts"
    assert event.payload["text"] == LONG, "the text stays as its transcript"
    assert "spoken_text" not in event.payload, "plain voice says exactly the text"
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


async def test_personality_speaks_exactly_what_the_agent_wrote(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path, style="personality")
    ws = await phone(fgw, store)
    await ws.send(env(store, "chat.send", {"text": "how are you"}, profile_id="coder", msg_id="m1"))
    for _ in range(50):
        if fgw.received:
            break
        await asyncio.sleep(0.02)
    told = fgw.received[0]
    # The agent is told, for the turn, that its reply will be spoken: it writes the way it talks.
    assert told[3] and "spoken aloud to the user as a voice note, word for word" in told[3]
    assert "Speak as yourself" in told[3] and "occasional filler" in told[3]
    seq = await fgw.publish_message("coder", LONG)
    assert (await until(ws, "voice.reply"))[0]["data"]["style"] == "personality"
    event = await saved_spoken(store, seq)
    assert " ".join(spoken) == "Sure! I booked ramen for two at seven tonight. The place is called Ichiran. See you there.", \
        "nothing rewritten: what you hear is what it wrote (and what it remembers)"
    assert event.payload["voicing"] == "personality" and "spoken_text" not in event.payload
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
    told = await fgw.voice_replies.turn_instructions("coder")
    assert "Preset hype." in told and "Hermes' \"hype\" personality" in told and "filler words freely" in told
    fgw.voice.set("coder", {"speak": "always", "style": "tts"})
    assert await fgw.voice_replies.turn_instructions("coder") is None, "plain voice: the agent isn't told anything"
    fgw.voice.set("coder", {"speak": "off", "style": "personality"})
    assert await fgw.voice_replies.turn_instructions("coder") is None, "voice replies off: nothing either"


async def test_hands_free_replies_are_always_spoken(fgw, store, file_store, tmp_path):
    spoken = make(fgw, store, file_store, tmp_path, mode="off")
    ws = await phone(fgw, store)
    rec = await upload(ws, store, "v.m4a", b"aac", "audio/mp4")
    await ws.send(env(store, "chat.send", {"text": "", "files": [rec["file_id"]], "hands_free": True,
                                           "voice": {"duration": 1, "waveform": []}}, profile_id="coder", msg_id="h1"))
    await drain(ws)
    seq = await fgw.publish_message("coder", "Sure, here you go.")
    assert (await saved_spoken(store, seq)).payload["voicing"] == "tts", "voice replies off, but hands-free speaks"
    await ws.send(env(store, "chat.send", {"text": "typed now"}, profile_id="coder", msg_id="t2"))
    await drain(ws)
    seq = await fgw.publish_message("coder", "Text again.")
    await asyncio.sleep(0.1)
    assert "voicing" not in store.get_event(seq).payload, "back to the chat's own setting"
    await ws.close()


async def test_timings_are_logged_for_the_first_sound_and_the_phones_half(fgw, store, file_store, tmp_path, caplog):
    import logging
    make(fgw, store, file_store, tmp_path)
    ws = await phone(fgw, store)
    fgw.voice_replies.user_message("coder", False, hands_free=True)
    caplog.set_level(logging.INFO, logger="lekora.voice_replies")
    await fgw.publish_message("coder", LONG)
    await until(ws, "voice.segment")
    assert any("voice timing (coder)" in r.getMessage() for r in caplog.records)
    fgw.voice_replies.phone_timing("coder", {"silence_wait": 0.8, "recognize": 0.2, "audio_received": 1.5,
                                              "playing": 0.1, "total": 3.4, "sounds": "[laughs] 0.41"})
    line = next(r.getMessage() for r in caplog.records if "hands-free timing (coder)" in r.getMessage())
    assert "waited for quiet 0.8s" in line and "last word to the agent's first: 3.4s" in line
    assert "sounds noticed: [laughs] 0.41" in line
    await ws.close()
