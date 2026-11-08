"""Turn on Hermes' reply streaming for Lekora only, in memory.

Hermes streams only when its global ``streaming.enabled`` switch is on (default
off); a per-platform display setting can only turn it *off*. Editing the user's
Hermes config is not allowed (AGENTS.md rule 8), and asking the user to run a
command breaks rule 2. So Lekora registers a private marker as its own default
``streaming`` display value, and this module wraps the running gateway's
in-memory streaming config: ``enabled_for(marker)`` is True (unless the user set
``streaming.transport: off``); every other platform gets the user's real answer.
Nothing is written to Hermes' config.

Uses Hermes internals that are not official plugin API (``runner.config.streaming``
and its ``enabled_for``). If they are missing or change shape, ``install`` returns
False and logs why; replies then arrive whole, as before.
"""

from __future__ import annotations

import logging
from typing import Any, Optional

log = logging.getLogger(__name__)

STREAMING_MARK = "lekora-stream"


class LekoraOnlyStreaming:
    """Wraps Hermes' StreamingConfig; streaming is on only for Lekora's marker."""

    _lekora_wrapper = True

    def __init__(self, original: Any) -> None:
        object.__setattr__(self, "_original", original)

    def enabled_for(self, platform_override: Any) -> bool:
        if platform_override == STREAMING_MARK:
            return getattr(self._original, "transport", "auto") != "off"
        return self._original.enabled_for(platform_override)

    def __getattr__(self, name: str) -> Any:  # transport, cursor, edit_interval, ...
        return getattr(self._original, name)

    def __setattr__(self, name: str, value: Any) -> None:
        setattr(self._original, name, value)


_last_problem: Optional[str] = None


def _problem(reason: str) -> bool:
    global _last_problem
    if reason != _last_problem:
        log.warning("Lekora: replies won't stream (they arrive whole): %s", reason)
        _last_problem = reason
    return False


def install(runner: Any) -> bool:
    """Wrap the running gateway's streaming config. Safe to call repeatedly."""
    config = getattr(runner, "config", None)
    if config is None:
        return _problem("the Hermes gateway is not available to the plugin")
    current = getattr(config, "streaming", None)
    if current is None:
        try:
            from gateway.config import StreamingConfig
            current = StreamingConfig()
        except Exception as exc:
            return _problem(f"this Hermes version has no streaming config ({exc})")
    if getattr(current, "_lekora_wrapper", False):
        return True
    if not callable(getattr(current, "enabled_for", None)):
        return _problem("this Hermes version decides streaming differently (enabled_for)")
    try:
        config.streaming = LekoraOnlyStreaming(current)
    except Exception as exc:
        return _problem(f"could not switch streaming on for Lekora ({exc})")
    log.info("Lekora: replies stream to the phone (other platforms unchanged)")
    return True


def cursor_of(runner: Any) -> Optional[str]:
    return getattr(getattr(getattr(runner, "config", None), "streaming", None), "cursor", None)
