"""Model picker details: OpenRouter's catalog, hosts and routing (docs/model-picker.md)."""

from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from lekora.models_service import ModelsService
from lekora.openrouter_catalog import OpenRouterCatalog, parse_host, parse_model, per_million
from lekora.routing_config import KEEP_BACKUPS, RoutingConfig, RoutingError, describe, routing_for
from tests.test_gateway import PROFILES, env, gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import drain, hello_rev

# Shapes as OpenRouter's public API returns them (trimmed).
MODELS = {"data": [
    {"id": "deepseek/deepseek-v4.1-flash-1017", "name": "DeepSeek: DeepSeek V4.1 Flash 1017", "created": 1792225624,
     "context_length": 1048576, "pricing": {"prompt": "0.00000008", "completion": "0.0000005", "input_cache_read": "0.000000008"},
     "architecture": {"input_modalities": ["text", "image"]},
     "supported_parameters": ["tools", "reasoning", "temperature"]},
    {"id": "meta-llama/llama-4-scout:free", "name": "Meta: Llama 4 Scout (free)", "created": 1790000000,
     "context_length": 131072, "pricing": {"prompt": "0", "completion": "0"},
     "architecture": {"input_modalities": ["text"]}, "supported_parameters": ["tools"]},
    {"id": "acme/no-tools", "name": "Acme: Chatty", "pricing": {"prompt": "0.000001", "completion": "0.000002"},
     "supported_parameters": ["temperature"]},
]}
HOSTS = {"data": {"id": "deepseek/deepseek-v4.1-flash-1017", "endpoints": [
    {"provider_name": "Together", "tag": "together", "pricing": {"prompt": "0.0000003", "completion": "0.0000012"},
     "context_length": 1048576, "quantization": "unknown", "uptime_last_30m": 100, "supported_parameters": ["tools"]},
    {"provider_name": "Wafer", "tag": "wafer/us", "pricing": {"prompt": "0.000000038", "completion": "0.0000005", "discount": 0},
     "context_length": 1048576, "quantization": "mxfp4", "uptime_last_30m": 99.7, "max_completion_tokens": 65536,
     "supported_parameters": ["tools", "reasoning"]},
    {"provider_name": "NoTools", "tag": "notools", "pricing": {"prompt": "0.00000001", "completion": "0.00000001"},
     "supported_parameters": ["temperature"]},
]}}


PROVIDERS = {"data": [
    {"name": "Wafer", "slug": "wafer", "headquarters": "US", "privacy_policy_url": "https://wafer.example/privacy",
     "terms_of_service_url": "https://wafer.example/terms"},
    {"name": "Together", "slug": "together", "headquarters": "US"},
]}


class FakeOpenRouter:
    def __init__(self):
        self.calls = []
        self.fail = False

    def __call__(self, url):
        self.calls.append(url)
        if self.fail:
            raise OSError("offline")
        if url.endswith("/providers"):
            return PROVIDERS
        return HOSTS if url.endswith("/endpoints") else MODELS


# ---- parsing --------------------------------------------------------------------

def test_prices_are_per_million_tokens():
    assert per_million("0.000003") == 3.0
    assert per_million("0") == 0.0
    assert per_million("-1") is None and per_million(None) is None


def test_only_tool_capable_models_with_prices_and_abilities():
    models = [m for m in (parse_model(r) for r in MODELS["data"]) if m]
    assert [m["id"] for m in models] == ["deepseek/deepseek-v4.1-flash-1017", "meta-llama/llama-4-scout:free"]
    assert models[0] == {"id": "deepseek/deepseek-v4.1-flash-1017", "name": "DeepSeek V4.1 Flash 1017",
                         "maker": "deepseek", "maker_name": "DeepSeek", "created": 1792225624, "context": 1048576,
                         "input": 0.08, "output": 0.5, "cache_read": 0.008, "free": False,
                         "reasoning": True, "vision": True}
    assert models[1]["free"] and models[1]["maker_name"] == "Meta"


