# Tailscale polish (Phase 8, feature 4; owner's choices 2026-11-22: all four)

## What the user sees
- **Addresses stay current.** Each time the app connects, the instance sends its addresses as they are
  now (home network, Tailscale name and IP). The phone saves them, keeping the route in use first.
  Turning Tailscale on later, or a new home IP, never needs pairing again.
- **Can't-connect help** (Reconnecting screen, and Hermes Instances when offline):
  - If the instance has a Tailscale address and this phone isn't on Tailscale, the screen says so,
    with **Turn On Tailscale**. That opens the Tailscale app, or the App Store if it isn't installed.
  - If the instance has no Tailscale address, it explains how to use Lekora away from home, with
    **Get Tailscale**.
- **Route in use.** Hermes Instances shows how the phone is connected (Home network / Tailscale /
  Internet), and every address it knows, with the one in use ticked.
- **Setup.** If pairing can't reach the instance, a short guide appears: the same Wi-Fi at home, or
  Tailscale on both devices, with a button.
- **On the Hermes machine.** When it isn't on Tailscale, `hermes lekora pair` ends with how to add it
  (https://tailscale.com/download), and says no re-pairing is needed afterwards.

## How it works
- **Plugin.** `hello.ack` carries `endpoints`, from the same lookup pairing uses
  (`routes.resolve_candidate_endpoints`), done at most once a minute.
  `pairing.is_tailscale` recognises 100.64.0.0/10 and `*.ts.net`.
- **App.**
  - `SavedHost.endpoints` is replaced by `[route in use] + current list` and saved.
  - `LKRoute.of` names an address's route.
  - `LKRoute.phoneOnTailscale()` looks for a 100.64.0.0/10 address on the phone's network interfaces,
    which is how Tailscale shows up when it's on.
  - Tailscale's app opens via `tailscale://`, falling back to its App Store page (id 1470499037).

## Protocol
- `hello.ack` adds `endpoints: [url]` (docs/protocol.md §5).
