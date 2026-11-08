"""Encrypted connections (wss://) with a certificate the plugin makes itself.

The plugin creates one self-signed certificate (EC P-256, SHA-256) the first time it
starts, stored with its private key in an app-owned folder next to lekora.db
(``lekora-tls/``, owner-only). Pairing codes carry the certificate's fingerprint;
the phone accepts this one certificate only ("pinning"), so connections are
encrypted and authenticated on home Wi-Fi and Tailscale alike, with no domain,
certificate authority or account.

The fingerprint is base64url(SHA-256(certificate DER)), without padding. The
certificate is valid for 20 years and is never rotated automatically: a new one
would need every phone to pair again.

Certificates are made with ``cryptography``, a pinned dependency of Hermes itself
(nothing extra to install); the ``openssl`` command is the fallback.
"""

from __future__ import annotations

import base64
import datetime
import hashlib
import os
import secrets
import shutil
import ssl
import subprocess
from dataclasses import dataclass
from pathlib import Path

TLS_DIR_NAME = "lekora-tls"
CERT_FILE = "cert.pem"
KEY_FILE = "key.pem"
VALID_DAYS = 365 * 20


class TLSUnavailable(RuntimeError):
    """No way to create the certificate on this machine."""


@dataclass(frozen=True)
class TLSIdentity:
    cert_path: Path
    key_path: Path
    fingerprint: str

    def server_context(self) -> ssl.SSLContext:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.minimum_version = ssl.TLSVersion.TLSv1_2  # also what iOS requires
        ctx.load_cert_chain(str(self.cert_path), str(self.key_path))
        return ctx


def tls_dir_for(db_path: Path) -> Path:
    return Path(db_path).parent / TLS_DIR_NAME


def fingerprint_of_der(der: bytes) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(der).digest()).rstrip(b"=").decode("ascii")


def fingerprint_of_pem(pem: str) -> str:
    return fingerprint_of_der(ssl.PEM_cert_to_DER_cert(pem))


def load_identity(directory: Path) -> TLSIdentity | None:
    """The existing certificate, or None if the gateway has not created one yet."""
    cert, key = Path(directory) / CERT_FILE, Path(directory) / KEY_FILE
    if not (cert.is_file() and key.is_file()):
        return None
    return TLSIdentity(cert, key, fingerprint_of_pem(cert.read_text()))


def ensure_identity(directory: Path, common_name: str = "Lekora") -> TLSIdentity:
    """Load the certificate, creating it (once) if it doesn't exist."""
    existing = load_identity(directory)
    if existing is not None:
        return existing
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    cert_pem, key_pem = _generate(common_name)
    key_path, cert_path = directory / KEY_FILE, directory / CERT_FILE
    # Key first, created owner-only; the certificate last, so a half-written pair is
    # never mistaken for a complete one (load_identity needs both files).
    fd = os.open(str(key_path), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(key_pem)
    cert_path.write_bytes(cert_pem)
    return TLSIdentity(cert_path, key_path, fingerprint_of_pem(cert_pem.decode()))


def _generate(common_name: str) -> tuple[bytes, bytes]:
    try:
        return _generate_with_cryptography(common_name)
    except ImportError:
        return _generate_with_openssl(common_name)


def _generate_with_cryptography(common_name: str) -> tuple[bytes, bytes]:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common_name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(int.from_bytes(secrets.token_bytes(16), "big") >> 1)
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=VALID_DAYS))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    key_pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
    return cert.public_bytes(serialization.Encoding.PEM), key_pem


def _generate_with_openssl(common_name: str) -> tuple[bytes, bytes]:
    openssl = shutil.which("openssl")
    if not openssl:
        raise TLSUnavailable("Can't create Lekora's certificate: neither the 'cryptography' "
                             "package nor the 'openssl' command is available")
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        key, cert = Path(tmp) / "k.pem", Path(tmp) / "c.pem"
        subprocess.run(
            [openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
             "-nodes", "-sha256", "-days", str(VALID_DAYS), "-subj", f"/CN={common_name}",
             "-keyout", str(key), "-out", str(cert)],
            check=True, capture_output=True, timeout=60)
        return cert.read_bytes(), key.read_bytes()
