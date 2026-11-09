"""SQLite host store (lekora.db): the single source of truth for the plugin.

Every table carries ``instance_id`` (AGENTS.md rule 6). Tokens are never
stored in the clear: only salted SHA-256 hashes, compared in constant time.
"""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import sqlite3
import threading
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Optional

INVITE_TTL = timedelta(minutes=30)
DB_PATH_ENV = "LEKORA_DB_PATH"

SCHEMA = """
CREATE TABLE IF NOT EXISTS instance_metadata (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS pairing_invites (
    token_hash  TEXT PRIMARY KEY,
    instance_id TEXT NOT NULL,
    created_at  TEXT,
    expires_at  TEXT,
    used_at     TEXT,
    client_ip   TEXT
);
CREATE TABLE IF NOT EXISTS paired_devices (
    device_id         TEXT PRIMARY KEY,
    instance_id       TEXT NOT NULL,
    device_token_hash TEXT NOT NULL,
    device_name       TEXT,
    client_version    TEXT,
    paired_at         TEXT,
    last_seen_at      TEXT,
    revoked_at        TEXT
);
CREATE TABLE IF NOT EXISTS events (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    instance_id  TEXT NOT NULL,
    profile_id   TEXT NOT NULL,
    event_type   TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    created_at   TEXT,
    rev          INTEGER
);
CREATE INDEX IF NOT EXISTS events_profile_seq ON events (instance_id, profile_id, seq);
"""

# Read markers (docs/chat-history.md): per agent, "read up to seq N", shared by all phones.
READ_MARKERS = """
CREATE TABLE IF NOT EXISTS read_markers (
    instance_id   TEXT NOT NULL,
    profile_id    TEXT NOT NULL,
    last_read_seq INTEGER NOT NULL,
    updated_at    TEXT,
    PRIMARY KEY (instance_id, profile_id)
);
"""


class TokenInvalid(Exception):
    """Pairing token unknown or already used (wire code TOKEN_INVALID)."""


class TokenExpired(Exception):
    """Pairing token older than 30 minutes (wire code TOKEN_EXPIRED)."""


@dataclass(frozen=True)
class Device:
    device_id: str
    device_name: str
    client_version: str
    paired_at: Optional[str]
    last_seen_at: Optional[str]
    revoked_at: Optional[str]

    @property
    def active(self) -> bool:
        return self.revoked_at is None


@dataclass(frozen=True)
class Event:
    seq: int
    instance_id: str
    profile_id: str
    event_type: str
    payload: dict
    created_at: str
    rev: int = 0


def default_db_path() -> Path:
    override = os.environ.get(DB_PATH_ENV)
    if override:
        return Path(override).expanduser()
    return Path.home() / ".hermes" / "lekora.db"


