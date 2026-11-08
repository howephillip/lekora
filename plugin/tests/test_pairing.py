import io
import re
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


def test_render_never_draws_dark_as_a_glyph():
    # Terminals may offset glyphs vertically; backgrounds always fill the cell.
    # Every cell must be a coloured space or a WHITE half block on BLACK.
    m = qr.make_qr("lekora-pair://pair?token=abc&instance_id=inst_1&endpoints=ws://h:1")
    cells = re.findall(r"\x1b\[([\d;]+)m(.)", qr.render_ansi(m, quiet=4))
    assert cells and all(
        (ch == " " and codes in ("40", "107")) or (ch in "▀▄" and codes == "97;40")
        for codes, ch in cells)


def test_render_matches_matrix():
    m = qr.make_qr("HELLO")
    quiet = 4
    size = len(m) + 2 * quiet

    def dark(x, y):
        return 0 <= x - quiet < len(m) and 0 <= y - quiet < len(m) and m[y - quiet][x - quiet]

    for line_no, line in enumerate(qr.render_ansi(m, quiet=quiet).split("\n")):
        cells = re.findall(r"\x1b\[([\d;]+)m(.)", line)
        assert len(cells) == size
        for x, (codes, ch) in enumerate(cells):
            drawn_top = codes == "40" if ch == " " else ch == "▄"
            drawn_bottom = codes == "40" if ch == " " else ch == "▀"
            assert (drawn_top, drawn_bottom) == (dark(x, 2 * line_no), dark(x, 2 * line_no + 1))


# ---- `hermes lekora devices` -------------------------------------------------

def test_devices_empty_list(store):
    out = io.StringIO()
    assert pairing.run_devices(store, out) == 0
    assert "No devices are paired yet" in out.getvalue()


def test_devices_table(store, clock):
    active_id, _ = store.register_device("iPhone", "1.0.0")
    clock.advance(minutes=30)
    revoked_id, _ = store.register_device("Old iPhone", "1.0.0")
    store.revoke_device(revoked_id)
    out = io.StringIO()
    assert pairing.run_devices(store, out) == 0
    lines = out.getvalue().splitlines()
    assert lines[0].split() == ["ID", "Name", "Status", "Last", "seen"]
    active_row = next(line for line in lines if line.startswith(active_id))
    revoked_row = next(line for line in lines if line.startswith(revoked_id))
    assert "iPhone" in active_row and "active" in active_row and "2026-11-07 12:00 UTC" in active_row
    assert "Old iPhone" in revoked_row and "revoked" in revoked_row and "12:30 UTC" in revoked_row
    assert "1 active, 1 revoked" in out.getvalue()
    # Columns line up: every Status value starts at the same position.
    assert active_row.index("active") == revoked_row.index("revoked") == lines[0].index("Status")


def test_devices_revoke(store):
    device_id, token = store.register_device("iPhone")
    out = io.StringIO()
    assert pairing.run_devices(store, out, revoke=[device_id]) == 0
    assert f"Revoked {device_id} (iPhone)" in out.getvalue()
    assert not store.verify_device_token(device_id, token)
    assert not store.list_devices()[0].active


def test_devices_revoke_unknown_and_already_revoked(store):
    device_id, _ = store.register_device()
    store.revoke_device(device_id)
    out = io.StringIO()
    assert pairing.run_devices(store, out, revoke=[device_id, "dev_nope"]) == 1
    text = out.getvalue()
    assert f"{device_id} was already revoked" in text
    assert "No device with ID dev_nope" in text


def test_devices_revoke_several(store):
    ids = [store.register_device(f"phone {i}")[0] for i in range(3)]
    out = io.StringIO()
    assert pairing.run_devices(store, out, revoke=ids[:2]) == 0
    assert [d.active for d in store.list_devices()] == [False, False, True]


def test_cli_wiring_for_devices(monkeypatch, tmp_path, capsys):
    import argparse
    monkeypatch.setenv("LEKORA_DB_PATH", str(tmp_path / "cli.db"))
    from lekora.store import Store
    setup = Store()
    device_id, _ = setup.register_device("iPhone")
    setup.close()

    parser = argparse.ArgumentParser(prog="hermes lekora")
    pairing.setup_cli(parser)
    assert pairing.handle_cli(parser.parse_args(["devices"])) == 0
    assert device_id in capsys.readouterr().out

    assert pairing.handle_cli(parser.parse_args(["devices", "--revoke", device_id])) == 0
    assert "Revoked" in capsys.readouterr().out
    check = Store()
    assert not check.is_device_active(device_id)
    check.close()
