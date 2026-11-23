"""Tailscale polish (docs/tailscale.md): the phone learns the instance's current addresses on every
connection, and pairing says how to reach Hermes away from home."""

from datetime import datetime

from lekora.pairing import Invite, format_pairing_output, is_tailscale
from tests.test_gateway import gw, recv  # noqa: F401  (gw fixture)
from tests.test_history import hello_rev


async def test_every_connection_carries_the_current_addresses(gw, store):
    addresses = ["wss://192.168.1.20:40225", "wss://box.tail1.ts.net:40225", "wss://100.88.1.2:40225"]
    gw._endpoints = lambda port: addresses
    device_id, tok = store.register_device("iPhone")
    ws = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    ack = await recv(ws)
    assert ack["type"] == "hello.ack" and ack["data"]["endpoints"] == addresses
    addresses = ["wss://192.168.1.99:40225"]  # a new home address: looked up again within a minute
    gw._endpoints_cache = (0.0, [])
    gw._endpoints = lambda port: addresses
    ws2 = await hello_rev(gw, store, device_id, tok, since_rev=store.current_rev())
    assert (await recv(ws2))["data"]["endpoints"] == ["wss://192.168.1.99:40225"]


def test_tailscale_addresses_are_recognised():
    assert is_tailscale("wss://100.88.44.108:40225") and is_tailscale("wss://howeitsdone.tail203404.ts.net:40225")
    assert not is_tailscale("wss://192.168.8.121:40225") and not is_tailscale("wss://my.domain.example:40225")


def test_pairing_says_how_to_reach_hermes_away_from_home():
    expires = datetime(2026, 11, 22, 12, 0)
    home_only = format_pairing_output(Invite("t", "i", ["wss://192.168.1.2:1"], "lekora-pair://x", expires), show_qr=False)
    assert "tailscale.com/download" in home_only
    with_tailnet = format_pairing_output(Invite("t", "i", ["wss://192.168.1.2:1", "wss://100.88.1.2:1"],
                                                "lekora-pair://x", expires), show_qr=False)
    assert "tailscale.com/download" not in with_tailnet
