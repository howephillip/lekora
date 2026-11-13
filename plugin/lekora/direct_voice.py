"""Direct voice (spec: docs/voice.md §4): Lekora talks to the voice service itself and streams
the sound to the phones while it's being made, instead of waiting for a whole sentence's file.

Owner, 2026-11-13: "Lekora talk to the voice provider directly - whether ElevenLabs, Fish, or
another OpenAI compatible provider". Where the voice comes from, per agent:

- ``auto`` (default): the agent's own Hermes voice, streamed by Hermes' own streaming voices
  (ElevenLabs, OpenAI-compatible, Gemini, xAI, plugin voices that stream) with Hermes' keys and
  voice choices; when Hermes can't stream that voice, the old way (Hermes makes each piece's file).
- ``fish`` / ``elevenlabs`` / ``openai``: Lekora connects to that service itself, with the voice
  and model chosen in the app. The key is the one already on this Hermes instance (its ``.env``,
  e.g. ``FISH_API_KEY``) or one entered in the app, kept in Lekora's store here and never sent
  back to a phone.
- ``off``: the old way only.

Nothing in Hermes' settings is changed.
"""

from __future__ import annotations

import json
import logging
import urllib.error
import urllib.request
from typing import Any, Callable, Iterator, Optional

log = logging.getLogger(__name__)

SETTINGS_KEY = "direct_voice"
KEYS_KEY = "direct_voice_keys"
SOURCES = ("auto", "fish", "elevenlabs", "openai", "off")
PROVIDERS = ("fish", "elevenlabs", "openai")

DEFAULTS: dict[str, Any] = {
    "source": "auto",
    "fish": {"voice_id": "", "model": "s2.1-pro", "speed": 1.0},
    "elevenlabs": {"voice_id": "", "model_id": "eleven_flash_v2_5"},
    "openai": {"base_url": "https://api.openai.com/v1", "model": "gpt-4o-mini-tts", "voice": "alloy"},
}
# Where each service's key usually is in a Hermes .env (first found wins).
KEY_NAMES = {
    "fish": ("FISH_API_KEY", "FISH_AUDIO_API_KEY", "FISH_AUDIO"),
    "elevenlabs": ("ELEVENLABS_API_KEY",),
    "openai": ("OPENAI_API_KEY",),
}
LABELS = {"fish": "Fish Audio", "elevenlabs": "ElevenLabs", "openai": "OpenAI-compatible"}
SAMPLE_RATE = 24000

# (text) -> (sample rate, PCM chunks: 16-bit little-endian mono). Blocking; iterate in one thread.
Speak = Callable[[str], tuple[int, Iterator[bytes]]]


class DirectVoiceError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def _text(value: Any, default: str, limit: int = 300) -> str:
    return " ".join(str(value).split())[:limit] if isinstance(value, (str, int, float)) and str(value).strip() else default


def clean(value: Any) -> dict:
    """Settings from a phone, with anything unknown or wrong replaced by the default."""
    value = value if isinstance(value, dict) else {}
    source = value.get("source") if value.get("source") in SOURCES else DEFAULTS["source"]
    out: dict[str, Any] = {"source": source}
    for provider in PROVIDERS:
        given = value.get(provider) if isinstance(value.get(provider), dict) else {}
        section = {}
        for key, default in DEFAULTS[provider].items():
            if isinstance(default, float):
                try:
                    section[key] = min(max(float(given.get(key, default)), 0.5), 2.0)
                except (TypeError, ValueError):
                    section[key] = default
            else:
                section[key] = _text(given.get(key), default if key != "voice_id" else "")
        out[provider] = section
    url = out["openai"]["base_url"]
    if not url.startswith(("https://", "http://")):
        out["openai"]["base_url"] = DEFAULTS["openai"]["base_url"]
    return out


def _even(chunks: Iterator[bytes]) -> Iterator[bytes]:
    """Whole 16-bit samples only (a chunk can end mid-sample)."""
    rest = b""
    for chunk in chunks:
        data = rest + chunk
        cut = len(data) - len(data) % 2
        rest = data[cut:]
        if cut:
            yield data[:cut]