def test_hosts_that_can_call_tools():
    hosts = [h for h in (parse_host(e) for e in HOSTS["data"]["endpoints"]) if h]
    assert [h["tag"] for h in hosts] == ["together", "wafer/us"]
    assert hosts[1]["quantization"] == "mxfp4" and hosts[0]["quantization"] is None
    assert hosts[1]["input"] == 0.038 and hosts[1]["uptime"] == 99.7 and hosts[1]["max_output"] == 65536


# ---- the catalog cache ------------------------------------------------------------

def test_catalog_is_cached_on_disk_and_refreshed_hourly(tmp_path):
    fetch, now = FakeOpenRouter(), [1000.0]
    catalog = OpenRouterCatalog(tmp_path, fetch, clock=lambda: now[0])
    assert len(catalog.models()) == 2 and len(fetch.calls) == 1
    catalog.models()
    assert len(fetch.calls) == 1, "cached"
    again = OpenRouterCatalog(tmp_path, fetch, clock=lambda: now[0] + 60)   # e.g. after a restart
    assert len(again.models()) == 2 and len(fetch.calls) == 1, "read from disk"
    now[0] += 3601
    catalog.models()
    assert len(fetch.calls) == 2, "refreshed after an hour"


def test_stale_catalog_when_openrouter_is_down(tmp_path):
    fetch, now = FakeOpenRouter(), [0.0]
    catalog = OpenRouterCatalog(tmp_path, fetch, clock=lambda: now[0])
    catalog.models()
    fetch.fail, now[0] = True, 10_000
    assert len(catalog.models()) == 2


def test_hosts_cheapest_first_and_cached(tmp_path):
    fetch = FakeOpenRouter()
    catalog = OpenRouterCatalog(None, fetch)
    result = catalog.hosts("deepseek/deepseek-v4.1-flash-1017")
    assert [h["name"] for h in result["hosts"]] == ["Wafer", "Together"]
    assert fetch.calls[0].endswith("/models/deepseek/deepseek-v4.1-flash-1017/endpoints")
    assert result["hosts"][0]["country"] == "US" and result["hosts"][0]["privacy_url"] == "https://wafer.example/privacy"
    calls = len(fetch.calls)
    catalog.hosts("deepseek/deepseek-v4.1-flash-1017")
    assert len(fetch.calls) == calls, "cached"
    catalog.hosts("meta-llama/llama-4-scout:free")
    assert any(c.endswith("/models/meta-llama/llama-4-scout/endpoints") for c in fetch.calls), ":free shares the base model's page"
    assert sum(c.endswith("/providers") for c in fetch.calls) == 1, "the company list is fetched once a day"


# ---- routing in Hermes' config ------------------------------------------------------

class FakeConfigFile:
    """Stands in for Hermes' raw config reader/writer, on a real file (for the backups)."""

    def __init__(self, path: Path, data: dict):
        self.path, self.data = path, data
        path.write_text("model: x\n# the user's comments\n")
        self.writes = 0

    def read(self, path):
        assert path == self.path
        return dict(self.data)

    def write(self, path, data):
        assert path == self.path
        self.data, self.writes = data, self.writes + 1
        path.write_text(f"written {self.writes}\n")


def test_routing_choices():
    assert routing_for("balanced") is None
    assert routing_for("cheapest") == {"sort": "price"}
    assert routing_for("fastest") == {"sort": "throughput"}
    assert routing_for("only", ["wafer/us"]) == {"only": ["wafer/us"]}
    assert routing_for("prefer", ["wafer/us", "together"]) == {"order": ["wafer/us", "together"]}
    assert routing_for("one", ["wafer/us", "together"]) == {"only": ["wafer/us"]}
    assert routing_for("balanced", no_training=True) == {"data_collection": "deny"}
    assert routing_for("one", ["wafer/us"], no_training=True) == {"only": ["wafer/us"], "data_collection": "deny"}
    with pytest.raises(RoutingError):
        routing_for("only", [])
    assert describe({"sort": "latency"}) == {"mode": "fastest", "hosts": [], "no_training": False}
    assert describe({"only": ["wafer/us"]}) == {"mode": "one", "hosts": ["wafer/us"], "no_training": False}
    assert describe({"data_collection": "deny"}) == {"mode": "balanced", "hosts": [], "no_training": True}
    assert describe({"order": ["a"], "data_collection": "deny"})["no_training"] is True
    assert describe({"require_parameters": True}) == {"mode": "custom", "hosts": [], "no_training": False}


