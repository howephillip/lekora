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
- ``TOOL_PROGRESS``: tool-activity bubbles ("⚙️ tool_search: \"…\""). Lekora registers
  ``tool_progress: off``, but an agent's own ``display.tool_progress`` setting outranks a
  platform default in Hermes, so some agents still send them. Dropped: the thinking
  line already shows the same activity live, from Hermes' status text.
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
TOOL_PROGRESS = "tool_progress"

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
    # Replies to a message sent while the agent is busy ("{head}{detail}{tail}").
    "gateway.busy.redirected_head": (NOTICE, "↪ Redirected current run"),
    "gateway.busy.steered_head": (NOTICE, "⏩ Steered into current run"),
    "gateway.busy.steered_subagents_head": (NOTICE, "⏩ Steered into current run and its active subagent(s)"),
    "gateway.busy.queued_head": (NOTICE, "⏳ Queued for the next turn"),
    "gateway.busy.interrupting_head": (NOTICE, "⚡ Interrupting current task"),
    "gateway.busy.subagent_working_head": (NOTICE, "⏳ Subagent working"),
    "gateway.busy.compressing_head": (NOTICE, "⏳ Compressing context"),
    "gateway.busy.draining_maintenance": (NOTICE, "⏳ This agent is draining for a maintenance action"),
    "gateway.busy.another_turn_running": (NOTICE, "⏳ Another turn is still running on this session."),
}

# Hermes' tool-activity lines (gateway.progress.tool_preview / tool_pending / tool_verbose,
# the "{emoji} {Verb}ing …" form, and thinking_prefix "💬 …"). Each line starts with an emoji.
_EMOJI = r"[^\w\s\"'`*_#>\-\[(]{1,4}"
_TOOL = r"[a-z][a-z0-9_.\-]*"
# The tool name in each form is captured so it can be checked (see _real_tool).
_TOOL_FORMS = (
    re.compile(rf"^{_EMOJI}\s+({_TOOL}): \".*\"$"),   # ⚙️ tool_search: "Searching tools · …"
    re.compile(rf"^{_EMOJI}\s+({_TOOL})\.\.\.$"),      # ⚙️ terminal...
    re.compile(rf"^{_EMOJI}\s+({_TOOL})\(.*\)$"),      # ⚙️ terminal(command, cwd)   (verbose head)
)
_VERB_LINE = re.compile(rf"^{_EMOJI}\s+[A-Z][a-z]+ing\b.*$")   # 🔍 Searching the web for …
_THINKING_LINE = re.compile(r"^💬 .+$")


def _hermes_tool_names() -> Optional[set[str]]:
    try:
        from tools.registry import registry  # Hermes internal; absent outside Hermes
        return set(registry.get_all_tool_names())
    except Exception:
        return None


def _real_tool(name: str) -> bool:
    """A tool Hermes knows; without Hermes, something shaped like one (has "_" or ".")."""
    known = _hermes_tool_names()
    if known:
        return name in known
    return "_" in name or "." in name


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


_VS16 = "\uFE0F"  # "show as emoji" marker: "↪" and "↪️" are the same notice


def _plain(text: str) -> str:
    return (text or "").replace(_VS16, "")


def _pattern(template: str) -> re.Pattern:
    """Template text as a prefix pattern: placeholders match anything; extra trailing
    detail (e.g. " — `cd …` (7m 19s)") is allowed."""
    parts = re.split(r"\{[a-zA-Z_]+\}", _plain(template).strip())
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


def _tool_line(line: str) -> bool:
    for form in _TOOL_FORMS:
        m = form.match(line)
        if m and _real_tool(m.group(1)):
            return True
    return False


def _is_tool_progress(text: str) -> bool:
    lines = [line.strip() for line in _plain(text).splitlines() if line.strip()]
    if not lines:
        return False
    # Every line must be activity, and at least one must name a real tool the Hermes way
    # (not just "🔍 Searching…"), so an agent's own short emoji sentence is never hidden.
    named = [line for line in lines if _tool_line(line)]
    return bool(named) and all(
        line in named or _VERB_LINE.match(line) or _THINKING_LINE.match(line) for line in lines)


def classify(text: str) -> Optional[str]:
    plain = _plain(text)
    for kind, pattern in _patterns():
        if pattern.match(plain):
            return kind
    if _is_tool_progress(plain):
        return TOOL_PROGRESS
    return None
