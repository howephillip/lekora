"""Route discovery: which ws:// addresses can the phone use to reach this host.

Nothing here assumes a machine, OS, address or interface name. Anything that
touches the system (interface listing, Tailscale CLI) is injectable so tests
can run with fakes.
"""

from __future__ import annotations

import ipaddress
import json
import logging
import os
import re
import shutil
import subprocess
from typing import Callable, Iterable, Optional

log = logging.getLogger(__name__)

# Virtual / bridge / tunnel adapters whose addresses a phone cannot reach.
# (utun* is macOS's tunnel naming; Tailscale is discovered separately.)
VIRTUAL_PREFIXES = ("docker", "br-", "veth", "virbr", "tun", "tap", "utun", "lo")

TAILSCALE_PATHS = (
    "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    "/usr/local/bin/tailscale",
    "/opt/homebrew/bin/tailscale",
    "/usr/bin/tailscale",
    "/usr/sbin/tailscale",
    "/snap/bin/tailscale",
)

_CGNAT = ipaddress.ip_network("100.64.0.0/10")  # Tailscale's range, not LAN

InterfaceLister = Callable[[], list[tuple[str, str]]]
CommandRunner = Callable[[list[str]], Optional[str]]


def is_virtual_interface(name: str) -> bool:
    return name.startswith(VIRTUAL_PREFIXES)


def _run(cmd: list[str]) -> Optional[str]:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout if out.returncode == 0 else None


def list_interfaces(run: CommandRunner = _run) -> list[tuple[str, str]]:
    """Return (interface_name, ipv4) pairs using `ip` (Linux) or `ifconfig` (macOS/BSD)."""
    pairs: list[tuple[str, str]] = []
    out = run(["ip", "-o", "-4", "addr", "show"])
    if out:
        for line in out.splitlines():
            m = re.match(r"\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)", line)
            if m:
                pairs.append((m.group(1), m.group(2)))
        return pairs
    out = run(["ifconfig"])
    if out:
        current = None
        for line in out.splitlines():
            m = re.match(r"^(\S+?):\s+flags", line)
            if m:
                current = m.group(1)
                continue
            m = re.match(r"^\s+inet\s+(\d+\.\d+\.\d+\.\d+)", line)
            if m and current:
                pairs.append((current, m.group(1)))
    return pairs


def lan_addresses(lister: InterfaceLister = list_interfaces) -> list[str]:
    """Routable private-network IPv4s, with virtual adapters and non-LAN ranges removed."""
    found: list[str] = []
    for name, addr in lister():
        if is_virtual_interface(name):
            continue
        try:
            ip = ipaddress.ip_address(addr)
        except ValueError:
            continue
        if ip.is_loopback or ip.is_link_local or ip in _CGNAT or ip.is_unspecified:
            continue
        if addr not in found:
            found.append(addr)
    return found


def find_tailscale(which: Callable[[str], Optional[str]] = shutil.which,
                   exists: Callable[[str], bool] = os.path.exists) -> Optional[str]:
    on_path = which("tailscale")
    if on_path:
        return on_path
    for p in TAILSCALE_PATHS:
        if exists(p):
            return p
    return None


def tailscale_hosts(run: CommandRunner = _run,
                    binary: Optional[str] = None) -> list[str]:
    """MagicDNS name (if any) followed by Tailscale IPs. Empty if Tailscale is absent/down."""
    binary = binary or find_tailscale()
    if not binary:
        return []
    out = run([binary, "status", "--json"])
    if not out:
        return []
    try:
        data = json.loads(out)
        me = data.get("Self") or {}
    except (ValueError, AttributeError):
        log.warning("Could not parse `tailscale status --json` output")
        return []
    if data.get("BackendState") not in (None, "Running"):
        return []
    hosts: list[str] = []
    dns = (me.get("DNSName") or "").rstrip(".")
    if dns:
        hosts.append(dns)
    for ip in me.get("TailscaleIPs") or []:
        try:
            if ipaddress.ip_address(ip).version == 4:
                hosts.append(ip)
        except ValueError:
            continue
    return hosts


def resolve_candidate_endpoints(
    port: int,
    configured_hosts: Iterable[str] = (),
    lister: InterfaceLister = list_interfaces,
    tailscale: Callable[[], list[str]] = tailscale_hosts,
) -> list[str]:
    """ws:// URLs the phone can try: LAN first, then Tailscale, then user-configured hosts."""
    hosts: list[str] = []
    for h in [*lan_addresses(lister), *tailscale(), *configured_hosts]:
        h = h.strip()
        if h and h not in hosts:
            hosts.append(h)
    return [f"ws://{h}:{int(port)}" for h in hosts]
