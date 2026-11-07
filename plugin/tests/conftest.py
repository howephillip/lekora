import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from lekora.store import Store  # noqa: E402


class FakeClock:
    def __init__(self) -> None:
        self.now = datetime(2026, 11, 7, 12, 0, 0, tzinfo=timezone.utc)

    def __call__(self) -> datetime:
        return self.now

    def advance(self, **kw) -> None:
        self.now += timedelta(**kw)


@pytest.fixture
def clock() -> FakeClock:
    return FakeClock()


@pytest.fixture
def db_path(tmp_path) -> Path:
    return tmp_path / "lekora.db"


@pytest.fixture
def store(db_path, clock):
    s = Store(db_path, clock=clock)
    yield s
    s.close()
