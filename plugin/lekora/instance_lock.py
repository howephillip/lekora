"""One running Lekora per Hermes machine.

Lekora's store (lekora.db: pairings, saved port, chats) is shared by anything on the
machine. A second copy that started while the first was running would find the saved
port busy, move to another one and overwrite the saved port, so new pairing codes
advertised a port nothing listened on. The running copy now holds an exclusive lock
next to the database for its lifetime; another copy sees the lock and stays out.

The OS releases the lock when the process exits, so a crash never leaves it stuck.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Optional


class LekoraAlreadyRunning(RuntimeError):
    """Another Lekora copy on this machine holds the lock."""


class InstanceLock:
    def __init__(self, path: Path) -> None:
        self.path = Path(path)
        self._fd: Optional[int] = None

    def acquire(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(str(self.path), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            _lock(fd)
        except OSError:
            os.close(fd)
            raise LekoraAlreadyRunning(
                "Lekora is already running on this machine (another Hermes profile or process)")
        os.ftruncate(fd, 0)
        os.write(fd, str(os.getpid()).encode())
        self._fd = fd

    def release(self) -> None:
        if self._fd is None:
            return
        try:
            _unlock(self._fd)
        finally:
            os.close(self._fd)
            self._fd = None


try:
    import fcntl

    def _lock(fd: int) -> None:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def _unlock(fd: int) -> None:
        fcntl.flock(fd, fcntl.LOCK_UN)

except ImportError:  # pragma: no cover - Windows
    import msvcrt

    def _lock(fd: int) -> None:
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)

    def _unlock(fd: int) -> None:
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
