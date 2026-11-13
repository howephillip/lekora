"""Direct voice: Lekora talks to the voice service and streams the sound (docs/voice.md §4)."""

import base64
import json

from lekora.direct_voice import DirectVoice, DirectVoiceError, clean, elevenlabs_speaker, fish_speaker, openai_speaker
from lekora.voice_replies import VoiceReplies
from lekora.voice_settings import VoiceSettings
from tests.test_files import fgw, file_store, phone  # noqa: F401  (fixtures)
from tests.test_gateway import env, recv
from tests.test_voice_replies import LONG, saved_spoken, until


def fake_post(calls, chunks=(b"\x01\x00\x02", b"\x00" * 9), status=None):
    def post(provider, url, headers, body, timeout=30):
        calls.append({"provider": provider, "url": url, "headers": headers, "body": body})
        if status:
            from lekora.direct_voice import _problem
            raise _problem(provider, status, "nope")
        return "audio/pcm; rate=22050", iter(chunks)
    return post


def test_settings_are_cleaned():
    settings = clean({"source": "fish", "fish": {"voice_id": " abc ", "speed": 9}, "openai": {"base_url": "ftp://x"}})
    assert settings["source"] == "fish" and settings["fish"]["voice_id"] == "abc"
    assert settings["fish"]["speed"] == 2.0 and settings["fish"]["model"] == "s2.1-pro"
    assert settings["openai"]["base_url"] == "https://api.openai.com/v1"
    assert clean({"source": "nonsense"})["source"] == "auto"


def test_each_service_is_asked_for_streamed_pcm():
    calls = []
    rate, chunks = fish_speaker({"voice_id": "v1", "model": "drama-3-preview", "speed": 1.1}, "k", post=fake_post(calls))("Hi [laughs]")
    assert rate == 24000 and b"".join(chunks) == b"\x01\x00\x02" + b"\x00" * 9, "whole samples, nothing lost"
    fish = calls[-1]
    assert fish["url"] == "https://api.fish.audio/v1/tts" and fish["headers"]["model"] == "drama-3-preview"
    assert fish["body"]["format"] == "pcm" and fish["body"]["reference_id"] == "v1" and fish["body"]["text"] == "Hi [laughs]"
    assert fish["headers"]["Authorization"] == "Bearer k"

    elevenlabs_speaker({"voice_id": "abc", "model_id": "m"}, "k2", post=fake_post(calls))("Hi")
    assert calls[-1]["url"].endswith("/text-to-speech/abc/stream?output_format=pcm_24000")
    assert calls[-1]["headers"] == {"xi-api-key": "k2"}

    rate, _ = openai_speaker({"base_url": "http://box:8000/v1/", "model": "kokoro", "voice": "af"}, "", post=fake_post(calls))("Hi")
    assert calls[-1]["url"] == "http://box:8000/v1/audio/speech" and calls[-1]["body"]["response_format"] == "pcm"
    assert rate == 22050, "the rate the server reports"
    try:
        elevenlabs_speaker({"voice_id": ""}, "k", post=fake_post(calls))("Hi")
        raise AssertionError("needs a voice")
    except DirectVoiceError as exc:
        assert exc.code == "VOICE_NOT_CHOSEN"


def test_keys_come_from_the_instance_or_the_app_and_never_go_back(store):
    direct = DirectVoice(store, env_value=lambda p, names: ("FISH_AUDIO", "sk-env") if "FISH_AUDIO" in names else None)
    assert direct.describe("coder")["keys"]["fish"] == "FISH_AUDIO"
    assert direct.describe("coder")["keys"]["elevenlabs"] == ""
    described = direct.set("coder", {"source": "elevenlabs"}, key={"provider": "elevenlabs", "value": "sk-secret"})
    assert described["keys"]["elevenlabs"] == "app"
    assert "sk-secret" not in json.dumps(described) and "sk-env" not in json.dumps(direct.describe("coder"))
    direct.set("coder", {"source": "elevenlabs"}, key={"provider": "elevenlabs", "value": ""})
    assert direct.describe("coder")["keys"]["elevenlabs"] == "", "cleared: back to the instance's key"
    assert direct.resolve("coder") is None, "no key: the old way"


def test_auto_uses_hermes_streaming_voice_when_there_is_one(store):
    speak = lambda text: (24000, iter([b"\x00\x00"]))  # noqa: E731
    assert DirectVoice(store, hermes_streamer=lambda p: ("Hermes (elevenlabs)", speak)).resolve("coder")[0] == "Hermes (elevenlabs)"
    assert DirectVoice(store, hermes_streamer=lambda p: None).resolve("coder") is None, "Hermes can't stream it: the old way"
    off = DirectVoice(store, hermes_streamer=lambda p: ("Hermes", speak))
    off.set("coder", {"source": "off"})
    assert off.resolve("coder") is None


