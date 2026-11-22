"""Skills: each agent's Hermes skills, from the phone (docs/skills.md).

Reading is straight from the agent's skills folder (read-only). Changes go through Hermes: its own
CLI for catalog installs and uninstalls, its own config writer for on/off (after a backup; owner's
rule 8 exception, 2026-11-22), its own scan before an install. New and edited skills are written
as Hermes lays them out. Nothing here imports Hermes: what needs it is passed in.
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Awaitable, Callable, Iterable, Optional, Sequence

log = logging.getLogger(__name__)

ESSENTIAL = {"hermes-agent"}          # Hermes never lets this one be turned off
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
CATEGORY_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
DESCRIPTION_LIMIT = 60                # Hermes' limit for a new skill's description
CONTENT_LIMIT = 200_000

RunCli = Callable[[Sequence[str]], Awaitable[tuple[int, str]]]


class SkillError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def frontmatter(text: str) -> dict:
    """The simple ``key: value`` lines of a SKILL.md header (name, description, category…)."""
    if not text.startswith("---"):
        return {}
    end = text.find("\n---", 3)
    if end == -1:
        return {}
    out: dict[str, str] = {}
    for line in text[3:end].splitlines():
        if not line or line[0] in " \t#-" or ":" not in line:
            continue
        key, _, value = line.partition(":")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        out[key.strip()] = value
    return out


def _stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")


class Skills:
    def __init__(self, profiles: Callable[[], Iterable[str]], home_of: Callable[[str], Path],
                 read_config: Callable[[Path], dict], write_config: Callable[[Path, dict], None],
                 backup_config: Callable[[str, Path], Any], run_cli: RunCli, backups: Path,
                 scan: Optional[Callable[[str], dict]] = None,
                 llm: Optional[Callable[[str, str], Awaitable[Any]]] = None) -> None:
        self._profiles = profiles
        self._home_of = home_of
        self._read_config = read_config
        self._write_config = write_config
        self._backup_config = backup_config
        self._run_cli = run_cli
        self._backups = Path(backups)
        self._scan = scan
        self._llm = llm

    # ---- reading ------------------------------------------------------------

    def _agent(self, profile_id: Any) -> str:
        if not isinstance(profile_id, str) or profile_id not in set(self._profiles()):
            raise SkillError("UNKNOWN_PROFILE", "Unknown agent")
        return profile_id

    def _dir(self, profile_id: str) -> Path:
        return Path(self._home_of(profile_id)) / "skills"

    def _config_path(self, profile_id: str) -> Path:
        return Path(self._home_of(profile_id)) / "config.yaml"

    def _disabled(self, profile_id: str) -> set[str]:
        try:
            cfg = self._read_config(self._config_path(profile_id)) or {}
        except Exception:
            return set()
        skills = cfg.get("skills") if isinstance(cfg, dict) else None
        listed = skills.get("disabled") if isinstance(skills, dict) else None
        return {str(n) for n in listed} if isinstance(listed, list) else set()

    def _records(self, root: Path) -> tuple[set[str], dict[str, dict]]:
        bundled: set[str] = set()
        try:
            for line in (root / ".bundled_manifest").read_text(errors="replace").splitlines():
                name = line.split(":", 1)[0].strip()
                if name:
                    bundled.add(name)
        except OSError:
            pass
        hub: dict[str, dict] = {}
        try:
            data = json.loads((root / ".hub" / "lock.json").read_text(errors="replace"))
            installed = data.get("installed") if isinstance(data, dict) else None
            if isinstance(installed, dict):
                hub = {str(k): (v if isinstance(v, dict) else {}) for k, v in installed.items()}
        except (OSError, ValueError):
            pass
        return bundled, hub

    def _found(self, profile_id: str) -> dict[str, tuple[Path, dict]]:
        """name -> (its folder, its header), for every skill in the agent's folder."""
        root = self._dir(profile_id)
        found: dict[str, tuple[Path, dict]] = {}
        if not root.is_dir():
            return found
        for skill_md in sorted(root.rglob("SKILL.md")):
            rel = skill_md.relative_to(root).parts
            if any(p.startswith(".") for p in rel):
                continue
            # Anything inside another skill's folder (its references, scripts…) is part of that skill.
            if any((root.joinpath(*rel[:i]) / "SKILL.md").is_file() for i in range(1, len(rel) - 1)):
                continue
            try:
                head = frontmatter(skill_md.read_text(errors="replace")[:20_000])
            except OSError:
                continue
            name = head.get("name") or skill_md.parent.name
            found.setdefault(name, (skill_md.parent, head))
        return found

    def _describe(self, profile_id: str, name: str, folder: Path, head: dict,
                  bundled: set[str], hub: dict[str, dict], disabled: set[str]) -> dict:
        rel = folder.relative_to(self._dir(profile_id)).parts
        category = head.get("category") or (rel[0] if len(rel) >= 2 else None)
        source = "hub" if name in hub else "builtin" if name in bundled else "local"
        item: dict[str, Any] = {"name": name, "description": head.get("description") or "",
                                "source": source, "enabled": name not in disabled or name in ESSENTIAL,
                                "essential": name in ESSENTIAL}
        if category:
            item["category"] = category
        if source == "hub" and hub[name].get("trust_level"):
            item["trust"] = hub[name]["trust_level"]
        return item

    def list(self, profile_id: Any) -> list[dict]:
        profile_id = self._agent(profile_id)
        bundled, hub = self._records(self._dir(profile_id))
        disabled = self._disabled(profile_id)
        items = [self._describe(profile_id, name, folder, head, bundled, hub, disabled)
                 for name, (folder, head) in self._found(profile_id).items()]
        return sorted(items, key=lambda s: (s.get("category") or "~", s["name"]))

    def all(self) -> list[dict]:
        """Every skill across every agent (owner, 2026-11-22: one Skills page, not per agent):
        ``{name, description, category?, agents: [{profile_id, source, enabled, essential, trust?}]}``."""
        merged: dict[str, dict] = {}
        for profile_id in self._profiles():
            for item in self.list(profile_id):
                entry = merged.setdefault(item["name"], {"name": item["name"], "description": item["description"],
                                                         "agents": []})
                if item.get("category") and "category" not in entry:
                    entry["category"] = item["category"]
                if not entry["description"] and item["description"]:
                    entry["description"] = item["description"]
                entry["agents"].append({k: item[k] for k in ("source", "enabled", "essential", "trust") if k in item}
                                       | {"profile_id": profile_id})
        return sorted(merged.values(), key=lambda s: s["name"])

    async def copy(self, from_profile: Any, name: Any, to: Any) -> dict:
        """Give agents a skill another agent has: a catalog skill is installed for them by Hermes (the
        same identifier); any other is copied as it is. Agents that have it already are left alone."""
        from_profile = self._agent(from_profile)
        name, folder, _ = self._one(from_profile, name)
        if not isinstance(to, list) or not to:
            raise SkillError("INVALID_REQUEST", "Which agents?")
        targets = [self._agent(p) for p in dict.fromkeys(to)]
        _, hub = self._records(self._dir(from_profile))
        added, failed = [], []
        for target in targets:
            if target == from_profile or name in self._found(target):
                continue
            try:
                if name in hub and hub[name].get("identifier"):
                    await self.install(target, hub[name]["identifier"])
                else:
                    rel = folder.relative_to(self._dir(from_profile))
                    dest = self._dir(target) / rel
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    await asyncio.to_thread(shutil.copytree, folder, dest)
                added.append(target)
            except SkillError as exc:
                failed.append({"profile_id": target, "reason": exc.reason})
            except OSError as exc:
                failed.append({"profile_id": target, "reason": str(exc)})
        return {"name": name, "added": added, "failed": failed}

    def _one(self, profile_id: str, name: Any) -> tuple[str, Path, dict]:
        found = self._found(profile_id)
        if not isinstance(name, str) or name not in found:
            raise SkillError("UNKNOWN_SKILL", "That skill isn't there any more")
        folder, head = found[name]
        return name, folder, head

    def get(self, profile_id: Any, name: Any) -> dict:
        profile_id = self._agent(profile_id)
        name, folder, head = self._one(profile_id, name)
        bundled, hub = self._records(self._dir(profile_id))
        content = (folder / "SKILL.md").read_text(errors="replace")
        return {"skill": self._describe(profile_id, name, folder, head, bundled, hub, self._disabled(profile_id)),
                "content": content}

    # ---- on / off (owner's rule 8 exception, 2026-11-22) --------------------

    def set_enabled(self, profile_id: Any, name: Any, enabled: Any) -> dict:
        profile_id = self._agent(profile_id)
        name, _, _ = self._one(profile_id, name)
        if not isinstance(enabled, bool):
            raise SkillError("INVALID_REQUEST", "On or off?")
        if name in ESSENTIAL and not enabled:
            raise SkillError("INVALID_REQUEST", "Hermes needs this skill; it can't be turned off")
        path = self._config_path(profile_id)
        cfg = self._read_config(path) or {}
        skills = cfg.get("skills") if isinstance(cfg.get("skills"), dict) else {}
        disabled = [str(n) for n in skills.get("disabled") or [] if isinstance(n, str)]
        changed = (name in disabled) == enabled
        if changed:
            self._backup_config(profile_id, path)
            disabled = [n for n in disabled if n != name] if enabled else disabled + [name]
            skills = dict(skills, disabled=disabled)
            cfg = dict(cfg, skills=skills)
            self._write_config(path, cfg)
            log.info("Lekora: %s's skill %s turned %s (config backed up first)", profile_id, name, "on" if enabled else "off")
        return self.get(profile_id, name)["skill"]

    # ---- the catalog -----------------------------------------------------------

    async def search(self, query: Any) -> list[dict]:
        query = " ".join(str(query or "").split())[:100]
        if not query:
            return []
        code, out = await self._run_cli(["skills", "search", query, "--json", "--limit", "20"])
        start = out.find("[")
        try:
            rows = json.loads(out[start:]) if code == 0 and start != -1 else []
        except ValueError:
            rows = []
        keep = ("name", "identifier", "source", "trust_level", "description")
        return [{k: str(r.get(k) or "") for k in keep} for r in rows if isinstance(r, dict) and r.get("identifier")]

    async def scan(self, identifier: Any) -> dict:
        if not isinstance(identifier, str) or not identifier.strip():
            raise SkillError("INVALID_REQUEST", "Which skill?")
        if self._scan is None:
            raise SkillError("SKILLS_UNAVAILABLE", "This Hermes instance can't check catalog skills")
        got = await asyncio.to_thread(self._scan, identifier.strip())
        if not got:
            raise SkillError("UNKNOWN_SKILL", "The catalog doesn't have that skill any more")
        return got

    async def install(self, profile_id: Any, identifier: Any) -> dict:
        profile_id = self._agent(profile_id)
        if not isinstance(identifier, str) or not identifier.strip():
            raise SkillError("INVALID_REQUEST", "Which skill?")
        before = set(self._found(profile_id))
        code, out = await self._run_cli(["-p", profile_id, "skills", "install", identifier.strip(), "--yes"])
        added = [n for n in self._found(profile_id) if n not in before]
        if code != 0 or not added:
            lines = [l.strip() for l in out.splitlines() if l.strip()]
            reason = next((l for l in reversed(lines) if "block" in l.lower() or "error" in l.lower()), None)
            raise SkillError("INSTALL_REFUSED", reason or (lines[-1] if lines else "Hermes didn't install it"))
        return self.get(profile_id, added[0])["skill"]

    # ---- removing (always confirmed in the app) -----------------------------

    async def remove(self, profile_id: Any, name: Any) -> dict:
        profile_id = self._agent(profile_id)
        name, folder, _ = self._one(profile_id, name)
        if name in ESSENTIAL:
            raise SkillError("INVALID_REQUEST", "Hermes needs this skill; it can't be removed")
        _, hub = self._records(self._dir(profile_id))
        if name in hub:
            code, out = await self._run_cli(["-p", profile_id, "skills", "uninstall", name, "--yes"])
            if code != 0 or name in self._found(profile_id):
                lines = [l.strip() for l in out.splitlines() if l.strip()]
                raise SkillError("REMOVE_FAILED", lines[-1] if lines else "Hermes didn't remove it")
            return {"name": name}
        target = self._backups / "skills" / profile_id / f"{name}-{_stamp()}"
        target.parent.mkdir(parents=True, exist_ok=True)
        await asyncio.to_thread(shutil.move, str(folder), str(target))
        log.info("Lekora: %s's skill %s moved to %s", profile_id, name, target)
        return {"name": name, "backup": str(target)}

    # ---- making and editing -------------------------------------------------

    @staticmethod
    def check(content: Any, name: Any = None) -> dict:
        """Hermes' rules for a SKILL.md: a header with a valid name and a short description."""
        if not isinstance(content, str) or not content.strip():
            raise SkillError("INVALID_SKILL", "The skill needs instructions")
        if len(content) > CONTENT_LIMIT:
            raise SkillError("INVALID_SKILL", "That's too long for a skill")
        head = frontmatter(content)
        if not head.get("name") or not head.get("description"):
            raise SkillError("INVALID_SKILL", "Start with a header: ---, name: …, description: …, ---")
        if not NAME_RE.match(head["name"]):
            raise SkillError("INVALID_SKILL", "Names use lowercase letters, digits, - _ and ., up to 64")
        if name is not None and head["name"] != name:
            raise SkillError("INVALID_SKILL", f"The header's name must stay {name}")
        if len(head["description"]) > DESCRIPTION_LIMIT:
            raise SkillError("INVALID_SKILL", f"Keep the description to {DESCRIPTION_LIMIT} characters")
        return head

    def save(self, profile_id: Any, content: Any, create: Any, category: Any = None, name: Any = None) -> dict:
        profile_id = self._agent(profile_id)
        if create:
            head = self.check(content)
            if head["name"] in self._found(profile_id):
                raise SkillError("SKILL_EXISTS", f"{head['name']} already exists; pick another name")
            category = str(category or head.get("category") or "").strip() or None
            if category and not CATEGORY_RE.match(category):
                raise SkillError("INVALID_SKILL", "A category is one lowercase word")
            folder = self._dir(profile_id) / (category or "") / head["name"]
            folder.mkdir(parents=True, exist_ok=False)
            (folder / "SKILL.md").write_text(content)
            return self.get(profile_id, head["name"])["skill"]
        name, folder, _ = self._one(profile_id, name)
        self.check(content, name)
        old = folder / "SKILL.md"
        keep = self._backups / "skills" / profile_id / f"{name}-{_stamp()}.SKILL.md"
        keep.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(old, keep)  # the version before this edit
        old.write_text(content)
        return self.get(profile_id, name)["skill"]

    async def draft(self, description: Any) -> dict:
        """A new skill drafted by Hermes' own model from the user's words. Nothing is saved."""
        words = " ".join(str(description or "").split())[:2000]
        if not words:
            raise SkillError("INVALID_REQUEST", "Describe what the skill should do")
        if self._llm is None:
            raise SkillError("DRAFT_UNAVAILABLE", "Drafting isn't available on this Hermes instance")
        hint = ""
        for _ in range(2):
            try:
                got = await self._llm(DRAFT_INSTRUCTIONS + hint, words)
            except Exception as exc:
                log.info("Lekora: drafting a skill failed: %s", exc)
                raise SkillError("DRAFT_FAILED", "Hermes' model couldn't draft it just now. Try again, or write it yourself")
            if isinstance(got, dict):
                name = re.sub(r"[^a-z0-9._-]+", "-", str(got.get("name") or "").lower()).strip("-")[:64]
                desc = " ".join(str(got.get("description") or "").split())[:DESCRIPTION_LIMIT]
                body = str(got.get("instructions") or "").strip()
                category = re.sub(r"[^a-z0-9._-]+", "-", str(got.get("category") or "").lower()).strip("-")[:64] or None
                if name and desc and body:
                    content = f"---\nname: {name}\ndescription: {json.dumps(desc)}\nversion: 1.0.0\n---\n\n{body}\n"
                    out = {"name": name, "description": desc, "content": content}
                    if category:
                        out["category"] = category
                    return out
            hint = "\nReply with the JSON object only, with name, description, category and instructions."
        raise SkillError("DRAFT_FAILED", "Hermes' model couldn't draft it just now. Try again, or write it yourself")


DRAFT_INSTRUCTIONS = (
    "You write Hermes Agent skills: reusable instructions an AI agent loads when a task calls for them. "
    "From the user's description, reply with one JSON object: "
    '{"name": lowercase-hyphenated name (max 40 chars), "description": what it does, at most 60 characters, '
    '"category": one lowercase word, "instructions": the skill body in Markdown: when to use it, the steps, '
    "any commands or checks, and pitfalls}. Write the instructions for the agent, concise and specific. "
    "Don't invent tools or credentials the description doesn't mention.")