def test_save_writes_only_that_models_entry_and_backs_up(tmp_path):
    cfg = FakeConfigFile(tmp_path / "config.yaml", {"model": {"default": "x"}, "provider_routing": {"sort": "price"}})
    routing = RoutingConfig(tmp_path / "backups", cfg.read, cfg.write)
    result = routing.save("bruce", cfg.path, "deepseek/v4", {"only": ["wafer/us"]})
    assert cfg.data == {"model": {"default": "x"},
                        "provider_routing": {"sort": "price", "models": {"deepseek/v4": {"only": ["wafer/us"]}}}}
    assert result["mode"] == "one" and result["hosts"] == ["wafer/us"]
    original = tmp_path / "backups" / "bruce" / "config.yaml.original"
    assert original.read_text() == "model: x\n# the user's comments\n", "the pre-Lekora file, kept"
    assert Path(result["backup"]).read_text() == "model: x\n# the user's comments\n"
    assert routing.current(cfg.path, "deepseek/v4") == {"mode": "one", "hosts": ["wafer/us"], "no_training": False}


def test_balanced_removes_the_entry_and_unchanged_writes_nothing(tmp_path):
    cfg = FakeConfigFile(tmp_path / "config.yaml",
                         {"provider_routing": {"models": {"deepseek/v4": {"sort": "price"}}}, "other": 1})
    routing = RoutingConfig(tmp_path / "backups", cfg.read, cfg.write)
    assert routing.save("bruce", cfg.path, "deepseek/v4", {"sort": "price"})["backup"] is None
    assert cfg.writes == 0
    routing.save("bruce", cfg.path, "deepseek/v4", None)
    assert cfg.data == {"other": 1}, "an emptied section is removed, nothing else touched"


def test_keeps_the_original_and_ten_newest_backups(tmp_path):
    cfg = FakeConfigFile(tmp_path / "config.yaml", {})
    start = datetime(2026, 11, 9, 12, 0, tzinfo=timezone.utc)
    tick = [0]

    def clock():
        tick[0] += 1
        return start + timedelta(minutes=tick[0])
    routing = RoutingConfig(tmp_path / "backups", cfg.read, cfg.write, clock=clock)
    for i in range(15):
        routing.save("bruce", cfg.path, "m", {"order": [f"h{i}"]})
    folder = tmp_path / "backups" / "bruce"
    dated = sorted(p.name for p in folder.glob("config.yaml.2*"))
    assert len(dated) == KEEP_BACKUPS and dated[-1] == "config.yaml.20261109-121500"
    assert (folder / "config.yaml.original").read_text().startswith("model: x")


# ---- the service and the gateway ------------------------------------------------------

@pytest.fixture
def models(tmp_path):
    homes = tmp_path / "hermes"
    (homes / "profiles" / "coder").mkdir(parents=True)
    cfg = FakeConfigFile(homes / "profiles" / "coder" / "config.yaml", {})
    service = ModelsService(OpenRouterCatalog(None, FakeOpenRouter()),
                            RoutingConfig(homes / "lekora-backups" / "config", cfg.read, cfg.write),
                            profile_home=lambda p: homes if p == "default" else homes / "profiles" / p,
                            model_info=lambda provider, model: {"input": 3.0, "output": 15.0, "context": 200000,
                                                                "reasoning": True, "vision": True, "tools": True}
                            if model == "claude-sonnet-5-5" else None)
    service.cfg = cfg
    return service