def _utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _iso(dt: datetime) -> str:
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Store:
    def __init__(
        self,
        path: Optional[os.PathLike | str] = None,
        clock: Callable[[], datetime] = _utc_now,
    ) -> None:
        self._clock = clock
        self._lock = threading.RLock()
        db_path = Path(path) if path is not None else default_db_path()
        self.path = db_path
        if str(db_path) != ":memory:":
            db_path.parent.mkdir(parents=True, exist_ok=True)
        self._db = sqlite3.connect(str(db_path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        with self._lock:
            self._migrate_events()
            self._db.executescript(SCHEMA)
            self._db.commit()
        # Ensure identity + salt exist up front.
        self.instance_id = self.get_or_create_instance_id()
        self._salt = self._get_or_create_salt()
        with self._lock:
            self._create_read_markers()

    def _migrate_events(self) -> None:
        """Databases from before chat history: add change numbers (``rev = seq``)."""
        exists = self._db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='events'").fetchone()
        if not exists:
            return
        columns = {r["name"] for r in self._db.execute("PRAGMA table_info(events)")}
        if "rev" not in columns:
            self._db.execute("ALTER TABLE events ADD COLUMN rev INTEGER")
        self._db.execute("UPDATE events SET rev = seq WHERE rev IS NULL")

    def _create_read_markers(self) -> None:
        existed = self._db.execute(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='read_markers'").fetchone()
        self._db.executescript(READ_MARKERS)
        self._db.execute("CREATE INDEX IF NOT EXISTS events_rev ON events (instance_id, rev)")
        if not existed and self._meta_get("read_baseline") is None:
            # Everything stored before read markers existed counts as read.
            self._meta_set("read_baseline", str(self.current_seq()))
        if self._meta_get("rev_counter") is None:
            row = self._db.execute("SELECT COALESCE(MAX(rev), 0) AS r FROM events").fetchone()
            self._meta_set("rev_counter", str(max(int(row["r"]), self.current_seq())))
        self._db.commit()

    def now(self) -> datetime:
        return self._clock()

    def close(self) -> None:
        with self._lock:
            self._db.close()

    # ---- instance metadata -------------------------------------------------

    def _meta_get(self, key: str) -> Optional[str]:
        row = self._db.execute(
            "SELECT value FROM instance_metadata WHERE key = ?", (key,)
        ).fetchone()
        return row["value"] if row else None

    def _meta_set(self, key: str, value: str) -> None:
        self._db.execute(
            "INSERT INTO instance_metadata (key, value) VALUES (?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, value),
        )

    def get_or_create_instance_id(self) -> str:
        with self._lock:
            existing = self._meta_get("instance_id")
            if existing:
                return existing
            new_id = "inst_" + uuid.uuid4().hex[:16]
            self._meta_set("instance_id", new_id)
            self._db.commit()
            return new_id

    def get_instance_name(self, default: str = "Hermes") -> str:
        with self._lock:
            return self._meta_get("instance_name") or default

    def set_instance_name(self, name: str) -> None:
        with self._lock:
            self._meta_set("instance_name", name)
            self._db.commit()

    def get_persisted_port(self) -> Optional[int]:
        with self._lock:
            value = self._meta_get("bound_port")
        return int(value) if value else None

    def set_persisted_port(self, port: int) -> None:
        with self._lock:
            self._meta_set("bound_port", str(int(port)))
            self._db.commit()

    # ---- hashing -----------------------------------------------------------

    def _get_or_create_salt(self) -> str:
        with self._lock:
            salt = self._meta_get("hash_salt")
            if not salt:
                salt = secrets.token_hex(16)
                self._meta_set("hash_salt", salt)
                self._db.commit()
            return salt

    def _hash(self, token: str) -> str:
        return hashlib.sha256((self._salt + token).encode("utf-8")).hexdigest()

    # ---- pairing invites ---------------------------------------------------

    def create_invite(self) -> str:
        """Create a one-time 256-bit invite; returns the clear token (shown once)."""
        token = secrets.token_urlsafe(32)
        now = self._clock()
        with self._lock:
            self._db.execute(
                "INSERT INTO pairing_invites "
                "(token_hash, instance_id, created_at, expires_at) VALUES (?,?,?,?)",
                (self._hash(token), self.instance_id, _iso(now), _iso(now + INVITE_TTL)),
            )
            self._db.commit()
        return token

    def consume_invite(self, token: str, client_ip: Optional[str] = None) -> None:
        """Atomically spend an invite. Raises TokenInvalid / TokenExpired."""
        candidate = self._hash(token)
        now = self._clock()
        with self._lock:
            row = self._db.execute(
                "SELECT token_hash, expires_at, used_at FROM pairing_invites "
                "WHERE token_hash = ? AND instance_id = ?",
                (candidate, self.instance_id),
            ).fetchone()
            if row is None or not secrets.compare_digest(row["token_hash"], candidate):
                raise TokenInvalid()
            if row["used_at"] is not None:
                raise TokenInvalid()
            if _iso(now) >= row["expires_at"]:
                raise TokenExpired()
            cur = self._db.execute(
                "UPDATE pairing_invites SET used_at = ?, client_ip = ? "
                "WHERE token_hash = ? AND used_at IS NULL",
                (_iso(now), client_ip, candidate),
            )
            self._db.commit()
            if cur.rowcount != 1:
                raise TokenInvalid()

    # ---- devices -----------------------------------------------------------

    def register_device(
        self, device_name: str = "", client_version: str = ""
    ) -> tuple[str, str]:
        """Create a paired device; returns (device_id, clear device_token)."""
        device_id = "dev_" + uuid.uuid4().hex[:8]
        token = "sec_" + secrets.token_urlsafe(32)
        now = _iso(self._clock())
        with self._lock:
            self._db.execute(
                "INSERT INTO paired_devices (device_id, instance_id, device_token_hash, "
                "device_name, client_version, paired_at, last_seen_at) "
                "VALUES (?,?,?,?,?,?,?)",
                (device_id, self.instance_id, self._hash(token),
                 device_name, client_version, now, now),
            )
            self._db.commit()
        return device_id, token

    def verify_device_token(self, device_id: str, token: str) -> bool:
        candidate = self._hash(token)
        with self._lock:
            row = self._db.execute(
                "SELECT device_token_hash, revoked_at FROM paired_devices "
                "WHERE device_id = ? AND instance_id = ?",
                (device_id, self.instance_id),
            ).fetchone()
            # Compare against a dummy when the device is unknown so timing is similar.
            stored = row["device_token_hash"] if row else self._hash("")
            match = secrets.compare_digest(stored, candidate)
            if row is None or not match or row["revoked_at"] is not None:
                return False
            self._db.execute(
                "UPDATE paired_devices SET last_seen_at = ? WHERE device_id = ?",
                (_iso(self._clock()), device_id),
            )
            self._db.commit()
            return True

    def revoke_device(self, device_id: str) -> bool:
        with self._lock:
            cur = self._db.execute(
                "UPDATE paired_devices SET revoked_at = ? "
                "WHERE device_id = ? AND instance_id = ? AND revoked_at IS NULL",
                (_iso(self._clock()), device_id, self.instance_id),
            )
            self._db.commit()
            return cur.rowcount == 1

    def is_device_active(self, device_id: str) -> bool:
        """False once revoked, including by `hermes lekora devices --revoke` in another process."""
        with self._lock:
            row = self._db.execute(
                "SELECT revoked_at FROM paired_devices WHERE device_id = ? AND instance_id = ?",
                (device_id, self.instance_id),
            ).fetchone()
        return row is not None and row["revoked_at"] is None

    def list_devices(self) -> list[Device]:
        """All devices ever paired with this instance, oldest first (revoked ones included)."""
        with self._lock:
            rows = self._db.execute(
                "SELECT device_id, device_name, client_version, paired_at, last_seen_at, "
                "revoked_at FROM paired_devices WHERE instance_id = ? "
                "ORDER BY paired_at, rowid",
                (self.instance_id,),
            ).fetchall()
        return [Device(r["device_id"], r["device_name"] or "", r["client_version"] or "",
                       r["paired_at"], r["last_seen_at"], r["revoked_at"]) for r in rows]

    # ---- events ------------------------------------------------------------

    def _next_rev(self) -> int:
        """The next change number (docs/chat-history.md). Only ever goes up, never reused."""
        rev = int(self._meta_get("rev_counter") or 0) + 1
        self._meta_set("rev_counter", str(rev))
        return rev

    def current_rev(self) -> int:
        with self._lock:
            return int(self._meta_get("rev_counter") or 0)

    @staticmethod
    def _event(r: sqlite3.Row) -> Event:
        return Event(r["seq"], r["instance_id"], r["profile_id"], r["event_type"],
                     json.loads(r["payload_json"]), r["created_at"], int(r["rev"] or r["seq"]))

    def append_event(
        self, profile_id: str, event_type: str, payload: dict[str, Any]
    ) -> int:
        with self._lock:
            cur = self._db.execute(
                "INSERT INTO events (instance_id, profile_id, event_type, "
                "payload_json, created_at, rev) VALUES (?,?,?,?,?,?)",
                (self.instance_id, profile_id, event_type,
                 json.dumps(payload), _iso(self._clock()), self._next_rev()),
            )
            self._db.commit()
            return int(cur.lastrowid)

    def current_seq(self) -> int:
        """Highest seq ever issued. Never goes backwards, even after a deleted agent's
        events are removed (AUTOINCREMENT never reuses numbers)."""
        with self._lock:
            row = self._db.execute(
                "SELECT MAX(COALESCE((SELECT MAX(seq) FROM events WHERE instance_id = ?), 0),"
                " COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'events'), 0)) AS s",
                (self.instance_id,),
            ).fetchone()
        return int(row["s"])

    def fetch_events_since(self, last_seq: int) -> list[Event]:
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND seq > ? ORDER BY seq",
                (self.instance_id, int(last_seq)),
            ).fetchall()
        return [self._event(r) for r in rows]

    def get_event(self, seq: int) -> Optional[Event]:
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND seq = ?",
                (self.instance_id, int(seq))).fetchone()
        return self._event(row) if row else None

    def messages_changed_since(self, rev: int, limit: int) -> list[Event]:
        """Chat messages added or changed after change number ``rev``, oldest change
        first; at most ``limit`` (callers ask for one more to see if there are too many)."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND rev > ? "
                "AND event_type = 'chat.message' ORDER BY rev LIMIT ?",
                (self.instance_id, int(rev), int(limit)),
            ).fetchall()
        return [self._event(r) for r in rows]

    def recent_messages(self, per_profile: int) -> list[Event]:
        """The newest ``per_profile`` chat messages of every agent, in seq order."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM (SELECT *, ROW_NUMBER() OVER "
                "(PARTITION BY profile_id ORDER BY seq DESC) AS n FROM events "
                "WHERE instance_id = ? AND event_type = 'chat.message') "
                "WHERE n <= ? ORDER BY seq",
                (self.instance_id, int(per_profile)),
            ).fetchall()
        return [self._event(r) for r in rows]

    def messages_before(self, profile_id: str, before_seq: Optional[int],
                        limit: int) -> tuple[list[Event], bool]:
        """One agent's newest ``limit`` messages older than ``before_seq`` (oldest first),
        and whether there are older ones still."""
        bound = int(before_seq) if before_seq is not None else 2**62
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND profile_id = ? AND seq < ? "
                "AND event_type = 'chat.message' ORDER BY seq DESC LIMIT ?",
                (self.instance_id, profile_id, bound, int(limit) + 1),
            ).fetchall()
        has_more = len(rows) > limit
        return [self._event(r) for r in reversed(rows[:limit])], has_more

    def update_event_text(self, seq: int, text: str) -> Optional[Event]:
        """Replace a saved chat message's text in place (an agent's later correction).
        It gets a new change number, so phones that were away still receive it."""
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND seq = ?",
                (self.instance_id, int(seq))).fetchone()
            if row is None or row["event_type"] != "chat.message":
                return None
            payload = json.loads(row["payload_json"])
            payload["text"] = text
            rev = self._next_rev()
            self._db.execute("UPDATE events SET payload_json = ?, rev = ? WHERE seq = ?",
                             (json.dumps(payload), rev, int(seq)))
            self._db.commit()
        return Event(row["seq"], row["instance_id"], row["profile_id"], row["event_type"],
                     payload, row["created_at"], rev)

    def update_event_payload(self, seq: int, payload: dict[str, Any]) -> Optional[Event]:
        """Replace a saved chat message's payload (a card's new status). New change number."""
        with self._lock:
            row = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND seq = ?",
                (self.instance_id, int(seq))).fetchone()
            if row is None or row["event_type"] != "chat.message":
                return None
            rev = self._next_rev()
            self._db.execute("UPDATE events SET payload_json = ?, rev = ? WHERE seq = ?",
                             (json.dumps(payload), rev, int(seq)))
            self._db.commit()
        return Event(row["seq"], row["instance_id"], row["profile_id"], row["event_type"],
                     payload, row["created_at"], rev)

    def pending_cards(self) -> list[Event]:
        """Approval and question cards still marked pending (docs/prompts.md)."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND event_type = 'chat.message' "
                "AND json_extract(payload_json, '$.card.status') = 'pending' ORDER BY seq",
                (self.instance_id,)).fetchall()
        return [self._event(r) for r in rows]

    def events_for_profile(self, profile_id: str) -> list[Event]:
        """One agent's events in order (for the backup taken before deleting it)."""
        with self._lock:
            rows = self._db.execute(
                "SELECT * FROM events WHERE instance_id = ? AND profile_id = ? ORDER BY seq",
                (self.instance_id, profile_id)).fetchall()
        return [self._event(r) for r in rows]

    def delete_profile_events(self, profile_id: str) -> int:
        """Remove a deleted agent's events and read marker, so a new agent with the same
        name starts clean."""
        with self._lock:
            cur = self._db.execute(
                "DELETE FROM events WHERE instance_id = ? AND profile_id = ?",
                (self.instance_id, profile_id),
            )
            self._db.execute(
                "DELETE FROM read_markers WHERE instance_id = ? AND profile_id = ?",
                (self.instance_id, profile_id))
            self._db.commit()
            return cur.rowcount

    # ---- read markers --------------------------------------------------------

    def read_marker(self, profile_id: str) -> int:
        """Highest seq read in this agent's chat (any of the user's phones)."""
        with self._lock:
            row = self._db.execute(
                "SELECT last_read_seq FROM read_markers WHERE instance_id = ? AND profile_id = ?",
                (self.instance_id, profile_id)).fetchone()
            if row is not None:
                return int(row["last_read_seq"])
            return int(self._meta_get("read_baseline") or 0)

    def mark_read(self, profile_id: str, seq: int) -> bool:
        """Move the marker forward to ``seq``; never backwards. True if it moved."""
        seq = min(int(seq), self.current_seq())
        with self._lock:
            if seq <= self.read_marker(profile_id):
                return False
            self._db.execute(
                "INSERT INTO read_markers (instance_id, profile_id, last_read_seq, updated_at) "
                "VALUES (?,?,?,?) ON CONFLICT(instance_id, profile_id) DO UPDATE SET "
                "last_read_seq = excluded.last_read_seq, updated_at = excluded.updated_at",
                (self.instance_id, profile_id, seq, _iso(self._clock())))
            self._db.commit()
            return True
