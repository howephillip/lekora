import json

from lekora import routes


def fake_lister(pairs):
    return lambda: pairs


def test_bridge_and_virtual_adapters_filtered():
    pairs = [
        ("lo", "127.0.0.1"),
        ("eth0", "192.168.1.120"),
        ("docker0", "172.17.0.1"),
        ("br-1a2b3c", "172.18.0.1"),
        ("veth9f", "172.19.0.2"),
        ("virbr0", "192.168.122.1"),
        ("tun0", "10.8.0.2"),
        ("tap0", "10.9.0.2"),
        ("utun3", "10.10.0.2"),
    ]
    assert routes.lan_addresses(fake_lister(pairs)) == ["192.168.1.120"]


def test_non_lan_ranges_excluded_and_deduped():
    pairs = [
        ("en0", "10.0.0.5"),
        ("en0", "10.0.0.5"),
        ("en1", "169.254.3.4"),
        ("en2", "100.101.102.103"),  # Tailscale CGNAT range, not LAN
        ("en3", "garbage"),
    ]
    assert routes.lan_addresses(fake_lister(pairs)) == ["10.0.0.5"]


def test_list_interfaces_parses_linux_ip():
    out = (
        "1: lo    inet 127.0.0.1/8 scope host lo\n"
        "2: eth0    inet 192.168.1.50/24 brd 192.168.1.255 scope global eth0\n"
    )
    run = lambda cmd: out if cmd[0] == "ip" else None
    assert routes.list_interfaces(run) == [("lo", "127.0.0.1"), ("eth0", "192.168.1.50")]


def test_list_interfaces_parses_macos_ifconfig():
    out = (
        "lo0: flags=8049<UP> mtu 16384\n\tinet 127.0.0.1 netmask 0xff000000\n"
        "en0: flags=8863<UP> mtu 1500\n\tinet6 fe80::1%en0 prefixlen 64\n"
        "\tinet 192.168.0.9 netmask 0xffffff00 broadcast 192.168.0.255\n"
    )
    run = lambda cmd: out if cmd[0] == "ifconfig" else None
    assert routes.list_interfaces(run) == [("lo0", "127.0.0.1"), ("en0", "192.168.0.9")]


def test_list_interfaces_no_tools_returns_empty():
    assert routes.list_interfaces(lambda cmd: None) == []


TS_JSON = json.dumps({
    "BackendState": "Running",
    "Self": {
        "DNSName": "hermes-host.tailnet01.ts.net.",
        "TailscaleIPs": ["100.64.1.2", "fd7a:115c:a1e0::1"],
    },
})


def test_tailscale_hosts_parsed():
    run = lambda cmd: TS_JSON
    assert routes.tailscale_hosts(run, binary="/x/tailscale") == [
        "hermes-host.tailnet01.ts.net", "100.64.1.2"]


def test_tailscale_absent_or_stopped_or_malformed():
    assert routes.tailscale_hosts(lambda c: None, binary="/x") == []
    assert routes.tailscale_hosts(lambda c: "not json", binary="/x") == []
    stopped = json.dumps({"BackendState": "Stopped", "Self": {"DNSName": "a.ts.net."}})
    assert routes.tailscale_hosts(lambda c: stopped, binary="/x") == []


def test_find_tailscale_prefers_path_then_known_locations():
    assert routes.find_tailscale(lambda n: "/p/tailscale", lambda p: False) == "/p/tailscale"
    mac = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
    assert routes.find_tailscale(lambda n: None, lambda p: p == mac) == mac
    assert routes.find_tailscale(lambda n: None, lambda p: False) is None


def test_resolve_candidate_endpoints_order_and_dedupe():
    eps = routes.resolve_candidate_endpoints(
        49152,
        configured_hosts=["hermes.example.com", "192.168.1.120", " "],
        lister=fake_lister([("eth0", "192.168.1.120"), ("docker0", "172.17.0.1")]),
        tailscale=lambda: ["hermes-host.tailnet01.ts.net", "100.64.1.2"],
    )
    assert eps == [
        "ws://192.168.1.120:49152",
        "ws://hermes-host.tailnet01.ts.net:49152",
        "ws://100.64.1.2:49152",
        "ws://hermes.example.com:49152",
    ]


def test_resolve_with_nothing_available_is_empty():
    assert routes.resolve_candidate_endpoints(
        1, lister=fake_lister([]), tailscale=lambda: []) == []
