"""Files both ways (spec: docs/files.md).

The bytes live in the plugin's own folder ``<Hermes>/lekora-files/<agent>/<file id>/<name>``
and are kept forever, like chats; the plugin's database records what each one is (with
``instance_id`` and ``profile_id``). Uploads arrive in pieces over the phone's connection
and are written to ``<name>.part`` until complete. Standard library only.
"""

from __future__ import annotations

import base64
import mimetypes
import os
import re
import shutil
import uuid
from datetime import timedelta
from pathlib import Path
from typing import Optional

from .store import Store

MAX_FILE_BYTES = 100 * 1024 * 1024   # owner's decision 2026-11-10
MAX_FILES_PER_MESSAGE = 10
CHUNK_BYTES = 384 * 1024             # base64 of this stays well under the 1 MiB frame limit
STALE_UPLOAD_AGE = timedelta(days=1)


class FileError(Exception):
    def __init__(self, code: str, reason: str) -> None:
        super().__init__(reason)
        self.code, self.reason = code, reason


def kind_of(mime: str) -> str:
    """image | video | audio | document."""
    top = (mime or "").split("/", 1)[0].lower()
    return top if top in ("image", "video", "audio") else "document"


def safe_name(name: str) -> str:
    """A file name that's safe on disk (no folders, no control characters)."""
    base = os.path.basename(str(name or "").replace("\\", "/")).strip()
    base = re.sub(r"[\x00-\x1f/]", "_", base).lstrip(".")
    return (base or "file")[:120]


def guess_mime(name: str, mime: Optional[str] = None) -> str:
    if mime and "/" in mime:
        return mime.lower()
    return mimetypes.guess_type(name)[0] or "application/octet-stream"


