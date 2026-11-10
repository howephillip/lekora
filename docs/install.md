# Installing the Lekora host plugin

Run this **on the machine that runs Hermes** (not on your phone). Needs Hermes 0.22 or newer and nothing else: the plugin has no extra dependencies.

## One command

```bash
cp ~/.hermes/config.yaml ~/.hermes/config.yaml.pre-lekora && \
hermes plugins install howephillip/lekora#plugin/lekora --enable && \
hermes config set platforms.lekora.enabled true && \
hermes gateway restart && \
hermes lekora pair
```

What each step does:
1. Backs up your Hermes config.
2. Installs and enables the plugin from this repo (Hermes' own installer).
3. Turns on the `lekora` messaging platform. This and step 2 are the only two config changes (`plugins.enabled` gains `lekora-platform`; `platforms.lekora.enabled: true` is added).
4. Restarts the Hermes gateway so Lekora starts listening. If agents are busy, Hermes names the live work and asks before interrupting it.
5. Prints the pairing QR code, a `lekora-pair://` link and the code. It works once and expires in 30 minutes.

## Pairing the phone
- The phone and the Hermes machine must be able to reach each other: same Wi-Fi, or both on Tailscale. Lekora advertises every route it finds (LAN and Tailscale) and the app uses whichever answers first.
- In the Lekora app scan the QR code, or tap the link / use Paste Token.
- Over SSH from a phone terminal (e.g. Termius), run `hermes lekora pair --no-qr` and tap the link.

## Paired phones
- `hermes lekora devices` lists every phone ever paired: ID, name, active or revoked, and when it last connected.
- `hermes lekora devices --revoke <ID>` removes a phone (repeat `--revoke` for several). A connected phone is cut off at its next message; the app then forgets the host and shows its setup screen.
- "Forget Host" in the app also removes the phone here. If the host was unreachable at the time, the app says so; revoke it with the command above.

## Security
- Every connection is encrypted with a certificate the plugin creates itself; the pairing code carries its fingerprint and the phone accepts only that certificate. See `docs/encryption.md`.
- The certificate and key are in `~/.hermes/lekora-tls/` (owner-only). Deleting that folder means every phone must pair again.

## Where things live
- Data: `~/.hermes/lekora.db` (override with `LEKORA_DB_PATH`). Safe to keep across re-installs.
- The port is chosen once and saved in that database, so restarts keep the same address.
- Extra address to advertise (a domain you own): `hermes lekora pair --host my.domain.example`.

## Undo
```bash
hermes config set platforms.lekora.enabled false
hermes plugins disable lekora-platform   # or: hermes plugins remove lekora-platform
hermes gateway restart
```
Your config backup is `~/.hermes/config.yaml.pre-lekora`. Pairing data stays in `lekora.db` unless you delete it.
