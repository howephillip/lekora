"""Hermes glue for Skills (docs/skills.md). Imports Hermes lazily: only runs inside it."""

from __future__ import annotations

import logging
import shutil
from typing import Optional

log = logging.getLogger(__name__)


def scan(identifier: str) -> Optional[dict]:
    """Hermes' own install-time check of a catalog skill, without installing it (as Hermes'
    dashboard does): fetch it into quarantine, scan it, ask the install policy, clean up."""
    from hermes_cli.skills_hub import _resolve_source_meta_and_bundle
    from tools.skills_guard import scan_skill, should_allow_install
    from tools.skills_hub_install import quarantine_bundle
    from tools.skills_hub_search import create_source_router

    meta, bundle, _src = _resolve_source_meta_and_bundle(identifier, create_source_router())
    if not bundle:
        return None
    source = "official" if bundle.source == "official" else (
        getattr(bundle, "identifier", "") or getattr(meta, "identifier", "") or identifier)
    path = quarantine_bundle(bundle)
    try:
        result = scan_skill(path, source=source)
    finally:
        shutil.rmtree(path, ignore_errors=True)
    allowed, reason = should_allow_install(result, force=False)
    return {
        "name": result.skill_name, "identifier": identifier, "source": result.source,
        "trust_level": result.trust_level, "verdict": result.verdict, "summary": result.summary,
        "policy": "allow" if allowed is True else "ask" if allowed is None else "block",
        "policy_reason": reason,
        "findings": [{"severity": f.severity, "category": f.category, "file": f.file, "line": f.line,
                      "description": f.description} for f in result.findings][:50],
    }