class FileStore:
    def __init__(self, root: Path, store: Store) -> None:
        self.root = Path(root)
        self.store = store

    # ---- describing ----------------------------------------------------------

    @staticmethod
    def describe(row: dict) -> dict:
        """What the phone sees: {file_id, name, mime, size, kind}."""
        return {"file_id": row["file_id"], "name": row["name"], "mime": row["mime"],
                "size": int(row["size"]), "kind": kind_of(row["mime"])}

    def _folder(self, row: dict) -> Path:
        agent = re.sub(r"[^\w.-]", "_", row["profile_id"]) or "_"
        return self.root / agent / row["file_id"]

    def path_of(self, row: dict) -> Path:
        return self._folder(row) / safe_name(row["name"])

    def _part(self, row: dict) -> Path:
        return self._folder(row) / (safe_name(row["name"]) + ".part")

    def ready(self, file_id: str, profile_id: Optional[str] = None) -> dict:
        """A complete file (of this agent, when given), or FileError."""
        row = self.store.get_file(str(file_id or ""))
        if row is None or row["status"] != "ready" or (profile_id is not None and row["profile_id"] != profile_id):
            raise FileError("UNKNOWN_FILE", "That file isn't here")
        return row

    # ---- uploads (phone -> host) ----------------------------------------------

    def begin_upload(self, profile_id: str, name: str, mime: Optional[str], size: object) -> dict:
        try:
            size = int(size)  # type: ignore[arg-type]
        except (TypeError, ValueError):
            raise FileError("INVALID_FILE", "How big is the file?")
        if size < 0:
            raise FileError("INVALID_FILE", "How big is the file?")
        if size > MAX_FILE_BYTES:
            raise FileError("FILE_TOO_LARGE", "Files can be up to 100 MB")
        name = safe_name(name)
        file_id = "f_" + uuid.uuid4().hex
        self.store.add_file(file_id, profile_id, name, guess_mime(name, mime), size, origin="user", status="uploading")
        row = self.store.get_file(file_id)
        assert row is not None
        part = self._part(row)
        part.parent.mkdir(parents=True, exist_ok=True)
        part.write_bytes(b"")
        if size == 0:
            self._finish(row)
        return {"file_id": file_id, "chunk_size": CHUNK_BYTES}

    def _uploading(self, file_id: str, profile_id: str) -> dict:
        row = self.store.get_file(str(file_id or ""))
        if row is None or row["profile_id"] != profile_id or row["status"] != "uploading":
            raise FileError("UNKNOWN_FILE", "That upload isn't here; start again")
        return row

    def write_chunk(self, profile_id: str, file_id: str, offset: object, data: object) -> int:
        row = self._uploading(file_id, profile_id)
        try:
            chunk = base64.b64decode(str(data or ""), validate=True)
        except (ValueError, TypeError):
            raise FileError("INVALID_FILE", "That piece of the file was damaged")
        if offset != row["received"] or len(chunk) > CHUNK_BYTES or row["received"] + len(chunk) > row["size"]:
            raise FileError("INVALID_FILE", "That piece of the file was out of order")
        with open(self._part(row), "ab") as out:
            out.write(chunk)
        received = row["received"] + len(chunk)
        self.store.update_file(row["file_id"], received=received)
        return received

    def finish_upload(self, profile_id: str, file_id: str) -> dict:
        row = self._uploading(file_id, profile_id)
        if row["received"] != row["size"] or self._part(row).stat().st_size != row["size"]:
            raise FileError("INVALID_FILE", "The file didn't arrive completely; send it again")
        return self._finish(row)

    def _finish(self, row: dict) -> dict:
        os.replace(self._part(row), self.path_of(row))
        self.store.update_file(row["file_id"], status="ready", received=row["size"])
        return self.describe(dict(row, status="ready"))

    def clean_stale_uploads(self) -> int:
        """Unfinished uploads older than a day (the phone gave up)."""
        stale = self.store.stale_uploads(self.store.now() - STALE_UPLOAD_AGE)
        for row in stale:
            shutil.rmtree(self._folder(row), ignore_errors=True)
        self.store.delete_files([r["file_id"] for r in stale])
        return len(stale)

    # ---- reading (host -> phone) ------------------------------------------------

    def read_chunk(self, file_id: str, offset: object) -> dict:
        row = self.ready(file_id)
        if not isinstance(offset, int) or offset < 0 or offset > row["size"]:
            raise FileError("INVALID_FILE", "Can't read from there")
        with open(self.path_of(row), "rb") as src:
            src.seek(offset)
            chunk = src.read(CHUNK_BYTES)
        end = offset + len(chunk)
        return {"file_id": row["file_id"], "offset": offset, "data": base64.b64encode(chunk).decode("ascii"),
                "size": row["size"], "done": end >= row["size"]}

    # ---- agent files (agent -> phone) ----------------------------------------------

    def add_agent_file(self, profile_id: str, source: Path, name: Optional[str] = None,
                       mime: Optional[str] = None) -> dict:
        """Keeps a copy of a file the agent sent (Hermes' cache is cleared after a day)."""
        source = Path(source)
        if not source.is_file():
            raise FileError("UNKNOWN_FILE", f"There's no file at {source}")
        size = source.stat().st_size
        if size > MAX_FILE_BYTES:
            raise FileError("FILE_TOO_LARGE", "Files can be up to 100 MB")
        name = safe_name(name or source.name)
        file_id = "f_" + uuid.uuid4().hex
        self.store.add_file(file_id, profile_id, name, guess_mime(name, mime), size, origin="agent", status="uploading")
        row = self.store.get_file(file_id)
        assert row is not None
        self._folder(row).mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, self._part(row))
        return self._finish(row)

    # ---- the whole agent ----------------------------------------------------------

    def usage(self) -> dict:
        return self.store.files_usage()

    def move_profile(self, profile_id: str, destination: Path) -> None:
        """Deleting an agent: its files go to the backup next to its chats, then are forgotten."""
        folder = self.root / (re.sub(r"[^\w.-]", "_", profile_id) or "_")
        if folder.exists():
            Path(destination).parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(folder), str(destination))
        self.store.delete_profile_files(profile_id)
