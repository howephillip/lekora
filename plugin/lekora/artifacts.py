"""Artifacts (spec: docs/artifacts.md): web pages, documents, code and images an agent makes for
the user, kept on the Hermes instance with every version.

Agents make and change them with real tools (AGENTS.md rule 7), offered only in Lekora chats:
``lekora_create_artifact``, ``lekora_update_artifact``, ``lekora_read_artifact`` and
``lekora_list_artifacts``. Each one made or changed shows in the chat as a card. The user can edit
one in the app (a new version, by "you"), go back to an earlier version, or ask the agent to
change it (their message carries which artifact it's about).
"""

from __future__ import annotations

import asyncio
import json
import uuid
from typing import Any, Awaitable, Callable, Optional

KINDS = ("html", "markdown", "code", "svg", "text")
KIND_NAMES = {"html": "web page", "markdown": "document", "code": "code", "svg": "image", "text": "text"}
MAX_CONTENT = 2_000_000          # characters per version
MAX_TITLE = 120


class ArtifactError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code = code
        self.reason = reason


def card(row: dict) -> dict:
    """What a chat card and a list row show."""
    data = {"artifact_id": row["artifact_id"], "title": row["title"], "kind": row["kind"], "version": row["version"]}
    if row.get("language"):
        data["language"] = row["language"]
    if row.get("updated_at"):
        data["updated_at"] = row["updated_at"]
    return data


def _title(value: Any) -> str:
    title = " ".join(str(value or "").split())[:MAX_TITLE]
    if not title:
        raise ArtifactError("INVALID_ARTIFACT", "Give the artifact a title.")
    return title


