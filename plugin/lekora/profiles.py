"""Discover the Hermes profiles (agents) on this machine, for the phone's agent list.

One Hermes gateway serves every profile ("multiplexing"), so the Lekora adapter can
reach all of them. A profile is a home directory: ``default`` is the Hermes root
(``~/.hermes``); named profiles live in ``<root>/profiles/<name>``.

Uses only Hermes' public plugin surface (``hermes_constants``), with plain
equivalents so this also works (and is testable) without Hermes installed.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Optional

log = logging.getLogger(__name__)

DEFAULT_PROFILE_ID = "default"
DEFAULT_AVATAR = "sparkles"
_PARKED_MARKER = "gateway.parked"            # `hermes -p X gateway stop`: not served
_IDENTITY_MARKERS = ("config.yaml", ".env", "SOUL.md", "profile.yaml", "auth.json", "state.db")
_PROFILE_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")

try:  # inside Hermes
    from hermes_constants import PROFILE_ID_RE as _HERMES_ID_RE
    from hermes_constants import get_default_hermes_root as _hermes_root
    from hermes_constants import named_profile_is_live as _hermes_is_live
except Exception:  # pragma: no cover - exercised only without Hermes
    _HERMES_ID_RE = None
    _hermes_root = None
    _hermes_is_live = None


def hermes_root() -> Path:
    if _hermes_root is not None:
        try:
            return Path(_hermes_root())
        except Exception as exc:
            log.warning("Lekora: could not resolve the Hermes root: %s", exc)
    return Path.home() / ".hermes"


def _valid_id(name: str) -> bool:
    return bool((_HERMES_ID_RE or _PROFILE_ID_RE).match(name))


def _is_live(home: Path) -> bool:
    if _hermes_is_live is not None:
        try:
            return bool(_hermes_is_live(home))
        except Exception:
            pass
    deleted = home.parent / ".deleted" / home.name
    return home.is_dir() and any((home / m).exists() for m in _IDENTITY_MARKERS) and not deleted.exists()


def _read_meta(home: Path) -> dict[str, str]:
    """``display_name`` and ``description`` from ``profile.yaml``; empty when missing or unreadable."""
    path = home / "profile.yaml"
    if not path.is_file():
        return {}
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return {}
    data: dict = {}
    try:
        import yaml  # available inside Hermes
        loaded = yaml.safe_load(text)
        data = loaded if isinstance(loaded, dict) else {}
    except Exception:
        # Minimal fallback: top-level `key: value` lines.
        for line in text.splitlines():
            m = re.match(r"^(display_name|description):\s*(.*?)\s*$", line)
            if m:
                data[m.group(1)] = m.group(2).strip("'\"")
    return {k: str(data.get(k) or "").strip() for k in ("display_name", "description")}


def readable_name(profile_id: str) -> str:
    """'default' -> 'Default', 'work-bot' -> 'Work bot' (when no display name is set)."""
    words = profile_id.replace("-", " ").replace("_", " ").strip()
    return words[:1].upper() + words[1:] if words else profile_id


def _entry(profile_id: str, home: Path) -> dict:
    meta = _read_meta(home)
    entry = {
        "profile_id": profile_id,
        "name": meta.get("display_name") or readable_name(profile_id),
        "avatar": DEFAULT_AVATAR,
    }
    if meta.get("description"):
        entry["description"] = meta["description"]
    return entry


def discover_profiles(root: Optional[Path] = None) -> list[dict]:
    """``default`` first, then live named profiles alphabetically. Deleted (tombstoned)
    and parked profiles are left out because the gateway does not serve them."""
    root = Path(root) if root is not None else hermes_root()
    profiles = [_entry(DEFAULT_PROFILE_ID, root)]
    named_dir = root / "profiles"
    if named_dir.is_dir():
        for home in sorted(named_dir.iterdir(), key=lambda p: p.name):
            if (home.is_dir() and _valid_id(home.name) and _is_live(home)
                    and not (home / _PARKED_MARKER).exists()):
                profiles.append(_entry(home.name, home))
    return profiles
