"""Hearing replies (spec: docs/voice.md §2): each agent's voice settings, and speaking a reply
with Hermes' own voice.

Settings live in the plugin's store (``app_settings``), so every phone and a new phone get
them (rule 3). Nothing is written to Hermes' config. Hermes' voice is used only when the agent's
own Hermes settings name a cloud voice; the adapter passes in how to check and how to speak.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable, Optional

SPEAK = ("off", "voice_notes", "always")
ENGINES = ("iphone", "hermes")
DEFAULTS: dict[str, Any] = {"speak": "off", "engine": "iphone", "voice": None, "rate": 0.5}
# Hermes' voices that need an account (owner's decision: Hermes' voice only for these).
CLOUD_PROVIDERS = {"elevenlabs", "openai", "gemini", "xai", "mistral", "minimax", "deepinfra", "fish", "fishaudio"}
KEY = "voice"


class VoiceError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


def clean(value: Any) -> dict:
    """Checked settings: {speak, engine, voice (an iPhone voice id or None), rate 0…1}."""
    if not isinstance(value, dict):
        raise VoiceError("INVALID_SETTING", "Voice settings were damaged")
    out = dict(DEFAULTS)
    if value.get("speak") is not None:
        if value["speak"] not in SPEAK:
            raise VoiceError("INVALID_SETTING", "Unknown 'speak replies' choice")
        out["speak"] = value["speak"]
    if value.get("engine") is not None:
        if value["engine"] not in ENGINES:
            raise VoiceError("INVALID_SETTING", "Unknown voice")
        out["engine"] = value["engine"]
    voice = value.get("voice")
    if voice is not None:
        if not isinstance(voice, str) or len(voice) > 200:
            raise VoiceError("INVALID_SETTING", "Unknown voice")
        out["voice"] = voice
    if value.get("rate") is not None:
        try:
            out["rate"] = round(min(max(float(value["rate"]), 0.0), 1.0), 3)
        except (TypeError, ValueError):
            raise VoiceError("INVALID_SETTING", "Unknown speed")
    return out


def _no_hermes_voice(profile_id: str) -> dict:
    return {"available": False, "provider": None}


class VoiceSettings:
    def __init__(self, store: Any, files: Any = None,
                 hermes_voice: Callable[[str], dict] = _no_hermes_voice,
                 speak: Optional[Callable[[str, str], Path]] = None) -> None:
        self.store = store
        self.files = files
        self._hermes_voice = hermes_voice     # profile -> {available, provider} (blocking)
        self._speak = speak                   # (profile, text) -> audio file (blocking)

    def get(self, profile_id: str) -> dict:
        saved = self.store.get_app_setting(profile_id, KEY) or {}
        settings = dict(DEFAULTS, **{k: v for k, v in saved.items() if k in DEFAULTS})
        return {"settings": settings, "hermes_voice": self.hermes_voice(profile_id)}

    def set(self, profile_id: str, value: Any) -> dict:
        settings = clean(value)
        self.store.set_app_setting(profile_id, KEY, settings)
        return settings

    def hermes_voice(self, profile_id: str) -> dict:
        try:
            found = self._hermes_voice(profile_id) or {}
        except Exception:
            found = {}
        provider = found.get("provider")
        return {"available": bool(found.get("available")) and provider in CLOUD_PROVIDERS, "provider": provider}

    def speak(self, profile_id: str, seq: int, text: str) -> dict:
        """The reply as Hermes' voice: an audio file (made once per reply, then reused)."""
        cache_key = f"speech:{seq}"
        if self.files is not None:
            known = self.store.get_app_setting(profile_id, cache_key)
            if known:
                try:
                    return self.files.describe(self.files.ready(known))
                except Exception:
                    pass
        if self._speak is None or self.files is None or not self.hermes_voice(profile_id)["available"]:
            raise VoiceError("VOICE_UNAVAILABLE", "This agent has no Hermes voice set up")
        try:
            path = self._speak(profile_id, text)
        except Exception as exc:
            raise VoiceError("VOICE_UNAVAILABLE", f"Hermes couldn't speak it: {exc}")
        described = self.files.add_agent_file(profile_id, Path(path), name=f"Reply {seq}{Path(path).suffix or '.mp3'}")
        self.store.set_app_setting(profile_id, cache_key, described["file_id"])
        return described
