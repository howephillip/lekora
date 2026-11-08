"""Route each Lekora chat to its Hermes profile, in memory.

Hermes' multiplexing gateway only runs a message as a named profile when its own
trusted routing table (``runner.config.profile_routes``) says so; a profile name
stamped by an adapter is refused ("profile_mismatch") by design. So the single
Lekora adapter installs one route per named profile, ``lekora chat <name> ->
profile <name>``, into the RUNNING gateway's in-memory table. Nothing is written
to the user's Hermes config, and the table is refreshed whenever the profile
list is read (every phone connect and message), so new profiles work without a
restart. ``default`` needs no route: it owns the adapter.

This uses Hermes internals that are not official plugin API
(``gateway.profile_routing.ProfileRoute`` and ``runner.config.profile_routes``).
If they are missing or change shape, ``sync`` reports routing as unavailable and
the phone is offered only the default agent, with a log message saying why.
"""

from __future__ import annotations

import logging
from typing import Any, Callable, Iterable, Optional

log = logging.getLogger(__name__)

DEFAULT_PROFILE_ID = "default"
ROUTE_PREFIX = "lekora-auto-"


def _hermes_route_factory() -> Callable[..., Any]:
    from gateway.profile_routing import ProfileRoute  # Hermes internal (see module docstring)
    return ProfileRoute


class ProfileRouter:
    def __init__(self, runner: Callable[[], Any], platform: str,
                 route_factory: Optional[Callable[..., Any]] = None) -> None:
        self._runner = runner
        self._platform = platform
        self._route_factory = route_factory
        self._last_problem: Optional[str] = None

    def _problem(self, reason: str) -> bool:
        if reason != self._last_problem:  # log each distinct problem once, not per message
            log.warning("Lekora: only the default agent is available on the phone: %s", reason)
            self._last_problem = reason
        return False

    def sync(self, profile_ids: Iterable[str]) -> bool:
        """Make sure every named profile in ``profile_ids`` has a Lekora route.
        Returns False when routing to named profiles is not possible."""
        named = [p for p in profile_ids if p != DEFAULT_PROFILE_ID]
        if not named:
            self._last_problem = None
            return True
        runner = self._runner()
        config = getattr(runner, "config", None)
        if config is None:
            return self._problem("the Hermes gateway is not available to the plugin")
        if not getattr(config, "multiplex_profiles", False):
            return self._problem("Hermes is not serving several profiles from one gateway (multiplexing is off)")
        routes = getattr(config, "profile_routes", None)
        if not isinstance(routes, list):
            return self._problem("this Hermes version keeps profile routes differently (profile_routes)")
        try:
            factory = self._route_factory or _hermes_route_factory()
            desired = [factory(name=f"{ROUTE_PREFIX}{p}", platform=self._platform, chat_id=p, profile=p)
                       for p in named]
            for route in desired:  # self-check: the shape Hermes' matcher relies on
                if not (callable(getattr(route, "matches", None)) and hasattr(route, "specificity")):
                    raise TypeError("ProfileRoute has an unexpected shape")
        except Exception as exc:
            return self._problem(f"this Hermes version's profile routes are not compatible ({exc})")

        def key(route: Any) -> tuple:
            return getattr(route, "name", None), getattr(route, "chat_id", None), getattr(route, "profile", None)

        ours = [r for r in routes if str(getattr(r, "name", "")).startswith(ROUTE_PREFIX)]
        if [key(r) for r in ours] != [key(r) for r in desired]:
            others = [r for r in routes if not str(getattr(r, "name", "")).startswith(ROUTE_PREFIX)]
            config.profile_routes = others + desired  # swap in a new list; Hermes reads it live
            log.info("Lekora: routing phone chats to profiles: %s", ", ".join(named))
        self._last_problem = None
        return True

    def offered(self, profiles: list[dict]) -> list[dict]:
        """The profiles the phone may use: all of them when routing works, else default only."""
        if self.sync(p["profile_id"] for p in profiles):
            return profiles
        return [p for p in profiles if p["profile_id"] == DEFAULT_PROFILE_ID]


def check_routed(source: Any, profile_id: str) -> None:
    """Refuse to deliver unless Hermes resolved this chat to exactly ``profile_id``,
    so a message is never run by another agent."""
    if getattr(source, "profile_route_rejected", False):
        raise RuntimeError(f"Hermes is not serving the profile {profile_id!r} right now")
    expected = None if profile_id == DEFAULT_PROFILE_ID else profile_id
    actual = getattr(source, "profile", None) or None
    if actual == DEFAULT_PROFILE_ID:
        actual = None
    if actual != expected:
        raise RuntimeError(
            f"Hermes resolved chat {profile_id!r} to profile {actual or DEFAULT_PROFILE_ID!r}; not delivering")
