# Lekora

A native iPhone app that sits **on top of any existing Hermes instance**, plus the **plugin** that connects the two.

- **App** (`app/`): SwiftUI, iOS 27 primary, iOS 26 minimum.
- **Plugin** (`plugin/`): installed on the Hermes machine by the user. It is the only technical setup required.
- **Protocol** (`protocol/`): the versioned contract between them.

## Hardware-agnostic rule

Nothing here may assume a particular machine. The plugin must run wherever Hermes runs (Linux, macOS, Windows/WSL, Raspberry Pi, VPS), use only the standard library, pick free ports itself, and store files in Hermes's own data directory. Anything specific to one person is a setting with a default.

See `docs/` for the spec, protocol, data model and decisions. `STATUS.md` is the live status.
