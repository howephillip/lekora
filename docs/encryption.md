# Encrypted connections

Every connection between the phone and the Hermes machine is encrypted (`wss://`, TLS 1.2+), on home Wi-Fi and Tailscale alike. There's no domain, certificate authority or account.

## How it works
1. **The host makes its own certificate.** On first start the plugin creates one self-signed certificate (EC P-256, SHA-256, valid 20 years) and its private key. They live in `lekora-tls/` next to `lekora.db`; the folder and key are owner-only. Code: `plugin/lekora/tls.py`.
   - It uses `cryptography`, a pinned dependency of Hermes itself, so nothing needs installing. The `openssl` command is the fallback.
2. **The pairing code carries its fingerprint** (`fp=` in the `lekora-pair://` link and QR): base64url(SHA-256(certificate DER)), no padding, 43 characters.
3. **The phone pins it.** The app accepts the one certificate with that fingerprint and nothing else, even a certificate a public authority signed. Code: `app/Lekora/Services/PinnedTLS.swift`.
   - The fingerprint is saved with the pairing in the Keychain and used for every connection: probing, chat, reconnect and Forget Host.
4. **No plain connections, either side.** The host serves only TLS, so a plain `ws://` client is refused. The app refuses pairing links without a fingerprint or with `ws://` addresses, and never tries a `ws://` address.

## Why the app keeps `NSAllowsArbitraryLoads`
- While App Transport Security applies, an app can only tighten certificate checks; it can't accept a self-made certificate. The ATS exception is what allows the pinned certificate at all.
- Safety comes from the app itself: it only opens `wss://` connections and only accepts the pinned certificate.
- The TLS settings still meet Apple's ATS requirements: TLS 1.2+, P-256, SHA-256 and forward-secret ciphers.

## Edge cases
- **Pairings made before encryption** have no fingerprint. The app removes them on launch and asks you to pair again. Revoke the old device on the host with `hermes lekora devices`.
- **Certificate mismatch.** If a different certificate answers (an impostor, or the plugin's `lekora-tls/` folder was deleted and recreated), the phone refuses to connect. It says the certificate doesn't match and to pair again if Lekora was reinstalled.
- **`hermes lekora pair` before the certificate exists** (the gateway hasn't started since updating) asks you to restart the gateway.
- **Rotation:** none, deliberately. A new certificate means every phone must pair again.

## Tests
- Plugin, `tests/test_tls.py`:
  - certificate created once and reused across restarts
  - owner-only permissions
  - meets iOS requirements
  - `openssl` fallback
  - plain `ws://` refused
  - `wss://` advertised
- App, `LekoraTests/EncryptionTests.swift`:
  - the fingerprint matches what the plugin computes for the same certificate
  - only the pinned certificate is accepted
  - old or unencrypted links refused with an update message
  - old pairings must be redone
  - never falls back to a plain address
  - certificate mismatch told apart from an offline host
- Also checked once with the real app against the real plugin: right pin pairs, chats and reconnects; wrong pin is refused before anything is sent and gets the mismatch message.
