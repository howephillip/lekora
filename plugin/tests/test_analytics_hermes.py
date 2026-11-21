"""Analytics against Hermes' real session store (docs/analytics.md), in a throwaway Hermes home."""

import time

import pytest

pytest.importorskip("hermes_state")

from lekora.hermes_analytics import read_usage  # noqa: E402


def test_reading_an_agents_usage_from_hermes_own_store(tmp_path, monkeypatch):
    from hermes_state import SessionDB
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s1", source="lekora", model="openrouter/anthropic/claude-x")
    db.update_token_counts("s1", input_tokens=1000, output_tokens=200, model="anthropic/claude-x",
                           estimated_cost_usd=0.05, billing_provider="openrouter")
    db.create_session("s2", source="cron", model="x")
    db.update_token_counts("s2", input_tokens=100, output_tokens=10, model="anthropic/claude-x",
                           estimated_cost_usd=0.01, billing_provider="openrouter")
    db.record_auxiliary_usage("s1", "title_generation", model="cheap/model", input_tokens=40, output_tokens=5,
                              estimated_cost_usd=0.001, billing_provider="openrouter")
    db.flush_token_counts() if hasattr(db, "flush_token_counts") else None
    db.close()

    got = read_usage(tmp_path, time.time() - 3600)
    by_source = {r["source"]: r for r in got["main"]}
    assert by_source["lekora"]["tokens"] == 1200 and abs(by_source["lekora"]["cost_usd"] - 0.05) < 1e-9
    assert by_source["cron"]["sessions"] == 1
    assert abs(got["background"][0]["cost_usd"] - 0.001) < 1e-9
    models = {(r["model"], r["provider"]) for r in got["models"]}
    assert ("anthropic/claude-x", "openrouter") in models and ("cheap/model", "openrouter") in models
    assert read_usage(tmp_path, time.time() + 3600)["main"] == []
