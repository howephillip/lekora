"""Tell Hermes' own notices apart from what an agent says.

Hermes sends lifecycle and status notices ("Hermes is restarting…", "Gateway
online…", "✅ Background task finished…", "⏳ Working — 12 min…") through the same
``send`` as agent replies. It marks them as non-conversational only for Discord;
for Lekora they carry the same marker as genuine agent commentary. So notices are
recognised by Hermes' own message templates, read from its translation catalogue
(in the user's language), with the English templates below as a fallback.

- ``NOTICE``: saved, shown on the phone as a small system line (role "system").
- ``HEARTBEAT``: the periodic "Working — N min" bubble; dropped, because the phone's
  thinking line already shows that the agent is working and for how long.
- ``None``: an agent message.
"""

from __future__ import annotations

import logging
import re
from functools import lru_cache
from typing import Optional

log = logging.getLogger(__name__)

NOTICE = "notice"
HEARTBEAT = "heartbeat"

# Hermes catalogue keys (locales/*.yaml) -> kind, with Hermes 0.22.5's English text.
_TEMPLATES: dict[str, tuple[str, str]] = {
    "gateway.progress.working_heartbeat": (HEARTBEAT, "⏳ Working — {minutes} min{detail}"),
    "gateway.startup.online": (NOTICE, "♻️ Gateway online — Hermes is back and ready."),
    "gateway.startup.restarted": (NOTICE, "♻ Gateway restarted successfully. Your session continues."),
    "gateway.shutdown.notice_restart": (NOTICE, "⚠️ Hermes is restarting — your current task will be "
                                                "interrupted. Send any message after the restart and I'll "
                                                "try to resume where you left off."),
    "gateway.shutdown.notice_shutdown": (NOTICE, "⚠️ Hermes is shutting down — your current task will be "
                                                 "interrupted. When it is back online, send any message "
                                                 "and I'll try to pick up where we left off."),
    "gateway.background.task_finished": (NOTICE, "✅ Background task finished"),
    "gateway.background.task_failed": (NOTICE, "❌ Background task failed"),
    "gateway.background.started": (NOTICE, "🔄 Background task started: \"{preview}\""),
    "gateway.background.stuck_warning": (NOTICE, "⚠️ I seem to be stuck (no activity for {minutes} min)."),
    "gateway.background.timeout_header": (NOTICE, "⏱️ Agent inactive for {minutes} min"),
}


def _hermes_template(key: str) -> Optional[str]:
    """The template in the user's language, from Hermes (internal API; may be absent)."""
    try:
        from agent.i18n import t
    except Exception:
        return None
    try:
        value = t(key)  # no format arguments: Hermes returns the raw template
    except Exception:
        return None
    return value if isinstance(value, str) and value and value != key else None


def _pattern(template: str) -> re.Pattern:
    """Template text as a prefix pattern: placeholders match anything; extra trailing
    detail (e.g. " — `cd …` (7m 19s)") is allowed."""
    parts = re.split(r"\{[a-zA-Z_]+\}", template.strip())
    body = ".*?".join(re.escape(p) for p in parts)
    return re.compile(r"\s*" + body, re.DOTALL)


@lru_cache(maxsize=1)
def _patterns() -> tuple[tuple[str, re.Pattern], ...]:
    found: list[tuple[str, re.Pattern]] = []
    for key, (kind, english) in _TEMPLATES.items():
        for template in {english, _hermes_template(key) or english}:
            # Only the first line: long notices are matched by their opening sentence.
            first = template.split("\n", 1)[0]
            found.append((kind, _pattern(first)))
    return tuple(found)


def classify(text: str) -> Optional[str]:
    for kind, pattern in _patterns():
        if pattern.match(text or ""):
            return kind
    return None
