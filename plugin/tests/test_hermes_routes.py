import os
import sys
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from typing import Optional

import pytest

from lekora.hermes_routes import ROUTE_PREFIX, ProfileRouter, check_routed


@dataclass(frozen=True)
class FakeRoute:
    """Same shape as Hermes' gateway.profile_routing.ProfileRoute."""
    name: str
    platform: str
    profile: str
    chat_id: Optional[str] = None

    @property
    def specificity(self) -> int:
        return 4 * bool(self.chat_id)

    def matches(self, platform, chat_id=None, **_):
        return self.platform == platform and self.chat_id in (None, chat_id)


def runner(multiplex=True, routes=None):
    return SimpleNamespace(config=SimpleNamespace(
        multiplex_profiles=multiplex, profile_routes=[] if routes is None else routes))


def profiles(*ids):
    return [{"profile_id": p, "name": p.title(), "avatar": "sparkles"} for p in ids]


def make_router(r):
    return ProfileRouter(lambda: r, "lekora", route_factory=FakeRoute)


def lekora_routes(r):
    return [(x.name, x.chat_id, x.profile) for x in r.config.profile_routes if x.name.startswith(ROUTE_PREFIX)]


def test_installs_one_route_per_named_profile():
    r = runner()
    assert make_router(r).offered(profiles("default", "bruce", "work")) == profiles("default", "bruce", "work")
    assert lekora_routes(r) == [("lekora-auto-bruce", "bruce", "bruce"), ("lekora-auto-work", "work", "work")]


def test_default_only_needs_no_routes_and_no_gateway():
    router = ProfileRouter(lambda: None, "lekora", route_factory=FakeRoute)
    assert router.offered(profiles("default")) == profiles("default")


def test_keeps_users_own_routes_and_updates_ours_when_profiles_change():
    theirs = FakeRoute(name="telegram-family", platform="telegram", profile="family", chat_id="42")
    r = runner(routes=[theirs])
    router = make_router(r)
    router.offered(profiles("default", "bruce", "work"))
    router.offered(profiles("default", "work"))  # bruce deleted in Hermes
    assert r.config.profile_routes[0] is theirs
    assert lekora_routes(r) == [("lekora-auto-work", "work", "work")]


def test_unchanged_profiles_leave_the_route_list_alone():
    r = runner()
    router = make_router(r)
    router.offered(profiles("default", "bruce"))
    before = r.config.profile_routes
    router.offered(profiles("default", "bruce"))
    assert r.config.profile_routes is before


@pytest.mark.parametrize("bad_runner", [
    None,                                                           # no gateway
    runner(multiplex=False),                                        # not multiplexing
    SimpleNamespace(config=SimpleNamespace(multiplex_profiles=True, profile_routes=())),  # changed shape
])
def test_falls_back_to_default_only(bad_runner, caplog):
    router = ProfileRouter(lambda: bad_runner, "lekora", route_factory=FakeRoute)
    assert router.offered(profiles("default", "bruce")) == profiles("default")
    assert "only the default agent" in caplog.text


def test_incompatible_route_class_falls_back(caplog):
    def broken_factory(**kwargs):
        raise TypeError("unexpected keyword 'chat_id'")
    router = ProfileRouter(lambda: runner(), "lekora", route_factory=broken_factory)
    assert router.offered(profiles("default", "bruce")) == profiles("default")
    assert "not compatible" in caplog.text


def test_problem_is_logged_once_not_per_message(caplog):
    router = ProfileRouter(lambda: None, "lekora", route_factory=FakeRoute)
    for _ in range(3):
        router.offered(profiles("default", "bruce"))
    assert caplog.text.count("only the default agent") == 1


def test_check_routed_accepts_only_the_intended_profile():
    check_routed(SimpleNamespace(profile="bruce"), "bruce")
    check_routed(SimpleNamespace(profile=None), "default")
    check_routed(SimpleNamespace(profile="default"), "default")
    with pytest.raises(RuntimeError, match="not delivering"):
        check_routed(SimpleNamespace(profile=None), "bruce")   # would have run as default
    with pytest.raises(RuntimeError, match="not delivering"):
        check_routed(SimpleNamespace(profile="work"), "bruce")
    with pytest.raises(RuntimeError, match="not serving"):
        check_routed(SimpleNamespace(profile=None, profile_route_rejected=True), "bruce")


# ---- against Hermes' real route code, when a Hermes source tree is available ----

HERMES_SRC = Path(os.environ.get("LEKORA_HERMES_SOURCE", Path.home() / ".hermes" / "hermes-agent"))


@pytest.fixture
def hermes_routing():
    if not (HERMES_SRC / "gateway" / "profile_routing.py").is_file():
        pytest.skip("Hermes source not available")
    sys.path.insert(0, str(HERMES_SRC))
    try:
        from gateway.profile_routing import ProfileRoute, match_profile_route
    except Exception as exc:
        pytest.skip(f"Hermes routing code not importable here: {exc}")
    finally:
        sys.path.remove(str(HERMES_SRC))
    return ProfileRoute, match_profile_route


def test_real_hermes_matcher_routes_each_chat_to_its_profile(hermes_routing):
    ProfileRoute, match_profile_route = hermes_routing
    r = runner()
    ProfileRouter(lambda: r, "lekora", route_factory=ProfileRoute).offered(
        profiles("default", "bruce", "work"))
    routes = r.config.profile_routes

    def resolve(chat_id):
        # How Hermes resolves a chat from the default-owned Lekora adapter (adapter_profile=None).
        hit = match_profile_route(routes, platform="lekora", chat_id=chat_id, adapter_profile=None)
        return hit.profile if hit else None

    assert resolve("bruce") == "bruce"
    assert resolve("work") == "work"
    assert resolve("default") is None          # default owns the adapter: no route needed
    assert match_profile_route(routes, platform="telegram", chat_id="bruce", adapter_profile=None) is None
