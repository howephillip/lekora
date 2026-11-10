"""OpenRouter's public model catalog and each model's hosts (spec: docs/model-picker.md).

Hermes' own picker shows a hand-picked OpenRouter list; this reads the whole public
catalog (only models that can call tools, which Hermes agents need) and, per model, the
companies that host it with their prices, uptime and quantization. Public, anonymous
endpoints: nothing about the user is sent. Cached: the catalog for an hour on disk next
to lekora.db, a model's hosts for ten minutes in memory.
"""

from __future__ import annotations

import json
import logging
import ssl
import threading
import time
import urllib.request
from pathlib import Path
from typing import Any, Callable, Optional

log = logging.getLogger(__name__)

API = "https://openrouter.ai/api/v1"
CATALOG_TTL = 3600
PROVIDERS_TTL = 86400  # where hosts are based and their policies change rarely
HOSTS_TTL = 600
Fetch = Callable[[str], Any]   # url -> parsed JSON


def _ssl_context() -> ssl.SSLContext:
    try:
        import certifi  # present inside Hermes (its HTTP clients use it)
        return ssl.create_default_context(cafile=certifi.where())
    except Exception:
        return ssl.create_default_context()


def http_json(url: str, timeout: float = 15) -> Any:
    request = urllib.request.Request(url, headers={"User-Agent": "Lekora (Hermes plugin)"})
    with urllib.request.urlopen(request, timeout=timeout, context=_ssl_context()) as response:
        return json.loads(response.read().decode("utf-8"))


def per_million(value: Any) -> Optional[float]:
    """OpenRouter's per-token USD string -> USD per million tokens (None if unknown)."""
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number < 0:  # OpenRouter uses -1 for "varies"
        return None
    return round(number * 1_000_000, 6)


def maker_of(model_id: str, name: str = "") -> tuple[str, str]:
    """('deepseek', 'DeepSeek') from 'deepseek/…' and 'DeepSeek: DeepSeek V4'."""
    slug = model_id.split("/", 1)[0] if "/" in model_id else model_id
    label = name.split(":", 1)[0].strip() if ":" in name else slug.replace("-", " ").title()
    return slug, label or slug


def parse_model(raw: dict) -> Optional[dict]:
    """One catalog entry, or None when it can't call tools (Hermes agents need tools)."""
    params = raw.get("supported_parameters") or []
    if not isinstance(params, list) or "tools" not in params:
        return None
    model_id = str(raw.get("id") or "")
    if not model_id:
        return None
    pricing = raw.get("pricing") or {}
    name = str(raw.get("name") or model_id)
    maker, maker_name = maker_of(model_id, name)
    inputs = (raw.get("architecture") or {}).get("input_modalities") or []
    prices = [per_million(pricing.get("prompt")), per_million(pricing.get("completion"))]
    return {
        "id": model_id,
        "name": name.split(":", 1)[1].strip() if ":" in name else name,
        "maker": maker,
        "maker_name": maker_name,
        "created": int(raw.get("created") or 0),
        "context": int(raw.get("context_length") or 0),
        "input": prices[0],
        "output": prices[1],
        "cache_read": per_million(pricing.get("input_cache_read")),
        "free": all(p == 0 for p in prices) or model_id.endswith(":free"),
        "reasoning": "reasoning" in params,
        "vision": "image" in inputs,
    }


def parse_host(raw: dict) -> Optional[dict]:
    """One company hosting a model, or None when it can't call tools there."""
    params = raw.get("supported_parameters") or []
    if isinstance(params, list) and params and "tools" not in params:
        return None
    pricing = raw.get("pricing") or {}
    tag = str(raw.get("tag") or "")
    if not tag:
        return None
    quant = raw.get("quantization")
    return {
        "name": str(raw.get("provider_name") or tag),
        "tag": tag,
        "input": per_million(pricing.get("prompt")),
        "output": per_million(pricing.get("completion")),
        "cache_read": per_million(pricing.get("input_cache_read")),
        "discount": float(pricing.get("discount") or 0),
        "context": int(raw.get("context_length") or 0),
        "max_output": int(raw.get("max_completion_tokens") or 0) or None,
        "quantization": None if quant in (None, "", "unknown") else str(quant),
        "uptime": raw.get("uptime_last_30m"),
        "status": raw.get("status", 0),
    }


