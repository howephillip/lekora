import io
from urllib.parse import parse_qs, urlparse

import pytest

from lekora import pairing, qr
from lekora.pairing import NoPortYet, create_invite, run_pair

EPS = ["ws://192.168.1.120:49152", "ws://hermes-host.tailnet01.ts.net:49152", "ws://100.64.1.2:49152"]


def eps_fn(port, hosts):
    return [e.replace("49152", str(port)) for e in EPS] + [f"ws://{h}:{port}" for h in hosts]


def test_uri_roundtrips_the_way_the_ios_app_parses_it():
    uri = pairing.build_invite_uri("tok-_Ab", "inst_1234", EPS)
    u = urlparse(uri)
    assert (u.scheme, u.netloc, u.path) == ("lekora-pair", "pair", "")
    q = parse_qs(u.query)  # percent-decodes, like URLComponents.queryItems
    assert q["token"] == ["tok-_Ab"] and q["instance_id"] == ["inst_1234"]
    assert q["endpoints"][0].split(",") == EPS


def test_no_port_yet_is_plain_language(store):
    with pytest.raises(NoPortYet) as e:
        create_invite(store, endpoints_fn=eps_fn)
    assert "Start Hermes" in str(e.value)


def test_invite_is_stored_hashed_single_use_and_expires(store):
    store.set_persisted_port(50000)
    inv = create_invite(store, ["h.example.com"], endpoints_fn=eps_fn)
    assert inv.endpoints[0] == "ws://192.168.1.120:50000" and inv.endpoints[-1] == "ws://h.example.com:50000"
    assert inv.instance_id == store.instance_id
    assert (inv.expires_at - store.now()).total_seconds() == 30 * 60
    assert inv.token not in open(store._db.execute("PRAGMA database_list").fetchone()[2], "rb").read().decode("latin1")
    store.consume_invite(inv.token)  # works once


def test_run_pair_output_and_warning_when_not_running(store):
    store.set_persisted_port(50000)
    out = io.StringIO()
    code = run_pair(store, out, listening=lambda p: False)
    text = out.getvalue()
    assert code == 0
    assert "lekora-pair://pair?token=" in text and "expires at" in text
    assert "▀" in text and "\x1b[" in text            # QR drawn with colored half blocks
    assert "does not seem to be running" in text


def test_run_pair_no_qr_and_running(store):
    store.set_persisted_port(50000)
    out = io.StringIO()
    run_pair(store, out, show_qr=False, listening=lambda p: True)
    assert "▀" not in out.getvalue() and "does not seem" not in out.getvalue()


def test_run_pair_before_first_start_returns_error(store):
    out = io.StringIO()
    assert run_pair(store, out) == 1 and "Start Hermes" in out.getvalue()


def test_qr_matrix_shapes():
    for text, size in (("HELLO", 21), ("x" * 100, 37)):
        m = qr.make_qr(text)
        assert len(m) == size and all(len(r) == size for r in m)
    # finder pattern top-left: 7x7 ring with solid 3x3 core
    m = qr.make_qr("HELLO")
    assert all(m[0][x] for x in range(7)) and not m[1][1] and m[3][3]


def test_qr_too_long():
    with pytest.raises(qr.QRTooLong):
        qr.make_qr("x" * 3000)


def test_render_dimensions():
    m = qr.make_qr("HELLO")
    lines = qr.render_ansi(m, quiet=4).split("\n")
    assert len(lines) == (21 + 8 + 1) // 2
