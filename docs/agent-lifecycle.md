# Agent lifecycle: create and delete from the phone

Every Hermes profile is an agent, and all are equal (AGENTS.md rule 5), so the phone can create and delete them. `default` is the one exception: Hermes itself refuses to delete it.

## How the host does it
The plugin runs Hermes' own CLI as a **separate process** (`hermes profile …`), never in-process: deleting notifies the running gateway (the one Lekora lives in) over its control socket, which would deadlock if called from inside it. Hermes then serves new profiles and stops serving deleted ones without a restart. The CLI is Hermes' stable, user-facing interface.

- **Create:** `hermes profile create <id> --clone-from default --no-alias [--description <text>]`.
  - Cloning gives the new agent a working model, keys, SOUL and skills straight away.
  - Hermes strips messaging channels and platform sections from clones, so the new profile does not start a second Lekora.
  - `--no-alias` skips the shell wrapper script.
- **Delete:** back up first, then `hermes profile delete <id> --yes` (the phone already confirmed).

### Names
- The user types a name, e.g. "Research Assistant". The id is derived: lowercase, other characters become `-`, at most 64 characters (`research-assistant`).
- The phone shows the readable form of the id ("Research assistant"). Hermes has no CLI for a named profile's display name, and writing Hermes' own profile files would break rule 8.

### Cloned agents and Lekora (found 2026-11-08)
- A clone of `default` can still carry what enables Lekora. Hermes then starts a second Lekora inside the new agent's profile.
- That copy once took a new port and overwrote the saved one, so new pairing codes advertised a dead port.
- The plugin now prevents this three ways:
  - **Default profile only.** A copy inside any other profile stays idle and logs that it did; it also isn't made that agent's home channel.
  - **One copy per machine.** The running copy holds a lock next to `lekora.db`, so any other copy stays out.
  - **Pair checks first.** `hermes lekora pair` refuses to print a code if nothing answers on the saved port.

## Safeguards (delete)
1. **Explicit confirmation.** The phone asks first, naming the agent and host and saying a backup is kept. The request must also carry `confirm` equal to the `profile_id`; the host refuses without it.
2. **Never `default`.** Refused with `CANNOT_DELETE_DEFAULT` before anything runs.
3. **Backup first, abort if it fails.** The backup goes to an app-owned folder, `<hermes root>/lekora-backups/profiles/` (owner-only permissions; it contains the profile's keys). It holds:
   - `<id>-<timestamp>.tar.gz`: Hermes' own `hermes profile export` of the profile.
   - `<id>-<timestamp>-lekora-chat.json`: Lekora's chat history for that agent.

   If either is missing or empty, nothing is deleted (`BACKUP_FAILED`).
4. **One operation at a time.** Operations are serialized on the host.
5. **Chat history** for the deleted agent is removed from Lekora's store only after Hermes confirms the delete, so a recreated agent with the same name starts clean. It stays in the backup.
6. **Pinned profiles.** If `platforms.lekora.extra.profiles` pins a fixed list, create and delete are refused (`PROFILE_ADMIN_UNAVAILABLE`). The host owner has chosen which agents the phone sees.

## Protocol
Both requests need an authenticated, non-revoked device. The host replies to the requester with an ack carrying the same `id`, then broadcasts `profiles.changed` to every connected device (including the requester).

```json
{ "type": "profile.create", "id": "c1", "instance_id": "…", "v": 1, "ts": "…",
  "data": { "name": "Research Assistant", "description": "Finds and summarises sources" } }

{ "type": "profile.create.ack", "id": "c1", …,
  "data": { "status": "ok", "profile": { "profile_id": "research-assistant", "name": "Research assistant",
                                          "avatar": "sparkles", "description": "Finds and summarises sources" } } }

{ "type": "profile.delete", "id": "d1", …, "data": { "profile_id": "bruce", "confirm": "bruce" } }

{ "type": "profile.delete.ack", "id": "d1", …,
  "data": { "status": "ok", "profile_id": "bruce", "backup": "lekora-backups/profiles/bruce-20261108-101500.tar.gz" } }

{ "type": "profiles.changed", …, "data": { "profiles": [ … same shape as hello.ack … ] } }
```

Errors arrive as `error` with the request's `id` and are recoverable:
- `INVALID_NAME`
- `PROFILE_EXISTS`
- `UNKNOWN_PROFILE`
- `CANNOT_DELETE_DEFAULT`
- `CONFIRMATION_REQUIRED`
- `BACKUP_FAILED`
- `PROFILE_OP_FAILED` (the Hermes CLI failed; the reason includes its last output line)
- `PROFILE_ADMIN_UNAVAILABLE`

## Phone
The agent selector is the Choose Agents screen, opened at setup or from the chat's title menu → "Choose Agents…".

- **Add Agent:** a sheet with Name (required) and "What is it for?" (optional). Create shows progress, because cloning takes a few seconds. On success the new agent is switched on and becomes the current chat.
- **Delete:** swipe left on an agent, or long-press → "Delete Agent…". A confirmation dialog follows ("Delete Bruce on Hermes? … A backup is saved on the Hermes computer first."). `default` has no delete action.
- Other phones update immediately through `profiles.changed`. A deleted agent disappears from their choice; if it was their current chat they move to another chosen agent, or see Choose Agents if none remain.

## Not included
- Renaming agents, editing descriptions, and restoring from a backup. A backup can be restored on the host with `hermes profile import <file>`.