def test_routing_only_for_offered_hosts(models):
    with pytest.raises(RoutingError) as err:
        models.set_routing("coder", "deepseek/deepseek-v4.1-flash-1017", "only", ["nobody"])
    assert err.value.code == "INVALID_ROUTING"
    with pytest.raises(RoutingError):
        models.set_routing("coder", "acme/unknown", "cheapest")
    result = models.set_routing("coder", "deepseek/deepseek-v4.1-flash-1017", "prefer", ["wafer/us", "together"])
    assert result["mode"] == "prefer"
    assert models.cfg.data["provider_routing"]["models"]["deepseek/deepseek-v4.1-flash-1017"] == {"order": ["wafer/us", "together"]}


def test_other_providers_get_hermes_prices_where_known(models):
    result = models.catalog("anthropic", ["claude-sonnet-5-5", "claude-mystery"])
    assert result["models"][0]["input"] == 3.0 and result["models"][0]["context"] == 200000
    assert result["models"][1] == {"id": "claude-mystery", "name": "claude-mystery"}


async def test_gateway_model_requests(gw, store, models):
    gw.models = models
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=0)
    await recv(ws)
    await ws.send(env(store, "models.catalog", {"provider": "openrouter"}, profile_id="coder", msg_id="m1"))
    reply = await recv(ws)
    assert reply["type"] == "models.catalog.result" and reply["id"] == "m1"
    assert len(reply["data"]["models"]) == 2 and reply["data"]["complete"]
    await ws.send(env(store, "models.hosts", {"model": "deepseek/deepseek-v4.1-flash-1017"}, profile_id="coder", msg_id="m2"))
    hosts = await recv(ws)
    assert [h["tag"] for h in hosts["data"]["hosts"]] == ["wafer/us", "together"]
    assert hosts["data"]["routing"] == {"mode": "balanced", "hosts": [], "no_training": False}
    await ws.send(env(store, "models.routing.set", {"model": "deepseek/deepseek-v4.1-flash-1017", "mode": "cheapest"},
                      profile_id="coder", msg_id="m3"))
    saved = await recv(ws)
    assert saved["type"] == "models.routing.set.result" and saved["data"]["mode"] == "cheapest" and saved["data"]["backup"]
    await ws.send(env(store, "models.routing.set", {"model": "deepseek/deepseek-v4.1-flash-1017", "mode": "only", "hosts": []},
                      profile_id="coder", msg_id="m4"))
    assert (await recv(ws))["data"]["code"] == "INVALID_ROUTING"
    await ws.send(env(store, "models.routing.set", {"model": "deepseek/deepseek-v4.1-flash-1017", "mode": "one",
                                                     "hosts": ["wafer/us"], "no_training": True},
                      profile_id="coder", msg_id="m5"))
    one = await recv(ws)
    assert one["data"]["mode"] == "one" and one["data"]["no_training"] is True
    assert models.cfg.data["provider_routing"]["models"]["deepseek/deepseek-v4.1-flash-1017"] == {
        "only": ["wafer/us"], "data_collection": "deny"}
    await ws.close()


async def test_picking_any_openrouter_model_from_the_full_catalog(gw, store, models):
    from lekora.prompts import Prompts
    picked = []

    async def on_selected(chat, model, provider):
        picked.append(model)
        return "switched"
    prompts = Prompts(lambda: gw)
    prompts.knows_openrouter_model = models.knows_openrouter_model
    gw.prompts = prompts
    message_id = await prompts.ask_model("coder", "s", [{"slug": "openrouter", "name": "OpenRouter", "models": ["x/curated"]}],
                                         "x/curated", "openrouter", on_selected)
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    await recv(ws)
    card_id = message_id[len("card-"):]
    await ws.send(env(store, "prompt.respond", {"card_id": card_id, "model": "acme/no-tools", "provider": "openrouter"},
                      profile_id="coder", msg_id="p1"))
    assert (await recv(ws))["data"]["code"] == "INVALID_ANSWER", "not tool-capable, so not in the catalog"
    await ws.send(env(store, "prompt.respond", {"card_id": card_id, "model": "meta-llama/llama-4-scout:free",
                                                "provider": "openrouter"}, profile_id="coder", msg_id="p2"))
    await drain(ws)
    assert picked == ["meta-llama/llama-4-scout:free"]
    await ws.close()