class OpenRouterCatalog:
    def __init__(self, cache_dir: Optional[Path], fetch: Fetch = http_json,
                 clock: Callable[[], float] = time.time) -> None:
        self._cache_file = Path(cache_dir) / "openrouter_models.json" if cache_dir else None
        self._fetch = fetch
        self._clock = clock
        self._lock = threading.Lock()
        self._models: Optional[list[dict]] = None
        self._fetched_at = 0.0
        self._hosts: dict[str, tuple[float, dict]] = {}
        self._companies: Optional[dict[str, dict]] = None
        self._companies_at = 0.0

    def models(self) -> list[dict]:
        """Every tool-capable OpenRouter model (cached; a stale copy if OpenRouter is unreachable)."""
        with self._lock:
            if self._models is not None and self._clock() - self._fetched_at < CATALOG_TTL:
                return self._models
            if self._models is None:
                self._load_disk()
                if self._models is not None and self._clock() - self._fetched_at < CATALOG_TTL:
                    return self._models
            try:
                raw = self._fetch(f"{API}/models")
                models = [m for m in (parse_model(r) for r in (raw or {}).get("data") or []) if m]
                if models:
                    self._models, self._fetched_at = models, self._clock()
                    self._save_disk()
            except Exception as exc:
                log.warning("Lekora: OpenRouter's model list is unavailable: %s", exc)
            return self._models or []

    def find(self, model_id: str) -> Optional[dict]:
        return next((m for m in self.models() if m["id"] == model_id), None)

    def hosts(self, model_id: str) -> dict:
        """The companies hosting ``model_id`` (cheapest first): {model, hosts}."""
        with self._lock:
            cached = self._hosts.get(model_id)
            if cached and self._clock() - cached[0] < HOSTS_TTL:
                return cached[1]
        if "/" not in model_id:
            return {"model": model_id, "hosts": []}
        slug = model_id.split(":", 1)[0]
        raw = self._fetch(f"{API}/models/{slug}/endpoints")
        data = (raw or {}).get("data") or {}
        hosts = [h for h in (parse_host(e) for e in data.get("endpoints") or []) if h]
        companies = self.companies()
        for host in hosts:
            company = companies.get(host["tag"].split("/", 1)[0]) or {}
            host["country"] = company.get("headquarters")
            host["privacy_url"] = company.get("privacy_policy_url")
            host["terms_url"] = company.get("terms_of_service_url")
        # Cheapest overall (input + output), unknown prices last.
        hosts.sort(key=lambda h: (h["input"] is None or h["output"] is None, (h["input"] or 0) + (h["output"] or 0)))
        result = {"model": model_id, "hosts": hosts}
        with self._lock:
            self._hosts[model_id] = (self._clock(), result)
        return result

    def companies(self) -> dict[str, dict]:
        """OpenRouter's list of hosting companies by slug: where they're based, their policies."""
        with self._lock:
            if self._companies is not None and self._clock() - self._companies_at < PROVIDERS_TTL:
                return self._companies
        try:
            raw = self._fetch(f"{API}/providers")
            rows = (raw or {}).get("data") if isinstance(raw, dict) else raw
            companies = {str(r["slug"]): r for r in rows or [] if isinstance(r, dict) and r.get("slug")}
            with self._lock:
                self._companies, self._companies_at = companies, self._clock()
        except Exception as exc:
            log.debug("Lekora: OpenRouter's host list is unavailable: %s", exc)
        return self._companies or {}

    def _load_disk(self) -> None:
        if not self._cache_file or not self._cache_file.is_file():
            return
        try:
            saved = json.loads(self._cache_file.read_text(encoding="utf-8"))
            self._models, self._fetched_at = list(saved["models"]), float(saved["fetched_at"])
        except Exception:
            self._models = None

    def _save_disk(self) -> None:
        if not self._cache_file:
            return
        try:
            self._cache_file.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._cache_file.with_suffix(".tmp")
            tmp.write_text(json.dumps({"fetched_at": self._fetched_at, "models": self._models}), encoding="utf-8")
            tmp.replace(self._cache_file)
        except OSError as exc:
            log.debug("Lekora: could not cache OpenRouter's model list: %s", exc)
