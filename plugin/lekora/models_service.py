"""Model details for the phone's model picker (spec: docs/model-picker.md).

- ``catalog(provider, model_ids)``: OpenRouter's whole tool-capable catalog with prices and
  capabilities; for other providers, prices/capabilities of the given models from Hermes'
  own price table (models.dev) where Hermes has them.
- ``hosts(profile, model)``: the companies hosting an OpenRouter model, plus the agent's
  current routing choice for it.
- ``set_routing(profile, model, mode, hosts)``: save that choice (routing_config.py).
Blocking (network, disk): the gateway calls these in a thread.
"""

from __future__ import annotations

import logging
from pathlib import Path
from typing import Any, Callable, Optional

from .openrouter_catalog import OpenRouterCatalog
from .routing_config import RoutingConfig, RoutingError, routing_for

log = logging.getLogger(__name__)

OPENROUTER = "openrouter"
ModelInfo = Callable[[str, str], Optional[dict]]


def hermes_model_info(provider: str, model: str) -> Optional[dict]:
    """Prices (USD per million tokens) and abilities from Hermes' models.dev table, if known."""
    from agent.models_dev import get_model_info
    info = get_model_info(provider, model)
    if info is None:
        return None
    priced = (getattr(info, "cost_input", 0) or 0) > 0 or (getattr(info, "cost_output", 0) or 0) > 0
    return {
        # models.dev uses 0 for "unknown": only show prices it actually has.
        "input": getattr(info, "cost_input", None) if priced else None,
        "output": getattr(info, "cost_output", None) if priced else None,
        "context": int(getattr(info, "context_window", 0) or 0),
        "reasoning": bool(getattr(info, "reasoning", False)),
        "vision": bool(getattr(info, "attachment", False)),
        "tools": bool(getattr(info, "tool_call", True)),
    }


class ModelsService:
    def __init__(self, catalog: OpenRouterCatalog, routing: RoutingConfig,
                 profile_home: Callable[[str], Path], model_info: ModelInfo = hermes_model_info) -> None:
        self.openrouter = catalog
        self.routing = routing
        self._profile_home = profile_home
        self._model_info = model_info

    def catalog(self, provider: str, model_ids: Optional[list[str]] = None) -> dict:
        if provider == OPENROUTER:
            return {"provider": provider, "models": self.openrouter.models(), "complete": True}
        models = []
        for model_id in model_ids or []:
            try:
                info = self._model_info(provider, model_id)
            except Exception:
                info = None
            entry: dict[str, Any] = {"id": model_id, "name": model_id}
            if info:
                entry.update(info)
            models.append(entry)
        return {"provider": provider, "models": models, "complete": False}

    def knows_openrouter_model(self, model_id: str) -> bool:
        return self.openrouter.find(model_id) is not None

    def hosts(self, profile_id: str, model_id: str) -> dict:
        result = dict(self.openrouter.hosts(model_id))
        result["routing"] = self.routing.current(self._config(profile_id), model_id)
        return result

    def set_routing(self, profile_id: str, model_id: str, mode: str, hosts: Optional[list[str]] = None,
                    no_training: bool = False) -> dict:
        if not self.knows_openrouter_model(model_id):
            raise RoutingError("UNKNOWN_MODEL", "That isn't an OpenRouter model")
        chosen = list(dict.fromkeys(hosts or []))
        if chosen:
            offered = {h["tag"] for h in self.openrouter.hosts(model_id)["hosts"]}
            unknown = [h for h in chosen if h not in offered]
            if unknown:
                raise RoutingError("INVALID_ROUTING", f"Not hosting this model: {', '.join(unknown)}")
        setting = routing_for(mode, chosen, no_training)
        return self.routing.save(profile_id, self._config(profile_id), model_id, setting)

    def _config(self, profile_id: str) -> Path:
        return Path(self._profile_home(profile_id)) / "config.yaml"
