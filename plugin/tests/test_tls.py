import asyncio
import base64
import datetime
import hashlib
import stat

import pytest
from conftest import peer_fingerprint, pinned_client_ssl
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from websockets.asyncio.client import connect

from lekora import tls
from lekora.plugin import LekoraConfig, LekoraService


class FakeHermes:
    async def deliver_to_agent(self, profile_id, text, message_id):
        pass


def service(tmp_path):
    return LekoraService(FakeHermes(), LekoraConfig(db_path=str(tmp_path / "lekora.db"),
                                                     listen_host="127.0.0.1"), check_version=False)


def test_identity_is_created_once_and_reused(tmp_path):
    d = tmp_path / "lekora-tls"
    first = tls.ensure_identity(d)
    second = tls.ensure_identity(d)
    assert first.fingerprint == second.fingerprint
    assert stat.S_IMODE(d.stat().st_mode) == 0o700
    assert stat.S_IMODE(first.key_path.stat().st_mode) == 0o600   # private key: owner only


def test_certificate_meets_ios_requirements(tmp_path):
    ident = tls.ensure_identity(tmp_path / "t")
    cert = x509.load_pem_x509_certificate(ident.cert_path.read_bytes())
    assert isinstance(cert.public_key(), ec.EllipticCurvePublicKey)
    assert cert.public_key().curve.name == "secp256r1"              # ECC >= 256 bits
    assert isinstance(cert.signature_hash_algorithm, hashes.SHA256)  # SHA-2, 256 bits
    years = (cert.not_valid_after_utc - datetime.datetime.now(datetime.timezone.utc)).days / 365
    assert years > 19                                                # no surprise expiry
    der = cert.public_bytes(serialization.Encoding.DER)
    expected = base64.urlsafe_b64encode(hashlib.sha256(der).digest()).rstrip(b"=").decode()
    assert ident.fingerprint == expected and len(expected) == 43     # what the phone computes


def test_openssl_fallback_when_cryptography_is_missing(tmp_path, monkeypatch):
    import shutil
    if not shutil.which("openssl"):
        pytest.skip("no openssl command here")

    def missing(_name):
        raise ImportError("no cryptography")
    monkeypatch.setattr(tls, "_generate_with_cryptography", missing)
    ident = tls.ensure_identity(tmp_path / "o")
    cert = x509.load_pem_x509_certificate(ident.cert_path.read_bytes())
    assert cert.public_key().curve.name == "secp256r1"
    ident.server_context()  # loads as a TLS server identity


def test_half_written_identity_is_not_used(tmp_path):
    d = tmp_path / "h"
    d.mkdir()
    (d / tls.KEY_FILE).write_text("partial")
    assert tls.load_identity(d) is None   # needs both files


async def test_service_speaks_only_tls_with_the_pinned_certificate(tmp_path):
    svc = service(tmp_path)
    port = await svc.start()
    try:
        ws = await connect(f"wss://127.0.0.1:{port}", ssl=pinned_client_ssl())
        assert peer_fingerprint(ws) == svc.tls.fingerprint
        await ws.close()

        # Plain ws:// is refused: no unencrypted connection gets through.
        with pytest.raises(Exception):
            plain = await asyncio.wait_for(connect(f"ws://127.0.0.1:{port}", open_timeout=2), 3)
            await plain.close()
    finally:
        await svc.stop()


async def test_certificate_survives_restart_so_paired_phones_keep_working(tmp_path):
    a = service(tmp_path)
    await a.start()
    fp = a.tls.fingerprint
    await a.stop()
    b = service(tmp_path)
    await b.start()
    try:
        assert b.tls.fingerprint == fp
        assert (tmp_path / "lekora-tls" / "cert.pem").is_file()
    finally:
        await b.stop()


async def test_pair_response_advertises_wss(tmp_path):
    svc = service(tmp_path)
    await svc.start()
    try:
        assert all(e.startswith("wss://") for e in svc.endpoints())
    finally:
        await svc.stop()
