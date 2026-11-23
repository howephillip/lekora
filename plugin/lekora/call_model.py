"""An agent's call model (docs/voice.md §3, "Speed"): Hermes' own ``auxiliary.voice_chat``, the faster
model Hermes uses for spoken turns. Words said in a Lekora call already reach Hermes as voice turns,
so this one setting makes calls answer faster with the same agent, voice and tools.

Owner's choice (2026-11-22, rule 8 exception like OpenRouter routing): only ``auxiliary.voice_chat`` in
the agent's config.yaml is changed, through Hermes' own config writer, after a backup.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)


class CallModelError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


class CallModel:
    def __init__(self, home_of: Callable[[str], Path], read: Callable[[Path], dict],
                 write: Callable[[Path, dict], None], backup: Callable[[str, Path], Any]) -> None:
        self._home_of = home_of
        self._read = read
        self._write = write
        self._backup = backup

    def _path(self, profile_id: str) -> Path:
        return Path(self._home_of(profile_id)) / "config.yaml"

    def get(self, profile_id: str) -> dict:
        """``{model, provider}`` when one is set; ``{}`` when calls use the agent's main model."""
        cfg = self._read(self._path(profile_id)) or {}
        aux = cfg.get("auxiliary") if isinstance(cfg.get("auxiliary"), dict) else {}
        slot = aux.get("voice_chat") if isinstance(aux.get("voice_chat"), dict) else {}
        model = str(slot.get("model") or "").strip()
        return {"model": model, "provider": str(slot.get("provider") or "main")} if model else {}

    def set(self, profile_id: str, model: Any, provider: Any = None) -> dict:
        model = str(model or "").strip()
        provider = str(provider or "main").strip().lower()
        if len(model) > 200 or not all(c.isalnum() or c in "-_./:@" for c in model):
            raise CallModelError("INVALID_REQUEST", "That isn't a model name")
        path = self._path(profile_id)
        cfg = self._read(path) or {}
        aux = dict(cfg.get("auxiliary") or {}) if isinstance(cfg.get("auxiliary"), dict) else {}
        if model:
            wanted = {**(aux.get("voice_chat") if isinstance(aux.get("voice_chat"), dict) else {}),
                      "provider": provider, "model": model}
        else:
            wanted = None
        if (aux.get("voice_chat") or None) == wanted:
            return self.get(profile_id)
        self._backup(profile_id, path)
        if wanted is None:
            aux.pop("voice_chat", None)
        else:
            aux["voice_chat"] = wanted
        cfg = dict(cfg)
        if aux:
            cfg["auxiliary"] = aux
        else:
            cfg.pop("auxiliary", None)
        self._write(path, cfg)
        log.info("Lekora: %s's call model is now %s (config backed up first)", profile_id, model or "its main model")
        return self.get(profile_id)
