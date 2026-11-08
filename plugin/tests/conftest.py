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


@pytest.fixture(autouse=True)
def fake_hermes_root(tmp_path, monkeypatch):
    """Profile discovery must never read the real ~/.hermes in tests."""
    root = tmp_path / "hermes-root"
    root.mkdir()
    (root / "config.yaml").write_text("model: test\n")
    import lekora.profiles
    monkeypatch.setattr(lekora.profiles, "hermes_root", lambda: root)
    return root


@pytest.fixture(autouse=True)
def no_real_hermes_cli(monkeypatch):
    """Tests must never run the real `hermes` command (it would change this machine's Hermes)."""
    import lekora.profile_admin

    def refuse():
        raise AssertionError("a test tried to run the real hermes CLI")
    monkeypatch.setattr(lekora.profile_admin, "hermes_command", refuse)


class FakeHermesCli:
    """Acts like `hermes profile create/export/delete` on the fake Hermes root."""

    def __init__(self, root):
        self.root = root
        self.calls = []
        self.fail = {}        # subcommand -> (exit code, output)
        self.empty_export = False

    async def __call__(self, args):
        self.calls.append(list(args))
        sub, name = args[1], args[2]
        if sub in self.fail:
            return self.fail[sub]
        home = self.root / "profiles" / name
        if sub == "create":
            home.mkdir(parents=True)
            (home / "config.yaml").write_text("model: cloned\n")
            if "--description" in args:
                desc = args[args.index("--description") + 1]
                (home / "profile.yaml").write_text(f"description: {desc}\n")
            return 0, f"Created profile {name}\n"
        if sub == "export":
            out = args[args.index("-o") + 1]
            Path(out).write_bytes(b"" if self.empty_export else b"archive")
            return 0, f"Exported to {out}\n"
        if sub == "delete":
            import shutil
            shutil.rmtree(home)
            return 0, f"Deleted {name}\n"
        return 2, "unknown"


@pytest.fixture
def fake_cli(fake_hermes_root):
    return FakeHermesCli(fake_hermes_root)


@pytest.fixture
def tls_identity(store):
    """The certificate the gateway creates on first start, next to the test store."""
    from lekora.tls import ensure_identity, tls_dir_for
    return ensure_identity(tls_dir_for(store.path))


def pinned_client_ssl():
    """A TLS client context for tests; callers check the pin with `assert_pinned`
    (the phone does the same: accept only the certificate whose fingerprint it was given)."""
    import ssl
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


def peer_fingerprint(ws):
    from lekora.tls import fingerprint_of_der
    return fingerprint_of_der(ws.transport.get_extra_info("ssl_object").getpeercert(binary_form=True))
