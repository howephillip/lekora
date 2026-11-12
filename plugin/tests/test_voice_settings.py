"""Hearing replies: voice settings and Hermes' voice (docs/voice.md §2)."""

import base64

import pytest

from lekora.voice_settings import DEFAULTS, VoiceError, VoiceSettings, clean
from tests.test_files import ask, fgw, file_store, phone  # noqa: F401  (fixtures)
from tests.test_gateway import recv


def test_clean():
    assert clean({}) == DEFAULTS
    assert clean({"speak": "always", "engine": "hermes", "voice": "com.apple.voice.premium.en-US.Zoe", "rate": 7}) == \
        {"speak": "always", "engine": "hermes", "voice": "com.apple.voice.premium.en-US.Zoe", "rate": 1.0}
    for bad in ({"speak": "loud"}, {"engine": "robot"}, {"rate": "fast"}, {"voice": 3}, "nope"):
        with pytest.raises(VoiceError):
            clean(bad)


def test_settings_are_kept_per_agent(store):
    voice = VoiceSettings(store)
    assert voice.get("coder")["settings"] == DEFAULTS
    voice.set("coder", {"speak": "voice_notes", "rate": 0.6})
    assert voice.get("coder")["settings"]["speak"] == "voice_notes"
    assert voice.get("assistant")["settings"] == DEFAULTS, "every agent has its own"
    store.delete_profile_events("coder")
    assert voice.get("coder")["settings"] == DEFAULTS, "a deleted agent's settings go with it"


def test_any_voice_hermes_can_use_is_offered(store):
    # Built in, a command provider (e.g. a user's Fish Audio) or a plugin one: whatever Hermes can speak with.
    custom = VoiceSettings(store, hermes_voice=lambda p: {"available": True, "provider": "fishaudio-cli"})
    assert custom.get("coder")["hermes_voice"] == {"available": True, "provider": "fishaudio-cli"}
    missing_key = VoiceSettings(store, hermes_voice=lambda p: {"available": False, "provider": "elevenlabs"})
    assert missing_key.get("coder")["hermes_voice"]["available"] is False
    broken = VoiceSettings(store, hermes_voice=lambda p: 1 / 0)
    assert broken.get("coder")["hermes_voice"]["available"] is False


def test_speaking_is_made_once(store, file_store, tmp_path):
    made = []

    def speak(profile, text):
        made.append(text)
        if len(made) == 1:
            raise RuntimeError("provider hiccup")  # retried once
        parts = []
        for i in (1, 2):  # a long reply comes back in two parts: both are kept
            out = tmp_path / f"tts{len(made)}-{i}.mp3"
            out.write_bytes(b"ID3 mp3")
            parts.append(out)
        return parts

    voice = VoiceSettings(store, file_store, hermes_voice=lambda p: {"available": True, "provider": "openai"}, speak=speak)
    first = voice.speak("coder", 7, "Hello there")
    assert [f["name"] for f in first] == ["Reply 7 part 1.mp3", "Reply 7 part 2.mp3"] and first[0]["kind"] == "audio"
    assert voice.speak("coder", 7, "Hello there") == first and len(made) == 2, "reused"
    with pytest.raises(VoiceError):
        VoiceSettings(store, file_store).speak("coder", 8, "hi")


async def test_over_the_connection(fgw, store, file_store, tmp_path):
    def speak(profile, text):
        out = tmp_path / "tts.mp3"
        out.write_bytes(b"ID3 " + text.encode())
        return [out]

    fgw.voice = VoiceSettings(store, file_store, hermes_voice=lambda p: {"available": True, "provider": "elevenlabs"},
                              speak=speak)
    ws = await phone(fgw, store)
    other = await phone(fgw, store)
    got = await ask(ws, store, "voice.settings.get", {})
    assert got["data"]["settings"] == DEFAULTS and got["data"]["hermes_voice"]["available"] is True
    got = await ask(ws, store, "voice.settings.set", {"settings": {"speak": "always", "engine": "hermes"}})
    assert got["data"]["settings"]["speak"] == "always"
    changed = await recv(other)
    assert changed["type"] == "voice.settings.changed" and changed["profile_id"] == "coder"
    assert (await ask(ws, store, "voice.settings.set", {"settings": {"speak": "x"}}, msg_id="bad"))["data"]["code"] == "INVALID_SETTING"

    seq = await fgw.publish_message("coder", "Ramen at 7?")
    await recv(ws)
    await recv(other)
    spoken = await ask(ws, store, "voice.speak", {"seq": seq})
    assert spoken["data"]["seq"] == seq
    read = await ask(ws, store, "file.read", {"file_id": spoken["data"]["file"]["file_id"], "offset": 0})
    assert base64.b64decode(read["data"]["data"]) == b"ID3 Ramen at 7?"
    mine = store.append_event("coder", "chat.message", {"role": "user", "text": "hi"})
    assert (await ask(ws, store, "voice.speak", {"seq": mine}, msg_id="u"))["data"]["code"] == "UNKNOWN_MESSAGE"
    await ws.close()
    await other.close()
