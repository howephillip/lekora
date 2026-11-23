"""Hermes glue for live calls (docs/live-calls.md). Imports Hermes lazily: only runs inside it.

- ``gpt_setup``: GPT-Live's session for an agent, from Hermes' own settings (``voice.gpt_live``, its OpenAI
  key chain) inside that agent's profile, set for a WebSocket (24 kHz 16-bit audio).
- ``fish_key``: the Fish Audio key Hermes already uses (``FISH_AUDIO``).
- ``connect`` / ``http``: a WebSocket client and JSON requests, for OpenAI and Fish.
"""

from __future__ import annotations

import json
import ssl
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

from .live_calls import LiveError

HISTORY_MESSAGES = 20
HISTORY_CHARS = 12_000


def _ssl() -> ssl.SSLContext:
    try:
        import certifi
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


class HermesLive:
    def __init__(self, home_of: Callable[[str], Path], agent_name: Callable[[str], str]) -> None:
        self._home_of = home_of
        self._agent_name = agent_name

    def gpt_setup(self, profile_id: str, history: list) -> dict:
        from gateway.run import _profile_runtime_scope
        from tools import voice_live
        with _profile_runtime_scope(Path(self._home_of(profile_id)), hydrate_secrets=True):
            status = voice_live.resolve_gpt_live_status()
            if not status.get("available"):
                raise LiveError("NO_KEY", "GPT-Live needs an OpenAI API key on the Hermes instance "
                                          "(OPENAI_API_KEY in the agent's .env, or voice.gpt_live.api_key)")
            key, base = voice_live._resolve_credentials(voice_live._live_section())
            session = voice_live.build_session_config(history or None)
        name = self._agent_name(profile_id)
        session["instructions"] = (f"{session.get('instructions', '')}\n\nYou are the voice of {name}, the user's own "
                                   f"AI agent. Hand every real request to it (delegate); it knows the user.").strip()
        session.setdefault("audio", {})["format"] = {"type": "audio/pcm", "rate": 24000}
        url = base.replace("https://", "wss://").replace("http://", "ws://") + "/live/sessions"
        return {"url": url, "key": key, "session": session}

    def fish_key(self, profile_id: str) -> Optional[str]:
        """The agent's own Fish Audio key, as its voice replies use it. Hermes only gives keys out inside an
        agent's profile (a multiplexed gateway refuses an unscoped read), so it's read in there."""
        try:
            from gateway.run import _profile_runtime_scope
            from hermes_cli.config import get_env_value
            with _profile_runtime_scope(Path(self._home_of(profile_id)), hydrate_secrets=True):
                return (get_env_value("FISH_AUDIO") or "").strip() or None
        except Exception:
            return None

    @staticmethod
    async def connect(url: str, headers: dict) -> Any:
        from websockets.asyncio.client import connect
        return await connect(url, additional_headers=headers, ssl=_ssl(), max_size=None, open_timeout=15)

    @staticmethod
    def http(method: str, url: str, body: Optional[dict], key: str) -> Any:
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {key}", "Content-Type": "application/json", "User-Agent": "Lekora"})
        try:
            with urllib.request.urlopen(request, timeout=30, context=_ssl()) as response:
                raw = response.read()
        except urllib.error.HTTPError as exc:
            detail = exc.read().decode(errors="replace")[:300]
            raise LiveError("LIVE_FAILED", f"Fish answered {exc.code}: {detail}")
        return json.loads(raw) if raw else {}


def chat_history(store: Any, profile_id: str) -> list:
    """The chat's latest messages, as GPT-Live's starting context (up to 20, about 12,000 characters)."""
    try:
        events = store.recent_messages(HISTORY_MESSAGES * 2)
    except Exception:
        return []
    out, used = [], 0
    for event in reversed([e for e in events if e.profile_id == profile_id]):
        role = event.payload.get("role")
        text = " ".join(str(event.payload.get("text") or "").split())
        if role not in ("user", "assistant") or not text:
            continue
        if used + len(text) > HISTORY_CHARS or len(out) >= HISTORY_MESSAGES:
            break
        used += len(text)
        out.append({"type": "message", "role": role,
                    "content": [{"type": "input_text" if role == "user" else "output_text", "text": text}]})
    return list(reversed(out))
