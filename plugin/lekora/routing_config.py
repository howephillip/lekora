"""Which companies OpenRouter may use for a model: Hermes' ``provider_routing`` setting.

The one place Lekora writes outside its own section of Hermes' config (AGENTS.md rule 8,
exception agreed with the owner on 2026-11-09). Only the entry
``provider_routing.models."<model id>"`` of the agent's own ``config.yaml`` is written,
and only when the user saves a routing choice for that model. Hermes re-reads it on every
request, so it applies from the next message.

Before every write the file is copied to ``<Hermes>/lekora-backups/config/<agent>/``:
the very first copy (``config.yaml.original``, from before Lekora ever changed it) is kept
forever, plus the ten newest dated copies. Writing goes through Hermes' own config writer
(keeps comments, refuses to drop other settings).
"""

from __future__ import annotations

import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Optional

KEEP_BACKUPS = 10
MODES = ("balanced", "cheapest", "fastest", "only", "prefer")

Read = Callable[[Path], dict]
Write = Callable[[Path, dict], None]


class RoutingError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


def hermes_read(path: Path) -> dict:
    from hermes_cli.config import read_user_config_raw
    return read_user_config_raw(path)


def hermes_write(path: Path, data: dict) -> None:
    # A full, deliberate state: removing a model's routing must really remove it.
    from hermes_cli.config import atomic_config_replace
    atomic_config_replace(path, data)


def routing_for(mode: str, hosts: Optional[list[str]] = None) -> Optional[dict]:
    """The setting for a choice in the app (None = OpenRouter's default balancing)."""
    if mode == "balanced":
        return None
    if mode == "cheapest":
        return {"sort": "price"}
    if mode == "fastest":
        return {"sort": "throughput"}
    if mode in ("only", "prefer"):
        if not hosts:
            raise RoutingError("INVALID_ROUTING", "Choose at least one company")
        return {"only": list(hosts)} if mode == "only" else {"order": list(hosts)}
    raise RoutingError("INVALID_ROUTING", "Unknown routing choice")


def describe(routing: Optional[dict]) -> dict:
    """The app's view of a saved setting: {mode, hosts}."""
    if not isinstance(routing, dict) or not routing:
        return {"mode": "balanced", "hosts": []}
    if routing.get("only"):
        return {"mode": "only", "hosts": list(routing["only"])}
    if routing.get("order"):
        return {"mode": "prefer", "hosts": list(routing["order"])}
    sort = routing.get("sort")
    if sort == "price":
        return {"mode": "cheapest", "hosts": []}
    if sort in ("throughput", "latency"):
        return {"mode": "fastest", "hosts": []}
    return {"mode": "custom", "hosts": []}  # set by hand in config.yaml: shown, not overwritten silently


class RoutingConfig:
    def __init__(self, backup_root: Path, read: Read = hermes_read, write: Write = hermes_write,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc)) -> None:
        self.backup_root = Path(backup_root)
        self._read, self._write, self._clock = read, write, clock

    def current(self, config_path: Path, model_id: str) -> dict:
        data = self._read(config_path) or {}
        models = ((data.get("provider_routing") or {}).get("models") or {})
        return describe(models.get(model_id))

    def save(self, profile_id: str, config_path: Path, model_id: str, routing: Optional[dict]) -> dict:
        """Write (or remove) the model's routing; returns {mode, hosts, backup}."""
        data = self._read(config_path) or {}
        section = data.get("provider_routing")
        section = dict(section) if isinstance(section, dict) else {}
        models = dict(section.get("models") or {})
        if (models.get(model_id) or None) == routing:
            return dict(describe(routing), backup=None)  # nothing to change
        backup = self.backup(profile_id, config_path)
        if routing is None:
            models.pop(model_id, None)
        else:
            models[model_id] = routing
        if models:
            section["models"] = models
        else:
            section.pop("models", None)
        updated = dict(data)
        if section:
            updated["provider_routing"] = section
        else:
            updated.pop("provider_routing", None)
        self._write(config_path, updated)
        return dict(describe(routing), backup=str(backup) if backup else None)

    def backup(self, profile_id: str, config_path: Path) -> Optional[Path]:
        """Copy config.yaml before a change; keep the original plus the newest ten."""
        if not Path(config_path).is_file():
            return None
        folder = self.backup_root / profile_id
        folder.mkdir(parents=True, exist_ok=True)
        original = folder / "config.yaml.original"
        if not original.exists():
            shutil.copy2(config_path, original)
        stamp = self._clock().strftime("%Y%m%d-%H%M%S")
        target = folder / f"config.yaml.{stamp}"
        n = 1
        while target.exists():
            n += 1
            target = folder / f"config.yaml.{stamp}-{n}"
        shutil.copy2(config_path, target)
        dated = sorted(p for p in folder.glob("config.yaml.2*"))
        for old in dated[:-KEEP_BACKUPS]:
            old.unlink(missing_ok=True)
        return target