def _problem(provider: str, status: int, body: str) -> DirectVoiceError:
    name = LABELS[provider]
    if status in (401, 403):
        return DirectVoiceError("VOICE_KEY_REFUSED", f"{name} refused the key. Check it in Chat Settings › Voice › Direct Voice.")
    if status == 402:
        return DirectVoiceError("VOICE_NO_CREDIT", f"{name} says the account is out of credit.")
    if status == 404:
        return DirectVoiceError("VOICE_NOT_FOUND", f"{name} doesn't know that voice or model.")
    if status == 429:
        return DirectVoiceError("VOICE_BUSY", f"{name} is limiting requests right now.")
    return DirectVoiceError("VOICE_FAILED", f"{name} couldn't speak (HTTP {status}): {body[:160]}")


def post_stream(provider: str, url: str, headers: dict, body: dict, timeout: float = 30) -> tuple[Optional[str], Iterator[bytes]]:
    """POSTs JSON and returns (content type, the response body as it arrives)."""
    request = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                     headers={**headers, "Content-Type": "application/json"})
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as exc:
        raise _problem(provider, exc.code, exc.read(400).decode("utf-8", "replace")) from None
    except (urllib.error.URLError, OSError) as exc:
        raise DirectVoiceError("VOICE_UNREACHABLE", f"Couldn't reach {LABELS[provider]}: {exc}") from None

    def chunks() -> Iterator[bytes]:
        with response:
            while True:
                piece = response.read1(16384) if hasattr(response, "read1") else response.read(16384)
                if not piece:
                    return
                yield piece
    return response.headers.get("X-Audio-Sample-Rate") or response.headers.get("Content-Type"), chunks()


def _rate(header: Optional[str], default: int) -> int:
    import re
    match = re.search(r"(?:^|rate\s*=\s*)(\d{4,6})", str(header or ""))
    return int(match.group(1)) if match else default


def fish_speaker(section: dict, key: str, post=post_stream) -> Speak:
    def speak(text: str) -> tuple[int, Iterator[bytes]]:
        body: dict[str, Any] = {"text": text, "format": "pcm", "sample_rate": SAMPLE_RATE, "latency": "balanced",
                                "prosody": {"speed": section.get("speed", 1.0)}}
        if section.get("voice_id"):
            body["reference_id"] = section["voice_id"]
        _, chunks = post("fish", "https://api.fish.audio/v1/tts", {"Authorization": f"Bearer {key}",
                                                                   "model": section.get("model") or "s2.1-pro"}, body)
        return SAMPLE_RATE, _even(chunks)
    return speak


def elevenlabs_speaker(section: dict, key: str, post=post_stream) -> Speak:
    def speak(text: str) -> tuple[int, Iterator[bytes]]:
        voice = section.get("voice_id")
        if not voice:
            raise DirectVoiceError("VOICE_NOT_CHOSEN", "Choose an ElevenLabs voice in Chat Settings › Voice › Direct Voice.")
        url = f"https://api.elevenlabs.io/v1/text-to-speech/{urllib.request.quote(voice)}/stream?output_format=pcm_{SAMPLE_RATE}"
        _, chunks = post("elevenlabs", url, {"xi-api-key": key},
                         {"text": text, "model_id": section.get("model_id") or DEFAULTS["elevenlabs"]["model_id"]})
        return SAMPLE_RATE, _even(chunks)
    return speak


def openai_speaker(section: dict, key: str, post=post_stream) -> Speak:
    def speak(text: str) -> tuple[int, Iterator[bytes]]:
        url = section.get("base_url", DEFAULTS["openai"]["base_url"]).rstrip("/") + "/audio/speech"
        header, chunks = post("openai", url, {"Authorization": f"Bearer {key}"} if key else {},
                              {"model": section.get("model"), "voice": section.get("voice"), "input": text,
                               "response_format": "pcm"})
        return _rate(header, SAMPLE_RATE), _even(chunks)
    return speak


MAKERS = {"fish": fish_speaker, "elevenlabs": elevenlabs_speaker, "openai": openai_speaker}


