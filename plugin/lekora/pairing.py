"""`hermes lekora pair`: create a one-time invite and show it as QR + link + token.

`hermes lekora devices`: list paired phones and revoke old ones."""

from __future__ import annotations

import socket
from dataclasses import dataclass
from datetime import datetime
from typing import Callable, Iterable, Optional, TextIO
from urllib.parse import quote

from .qr import make_qr, render_ansi
from .routes import resolve_candidate_endpoints
from .store import INVITE_TTL, Device, Store

SCHEME = "lekora-pair://pair"


@dataclass(frozen=True)
class Invite:
    token: str
    instance_id: str
    endpoints: list[str]
    uri: str
    expires_at: datetime


def build_invite_uri(token: str, instance_id: str, endpoints: Iterable[str]) -> str:
    # The whole comma-separated list is percent-encoded as one query value;
    # the app decodes it and splits on commas.
    csv = quote(",".join(endpoints), safe="")
    return f"{SCHEME}?token={quote(token, safe='')}&instance_id={quote(instance_id, safe='')}&endpoints={csv}"


class NoPortYet(RuntimeError):
    """Lekora has never started on this machine, so there is no port to advertise."""


def create_invite(
    store: Store,
    extra_hosts: Iterable[str] = (),
    endpoints_fn: Callable[..., list[str]] = resolve_candidate_endpoints,
) -> Invite:
    port = store.get_persisted_port()
    if not port:
        raise NoPortYet(
            "Lekora has not started yet. Start Hermes with the Lekora platform enabled, "
            "then run this command again.")
    endpoints = endpoints_fn(port, list(extra_hosts))
    if not endpoints:
        raise RuntimeError(
            "No reachable network address was found. Connect this machine to a network "
            "(or Tailscale), or pass --host <name-or-ip>.")
    token = store.create_invite()
    return Invite(token, store.instance_id, endpoints,
                  build_invite_uri(token, store.instance_id, endpoints),
                  store.now() + INVITE_TTL)


def format_pairing_output(invite: Invite, show_qr: bool = True) -> str:
    parts = []
    if show_qr:
        parts += ["Scan this with the Lekora app:", "", render_ansi(make_qr(invite.uri)), ""]
    parts += [
        "Or, on your phone, tap this link (or copy it into Lekora > Paste Token):",
        "",
        invite.uri,
        "",
        "Routes your phone will try: " + ", ".join(invite.endpoints),
        f"This code works once and expires at {invite.expires_at:%H:%M} UTC (30 minutes).",
    ]
    return "\n".join(parts)


def _gateway_listening(port: int) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def run_pair(
    store: Store,
    out: TextIO,
    extra_hosts: Iterable[str] = (),
    show_qr: bool = True,
    listening: Callable[[int], bool] = _gateway_listening,
) -> int:
    """Returns a process exit code."""
    try:
        invite = create_invite(store, extra_hosts)
    except (NoPortYet, RuntimeError) as exc:
        print(str(exc), file=out)
        return 1
    print(format_pairing_output(invite, show_qr), file=out)
    port = store.get_persisted_port()
    if port and not listening(port):
        print("\nNote: Lekora does not seem to be running right now. "
              "Start Hermes before scanning, or the phone won't connect.", file=out)
    return 0


# ---- `hermes lekora devices` -----------------------------------------------

def _when(iso: Optional[str]) -> str:
    """'2026-11-07T19:44:05Z' -> '2026-11-07 19:44 UTC'."""
    if not iso:
        return "never"
    return iso.replace("T", " ")[:16] + " UTC"


def format_device_table(devices: list[Device]) -> str:
    if not devices:
        return "No devices are paired yet. Run `hermes lekora pair` to pair the Lekora app."
    header = ("ID", "Name", "Status", "Last seen")
    rows = [(d.device_id, d.device_name or "(unnamed)",
             "active" if d.active else "revoked", _when(d.last_seen_at)) for d in devices]
    widths = [max(len(r[i]) for r in [header, *rows]) for i in range(len(header))]

    def line(cells) -> str:
        return "  ".join(c.ljust(w) for c, w in zip(cells, widths)).rstrip()

    active = sum(d.active for d in devices)
    return "\n".join([line(header), line("-" * w for w in widths), *map(line, rows), "",
                      f"{active} active, {len(devices) - active} revoked. "
                      "Revoke one with: hermes lekora devices --revoke <ID>"])


def run_devices(store: Store, out: TextIO, revoke: Iterable[str] = ()) -> int:
    """Lists devices, or revokes the given IDs. Returns a process exit code."""
    to_revoke = list(revoke)
    if not to_revoke:
        print(format_device_table(store.list_devices()), file=out)
        return 0

    known = {d.device_id: d for d in store.list_devices()}
    code = 0
    for device_id in to_revoke:
        device = known.get(device_id)
        if device is None:
            print(f"No device with ID {device_id}. Run `hermes lekora devices` to see the IDs.",
                  file=out)
            code = 1
        elif store.revoke_device(device_id):
            print(f"Revoked {device_id} ({device.device_name or 'unnamed'}). It is disconnected "
                  "at its next message and must pair again to reconnect.", file=out)
        else:
            print(f"{device_id} was already revoked.", file=out)
    return code


# ---- Hermes CLI wiring (`hermes lekora pair|devices`) ------------------------

def setup_cli(parser) -> None:
    sub = parser.add_subparsers(dest="lekora_command")
    pair = sub.add_parser("pair", help="Create a one-time code to pair the Lekora iPhone app")
    pair.add_argument("--no-qr", action="store_true", help="Show only the link and code")
    pair.add_argument("--host", action="append", default=[],
                      help="Extra host name or IP to advertise (repeatable)")
    devices = sub.add_parser("devices", help="List paired phones, or revoke one")
    devices.add_argument("--revoke", action="append", default=[], metavar="DEVICE_ID",
                         help="Revoke this device so it can no longer connect (repeatable)")
    parser.set_defaults(lekora_parser=parser)


def handle_cli(args) -> int:
    import sys
    command = getattr(args, "lekora_command", None)
    if command not in ("pair", "devices"):
        args.lekora_parser.print_help()
        return 0
    store = Store()
    try:
        if command == "devices":
            return run_devices(store, sys.stdout, args.revoke)
        return run_pair(store, sys.stdout, args.host, show_qr=not args.no_qr)
    finally:
        store.close()
