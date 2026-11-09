"""The slash commands an agent can use, from Hermes' own sources (spec: docs/slash-commands.md).

The same sources Hermes' Telegram and Discord menus use: the command registry
(``hermes_cli.commands``, filtered to what the gateway offers), plugin commands and
skill commands (``_collect_gateway_skill_entries``), plus the user's ``quick_commands``.
Read inside the agent's own Hermes home, because skills, plugins and settings differ
per profile. Hermes internals, so every source is optional: a part that fails is left
out and logged, never breaking the rest.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

PLATFORM = "lekora"
DESC_LIMIT = 200


def list_commands(profile_home: Path) -> list[dict[str, Any]]:
    """Commands for the profile at ``profile_home``. Does disk I/O: call off the event loop."""
    from hermes_constants import reset_hermes_home_override, set_hermes_home_override

    token = set_hermes_home_override(str(profile_home))
    try:
        return collect()
    finally:
        reset_hermes_home_override(token)


def collect() -> list[dict[str, Any]]:
    commands: list[dict[str, Any]] = []
    taken: set[str] = set()
    for part in (_builtin, _plugins_and_skills, _quick):
        try:
            for entry in part(taken):
                if entry["name"] not in taken:
                    taken.add(entry["name"])
                    taken.update(entry.get("aliases") or [])
                    commands.append(entry)
        except Exception as exc:  # a Hermes change in one source must not hide the others
            log.warning("Lekora: could not list %s commands: %s", part.__name__.strip("_"), exc)
    return commands


def _builtin(taken: set[str]):
    from hermes_cli.commands import SUBCOMMANDS, category_label
    from hermes_cli.commands_platforms import _gateway_available_commands

    for cmd in _gateway_available_commands():
        yield {
            "name": cmd.name,
            "description": _text(cmd.describe() if hasattr(cmd, "describe") else cmd.description),
            "args": cmd.args_hint or "",
            "choices": list(SUBCOMMANDS.get("/" + cmd.name, [])),
            "aliases": list(cmd.aliases),
            "group": "hermes",
            "category": category_label(cmd.category) if cmd.category else "",
        }


def _plugins_and_skills(taken: set[str]):
    from hermes_cli.commands_platforms import _collect_gateway_skill_entries

    try:
        from hermes_cli.plugins import get_plugin_commands
        plugin_meta = get_plugin_commands()
    except Exception:
        plugin_meta = {}
    entries, _hidden = _collect_gateway_skill_entries(PLATFORM, None, set(taken), desc_limit=DESC_LIMIT)
    for name, description, cmd_key, _raw in entries:
        is_skill = bool(cmd_key)
        meta = {} if is_skill else (plugin_meta.get(name) or {})
        yield {
            "name": name,
            "description": _text(description),
            "args": str(meta.get("args_hint") or ""),
            "choices": [],
            "aliases": [],
            "group": "skill" if is_skill else "plugin",
            "category": "Skills" if is_skill else "Plugins",
        }


def _quick(taken: set[str]):
    from hermes_cli.config import read_raw_config

    quick = (read_raw_config() or {}).get("quick_commands") or {}
    if not isinstance(quick, dict):
        return
    for name, spec in sorted(quick.items()):
        if not isinstance(spec, dict):
            continue
        description = spec.get("description") or (
            f"Runs: {spec.get('command')}" if spec.get("type") == "exec" else f"Same as {spec.get('target')}")
        yield {"name": str(name), "description": _text(description), "args": "", "choices": [],
               "aliases": [], "group": "quick", "category": "Your commands"}


def _text(value: Any) -> str:
    text = " ".join(str(value or "").split())
    return text if len(text) <= DESC_LIMIT else text[: DESC_LIMIT - 1] + "…"
