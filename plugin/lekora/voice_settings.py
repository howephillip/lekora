"""Hearing replies (spec: docs/voice.md §2): each agent's voice settings, and speaking a reply
with Hermes' own voice.

Settings live in the plugin's store (``app_settings``), so every phone and a new phone get
them (rule 3). Nothing is written to Hermes' config. Hermes' voice is whatever voice that agent's
Hermes settings use (built in, a command provider, or one added by a Hermes plugin), offered
whenever Hermes can speak with it; the adapter passes in how to check and how to speak.
"""

from __future__ import annotations

from pathlib import Path
import logging
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)

SPEAK = ("off", "voice_notes", "always")
ENGINES = ("iphone", "hermes")
STYLES = ("tts", "personality")
DEFAULTS: dict[str, Any] = {"speak": "off", "engine": "iphone", "voice": None, "rate": 0.5,
                            "style": "tts", "style_instructions": None}
MAX_INSTRUCTIONS = 4000
# Personality voice (owner's idea, 2026-11-12): how a reply is turned into a voice script before
# Hermes speaks it. Generic on purpose; users write their own for their voice and provider.
DEFAULT_STYLE_INSTRUCTIONS = (
    "Rewrite the reply as natural speech, the way this agent would say it out loud: conversational, "
    "warm, with contractions and short sentences. Keep every fact and name. Spell out numbers, "
    "symbols and abbreviations the way they are spoken. Add natural pauses with commas and '…'. "
    "If the voice understands delivery tags (for example [laughs], [whispers], [excited] or "
    "(sighs)), use a few where they fit; otherwise use none.")
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
    if value.get("style") is not None:
        if value["style"] not in STYLES:
            raise VoiceError("INVALID_SETTING", "Unknown voice style")
        out["style"] = value["style"]
    instructions = value.get("style_instructions")
    if instructions is not None:
        if not isinstance(instructions, str) or len(instructions) > MAX_INSTRUCTIONS:
            raise VoiceError("INVALID_SETTING", f"Voice instructions can be up to {MAX_INSTRUCTIONS} characters")
        out["style_instructions"] = instructions.strip() or None
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
                 speak: Optional[Callable[[str, str], list[Path]]] = None) -> None:
        self.store = store
        self.files = files
        self._hermes_voice = hermes_voice     # profile -> {available, provider} (blocking)
        self._speak = speak                   # (profile, text) -> audio files, in order (blocking)
        self._voice_cache: dict[str, tuple[float, dict]] = {}

    def get_settings(self, profile_id: str) -> dict:
        saved = self.store.get_app_setting(profile_id, KEY) or {}
        return dict(DEFAULTS, **{k: v for k, v in saved.items() if k in DEFAULTS})

    def get(self, profile_id: str) -> dict:
        settings = self.get_settings(profile_id)
        return {"settings": settings, "hermes_voice": self.hermes_voice(profile_id, fresh=True),
                "default_style_instructions": DEFAULT_STYLE_INSTRUCTIONS}

    def set(self, profile_id: str, value: Any) -> dict:
        settings = clean(value)
        self.store.set_app_setting(profile_id, KEY, settings)
        return settings

    def hermes_voice(self, profile_id: str, fresh: bool = False) -> dict:
        import time
        cached = self._voice_cache.get(profile_id)
        if not fresh and cached and time.monotonic() - cached[0] < 60:
            return cached[1]
        try:
            found = self._hermes_voice(profile_id) or {}
        except Exception:
            log.warning("Lekora: couldn't check %s's Hermes voice", profile_id, exc_info=True)
            found = {}
        result = {"available": bool(found.get("available")), "provider": found.get("provider")}
        self._voice_cache[profile_id] = (time.monotonic(), result)
        return result

    def speak(self, profile_id: str, seq: int, text: str) -> list[dict]:
        """The reply in Hermes' voice: its audio file(s), in order (a long reply can be several;
        made once per reply, then reused)."""
        cache_key = f"speech:{seq}"
        if self.files is not None:
            known = self.store.get_app_setting(profile_id, cache_key)
            if known:
                try:
                    return [self.files.describe(self.files.ready(f)) for f in (known if isinstance(known, list) else [known])]
                except Exception:
                    pass
        if self._speak is None or self.files is None or not self.hermes_voice(profile_id)["available"]:
            raise VoiceError("VOICE_UNAVAILABLE", "This agent has no Hermes voice set up")
        paths: list[Path] = []
        problem: Optional[Exception] = None
        for _attempt in (1, 2):  # a provider hiccup gets one retry
            try:
                paths = [Path(p) for p in self._speak(profile_id, text)]
                if paths:
                    break
            except Exception as exc:
                problem = exc
                log.warning("Lekora: Hermes couldn't speak reply %s for %s: %s", seq, profile_id, exc)
        if not paths:
            raise VoiceError("VOICE_UNAVAILABLE", f"Hermes couldn't speak it: {problem or 'no audio'}")
        from .playable_audio import UnplayableAudio, playable
        try:
            paths = [playable(p) for p in paths]
        except UnplayableAudio as exc:
            raise VoiceError("VOICE_UNAVAILABLE", exc.reason)
        described = [self.files.add_agent_file(profile_id, p, name=f"Reply {seq}" + (f" part {i + 1}" if len(paths) > 1 else "")
                                               + (p.suffix or ".mp3"))
                     for i, p in enumerate(paths)]
        self.store.set_app_setting(profile_id, cache_key, [d["file_id"] for d in described])
        return described