class DirectVoice:
    def __init__(self, store: Any,
                 hermes_streamer: Optional[Callable[[str], Optional[tuple[str, Speak]]]] = None,
                 env_value: Optional[Callable[[str, tuple], Optional[tuple[str, str]]]] = None,
                 post=post_stream) -> None:
        self.store = store
        # profile -> (label, speak) when Hermes can stream the agent's own voice (blocking)
        self.hermes_streamer = hermes_streamer
        # (profile, names) -> (name, value) of the first set in the agent's Hermes .env (blocking)
        self.env_value = env_value
        self.post = post

    # ---- settings --------------------------------------------------------------------

    def get_settings(self, profile_id: str) -> dict:
        return clean(self.store.get_app_setting(profile_id, SETTINGS_KEY) or {})

    def _saved_keys(self, profile_id: str) -> dict:
        saved = self.store.get_app_setting(profile_id, KEYS_KEY)
        return saved if isinstance(saved, dict) else {}

    def _key(self, profile_id: str, provider: str) -> tuple[str, str]:
        """(the key, where it came from: "app" / the .env name / "")."""
        saved = self._saved_keys(profile_id).get(provider)
        if isinstance(saved, str) and saved:
            return saved, "app"
        if self.env_value is not None:
            try:
                found = self.env_value(profile_id, KEY_NAMES[provider])
            except Exception:
                log.debug("Lekora: couldn't read the agent's keys", exc_info=True)
                found = None
            if found:
                return found[1], found[0]
        return "", ""

    def describe(self, profile_id: str) -> dict:
        """Settings and what each choice would use (never a key itself)."""
        settings = self.get_settings(profile_id)
        keys = {}
        for provider in PROVIDERS:
            _, origin = self._key(profile_id, provider)
            keys[provider] = origin  # "app", "FISH_API_KEY"… or "" (none)
        hermes = None
        if self.hermes_streamer is not None:
            try:
                found = self.hermes_streamer(profile_id)
                hermes = found[0] if found else None
            except Exception:
                log.debug("Lekora: couldn't check Hermes' streaming voice", exc_info=True)
        return {"settings": settings, "keys": keys, "hermes_streaming": hermes, "labels": LABELS}

    def set(self, profile_id: str, value: Any, key: Optional[dict] = None) -> dict:
        settings = clean(value)
        self.store.set_app_setting(profile_id, SETTINGS_KEY, settings)
        if isinstance(key, dict) and key.get("provider") in PROVIDERS:
            keys = self._saved_keys(profile_id)
            secret = str(key.get("value") or "").strip()
            if secret:
                keys[key["provider"]] = secret[:500]
            else:
                keys.pop(key["provider"], None)  # empty: back to the key on this instance
            self.store.set_app_setting(profile_id, KEYS_KEY, keys)
        return self.describe(profile_id)

    # ---- speaking --------------------------------------------------------------------

    def resolve(self, profile_id: str) -> Optional[tuple[str, Speak]]:
        """How this agent's replies are streamed right now, or None (the old way)."""
        settings = self.get_settings(profile_id)
        source = settings["source"]
        if source == "off":
            return None
        if source == "auto":
            if self.hermes_streamer is None:
                return None
            try:
                return self.hermes_streamer(profile_id)
            except Exception:
                log.warning("Lekora: Hermes' streaming voice isn't usable for %s", profile_id, exc_info=True)
                return None
        key, _ = self._key(profile_id, source)
        if not key and source != "openai":
            log.warning("Lekora: no %s key for %s; using Hermes' voice instead", LABELS[source], profile_id)
            return None
        speak = MAKERS[source](settings[source], key, post=self.post)
        return LABELS[source], lambda text: speak(_prepare(text))


def _prepare(text: str) -> str:
    """Hermes' own clean-up of text before it's spoken (symbols, identifiers…), when present;
    [tags] such as [laughs] are kept for voices that act them."""
    try:
        from tools.tts_text_normalize import prepare_spoken_text
    except ImportError:
        return text
    try:
        return prepare_spoken_text(text) or text
    except Exception:
        return text