def _content(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ArtifactError("INVALID_ARTIFACT", "The artifact needs content.")
    if len(value) > MAX_CONTENT:
        raise ArtifactError("ARTIFACT_TOO_LARGE", f"Artifacts can be up to {MAX_CONTENT // 1_000_000} million characters.")
    return value


def _kind(value: Any) -> str:
    kind = str(value or "").strip().lower()
    aliases = {"md": "markdown", "document": "markdown", "doc": "markdown", "page": "html", "web": "html",
               "image": "svg", "txt": "text", "plain": "text"}
    kind = aliases.get(kind, kind)
    if kind not in KINDS:
        raise ArtifactError("INVALID_ARTIFACT", f"Kind must be one of: {', '.join(KINDS)}.")
    return kind


# (profile, payload) -> seq: a chat message (a card) saved and sent to the phones
Publish = Callable[[str, dict], Awaitable[int]]
# (profile, card) -> None: tell open phones an artifact changed
Changed = Callable[[str, dict], Awaitable[None]]


class Artifacts:
    def __init__(self, store: Any, publish: Publish, changed: Optional[Changed] = None) -> None:
        self.store = store
        self._publish = publish
        self._changed = changed

    def _own(self, profile_id: str, artifact_id: Any) -> dict:
        row = self.store.get_artifact(str(artifact_id or ""))
        if row is None or row["profile_id"] != profile_id:
            raise ArtifactError("UNKNOWN_ARTIFACT", "There's no artifact with that id in this chat.")
        return row

    async def _announce(self, profile_id: str, row: dict, role: str, action: str) -> int:
        shown = {**card(row), "action": action}
        seq = await self._publish(profile_id, {"role": role, "text": "", "artifact": shown})
        if self._changed is not None:
            await self._changed(profile_id, card(row))
        return seq

    async def create(self, profile_id: str, title: Any, kind: Any, content: Any,
                     language: Any = None) -> dict:
        title, kind, content = _title(title), _kind(kind), _content(content)
        language = " ".join(str(language).split())[:40] if language and kind == "code" else None
        artifact_id = "art_" + uuid.uuid4().hex[:16]
        await asyncio.to_thread(self.store.add_artifact, artifact_id, profile_id, title, kind, language,
                                content, "agent")
        row = self.store.get_artifact(artifact_id)
        await self._announce(profile_id, row, "assistant", "created")
        return card(row)

    async def update(self, profile_id: str, artifact_id: Any, content: Any, *, note: Any = None,
                     title: Any = None, author: str = "agent", base: Optional[int] = None) -> dict:
        row = self._own(profile_id, artifact_id)
        content = _content(content)
        new_title = _title(title) if title else None
        note = " ".join(str(note).split())[:300] if note else None
        try:
            await asyncio.to_thread(self.store.add_artifact_version, row["artifact_id"], content, author, note,
                                    new_title, base)
        except ValueError as exc:
            raise ArtifactError("ARTIFACT_CHANGED",
                                f"It was changed meanwhile (now version {exc.args[0]}); open it again to see the latest.")
        row = self.store.get_artifact(row["artifact_id"])
        await self._announce(profile_id, row, "user" if author == "user" else "assistant",
                             "edited" if author == "user" else "updated")
        return card(row)

    def read(self, profile_id: str, artifact_id: Any, version: Any = None) -> dict:
        row = self._own(profile_id, artifact_id)
        try:
            number = int(version) if version not in (None, "") else None
        except (TypeError, ValueError):
            raise ArtifactError("INVALID_ARTIFACT", "Version must be a number.")
        got = self.store.artifact_version(row["artifact_id"], number)
        if got is None:
            raise ArtifactError("UNKNOWN_VERSION", f"There's no version {number}.")
        return {**card(row), "shown_version": got["version"], "content": got["content"],
                "versions": self.store.artifact_history(row["artifact_id"])}

    def list(self, profile_id: str) -> list[dict]:
        return [card(row) for row in self.store.list_artifacts(profile_id)]

    def describe_for_agent(self, profile_id: str, artifact_id: Any) -> Optional[dict]:
        """For a user's "ask to change" message: which artifact it's about (None if not here)."""
        try:
            return card(self._own(profile_id, artifact_id))
        except ArtifactError:
            return None


# ---- the agent's tools ----------------------------------------------------------------

TOOLSET = "lekora"

CREATE_SCHEMA = {
    "name": "lekora_create_artifact",
    "description": (
        "Create an artifact in this Lekora chat: a web page (HTML; scripts and online libraries work), "
        "a document (Markdown), code, an SVG image, or plain text. The user sees it as a card that opens "
        "full screen, and can edit it, share it (file or PDF) and go back to earlier versions. Use it for "
        "anything substantial the user will want to view, keep or reuse (a page, report, plan, chart, "
        "script) instead of pasting it into your reply. Give the complete content."),
    "parameters": {
        "type": "object",
        "properties": {
            "title": {"type": "string", "description": "Short title shown on the card."},
            "kind": {"type": "string", "enum": list(KINDS), "description": "What it is."},
            "content": {"type": "string", "description": "The complete content (HTML, Markdown, code, SVG or text)."},
            "language": {"type": "string", "description": "For code: the language, e.g. python, swift."},
        },
        "required": ["title", "kind", "content"],
    },
}
UPDATE_SCHEMA = {
    "name": "lekora_update_artifact",
    "description": (
        "Change an artifact in this Lekora chat: saves a new version (earlier ones are kept). Read it first "
        "with lekora_read_artifact if you don't have its latest content: the user may have edited it. "
        "Give the complete new content."),
    "parameters": {
        "type": "object",
        "properties": {
            "artifact_id": {"type": "string", "description": "The artifact's id (art_…)."},
            "content": {"type": "string", "description": "The complete new content."},
            "note": {"type": "string", "description": "Optional: what changed, in a few words."},
            "title": {"type": "string", "description": "Optional: a new title."},
        },
        "required": ["artifact_id", "content"],
    },
}
READ_SCHEMA = {
    "name": "lekora_read_artifact",
    "description": "Read an artifact in this Lekora chat (its latest version, or an earlier one), including the user's own edits.",
    "parameters": {
        "type": "object",
        "properties": {
            "artifact_id": {"type": "string", "description": "The artifact's id (art_…)."},
            "version": {"type": "integer", "description": "Optional: an earlier version's number."},
        },
        "required": ["artifact_id"],
    },
}
LIST_SCHEMA = {
    "name": "lekora_list_artifacts",
    "description": "List the artifacts in this Lekora chat (id, title, kind, latest version), most recently changed first.",
    "parameters": {"type": "object", "properties": {}},
}
SCHEMAS = (CREATE_SCHEMA, UPDATE_SCHEMA, READ_SCHEMA, LIST_SCHEMA)


def _result(ok: bool, **data: Any) -> str:
    return json.dumps({"success": ok, **data})


def run_tool(name: str, args: dict, *, platform: str, chat_id: str, service: Optional[Artifacts],
             loop: Optional[asyncio.AbstractEventLoop], timeout: float = 60) -> str:
    """A tool call, in Hermes' tool thread: the work runs on the Lekora service's event loop."""
    if platform != "lekora" or not chat_id:
        return _result(False, error=f"{name} only works in Lekora chats")
    if service is None or loop is None:
        return _result(False, error="Lekora isn't running")
    try:
        if asyncio.get_running_loop() is loop:
            return _result(False, error="Lekora can't do that from here")
    except RuntimeError:
        pass
    try:
        if name == "lekora_create_artifact":
            made = asyncio.run_coroutine_threadsafe(service.create(
                chat_id, args.get("title"), args.get("kind"), args.get("content"), args.get("language")), loop
            ).result(timeout=timeout)
            return _result(True, message=f"Created \"{made['title']}\" (version 1); the user sees it as a card.", **made)
        if name == "lekora_update_artifact":
            made = asyncio.run_coroutine_threadsafe(service.update(
                chat_id, args.get("artifact_id"), args.get("content"), note=args.get("note"),
                title=args.get("title")), loop).result(timeout=timeout)
            return _result(True, message=f"Saved \"{made['title']}\" as version {made['version']}.", **made)
        if name == "lekora_read_artifact":
            got = service.read(chat_id, args.get("artifact_id"), args.get("version"))
            history = [{"version": v["version"], "by": "the user" if v["author"] == "user" else "you",
                        "note": v.get("note")} for v in got.pop("versions")]
            return _result(True, **got, versions=history)
        if name == "lekora_list_artifacts":
            return _result(True, artifacts=service.list(chat_id))
    except ArtifactError as exc:
        return _result(False, error=exc.reason)
    except Exception as exc:
        return _result(False, error=f"Couldn't do that: {getattr(exc, 'reason', None) or exc}")
    return _result(False, error=f"Unknown tool {name}")


# ---- reviews: comments on lines, sent together (docs/artifacts.md, "Comments") ---------

MAX_COMMENTS = 100


def clean_review(value: Any) -> Optional[list[dict]]:
    """Comments from the phone: [{line_start, line_end, quote, comment}], or None if not a review."""
    if not isinstance(value, list) or not value:
        return None
    out = []
    for item in value[:MAX_COMMENTS]:
        if not isinstance(item, dict):
            continue
        comment = str(item.get("comment") or "").strip()[:4000]
        try:
            start = max(int(item.get("line_start")), 1)
            end = max(int(item.get("line_end", start)), start)
        except (TypeError, ValueError):
            continue
        if not comment:
            continue
        quote = str(item.get("quote") or "")[:2000]
        out.append({"line_start": start, "line_end": end, "quote": quote, "comment": comment})
    return out or None


def review_text(about: dict, review: list[dict], note: str) -> str:
    """What the agent receives for a review: every comment with its lines, in order."""
    count = len(review)
    head = (f'Review of the artifact "{about["title"]}" (id {about["artifact_id"]}, version {about["version"]}): '
            f'{count} comment{"s" if count != 1 else ""} on specific lines.')
    parts = [head]
    if note.strip():
        parts.append(note.strip())
    for n, item in enumerate(sorted(review, key=lambda c: (c["line_start"], c["line_end"])), start=1):
        where = (f'Line {item["line_start"]}' if item["line_start"] == item["line_end"]
                 else f'Lines {item["line_start"]}-{item["line_end"]}')
        block = f"{n}. {where}:"
        if item["quote"].strip():
            quoted = "\n".join("   > " + line for line in item["quote"].splitlines())
            block += "\n" + quoted
        block += "\n   " + item["comment"].replace("\n", "\n   ")
        parts.append(block)
    return "\n\n".join(parts)