def make_streaming(fgw, store, file_store, tmp_path, speak):
    spoken = []

    def synthesize(profile, script):
        spoken.append(script)
        out = tmp_path / f"s{len(spoken)}.mp3"
        out.write_bytes(b"ID3 " + script.encode())
        return [out]
    settings = VoiceSettings(store, file_store, hermes_voice=lambda p: {"available": True, "provider": "elevenlabs"},
                             speak=synthesize)
    settings.set("coder", {"speak": "always"})
    fgw.voice = settings
    direct = DirectVoice(store, hermes_streamer=lambda p: ("Hermes (elevenlabs)", speak))
    fgw.voice_replies = VoiceReplies(fgw, settings, synthesize, direct=direct)
    return spoken


async def test_a_reply_is_streamed_as_it_is_made_and_kept_as_a_voice_note(fgw, store, file_store, tmp_path):
    said = []

    def speak(text):
        said.append(text)
        return 24000, iter([b"\x01\x00" * 2400, b"\x02\x00" * 24000])  # 0.1 s, then 1 s
    spoken_the_old_way = make_streaming(fgw, store, file_store, tmp_path, speak)
    ws = await phone(fgw, store)
    seq = await fgw.publish_message("coder", LONG)
    told = (await until(ws, "voice.reply"))[0]["data"]
    assert told["streaming"] is True, "phones know the sound comes as a stream"
    first = (await until(ws, "voice.stream"))[0]["data"]
    assert first["index"] == 0 and first["chunk"] == 0 and first["rate"] == 24000
    assert len(base64.b64decode(first["data"])) == 4800, "the first sound goes out at once"
    rest = await until(ws, "voice.stream", 2)
    assert rest[-1]["data"].get("last") is True
    event = await saved_spoken(store, seq)
    assert len(event.payload["spoken"]) == len(said) == 3, "each piece kept as a part"
    assert said[0] == "Sure!" and spoken_the_old_way == [], "nothing made twice"
    await ws.close()


async def test_a_voice_service_failure_falls_back_to_hermes_voice(fgw, store, file_store, tmp_path):
    def speak(text):
        raise DirectVoiceError("VOICE_KEY_REFUSED", "refused")
    spoken_the_old_way = make_streaming(fgw, store, file_store, tmp_path, speak)
    ws = await phone(fgw, store)
    seq = await fgw.publish_message("coder", LONG)
    await until(ws, "voice.segment")
    event = await saved_spoken(store, seq)
    assert spoken_the_old_way, "the reply is still spoken, the old way"
    assert event.payload["spoken"]
    await ws.close()


async def test_direct_voice_settings_and_a_sample_from_the_phone(fgw, store, file_store, tmp_path):
    make_streaming(fgw, store, file_store, tmp_path, lambda text: (24000, iter([b"\x01\x00" * 100])))
    ws = await phone(fgw, store)
    await ws.send(env(store, "voice.direct.get", {}, msg_id="d1", profile_id="coder"))
    got = await recv(ws)
    assert got["type"] == "voice.direct.get.result" and got["data"]["hermes_streaming"] == "Hermes (elevenlabs)"
    await ws.send(env(store, "voice.direct.set", {"settings": {"source": "fish", "fish": {"voice_id": "v"}},
                                                  "key": {"provider": "fish", "value": "sk-x"}},
                      msg_id="d2", profile_id="coder"))
    got = await recv(ws)
    assert got["data"]["settings"]["source"] == "fish" and got["data"]["keys"]["fish"] == "app"
    assert "sk-x" not in json.dumps(got)
    fgw.voice_replies.direct.set("coder", {"source": "auto"})
    await ws.send(env(store, "voice.direct.test", {}, msg_id="d3", profile_id="coder"))
    got = await recv(ws)
    assert got["type"] == "voice.direct.test.result" and got["data"]["file"]["name"].startswith("Voice sample")
    await ws.close()


def test_real_http_streaming_against_a_local_server():
    """The plain-HTTP path (no SDKs), as an OpenAI-compatible server would answer."""
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Handler(BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            assert body["response_format"] == "pcm" and self.headers["Authorization"] == "Bearer k"
            self.send_response(200)
            self.send_header("Content-Type", "audio/pcm; rate=16000")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for piece in (b"\x01\x00\x02", b"\x00\x03\x00"):
                self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
            self.wfile.write(b"0\r\n\r\n")

        def log_message(self, *args):
            pass

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        url = f"http://127.0.0.1:{server.server_port}/v1"
        rate, chunks = openai_speaker({"base_url": url, "model": "m", "voice": "v"}, "k")("Hello")
        assert rate == 16000 and b"".join(chunks) == b"\x01\x00\x02\x00\x03\x00"
        try:
            fish_speaker({"voice_id": "v"}, "k", post=lambda *a, **k: (_ for _ in ()).throw(
                __import__("lekora.direct_voice", fromlist=["_problem"])._problem("fish", 401, "")))("Hi")
            raise AssertionError("refused")
        except DirectVoiceError as exc:
            assert exc.code == "VOICE_KEY_REFUSED" and "Fish Audio" in exc.reason
    finally:
        server.shutdown()
