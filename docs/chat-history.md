# Chat history on the phone, and unread dots (Phase 2, feature 2)

The app opens straight to your conversations, even before it reaches the host. Then it fetches only what changed. Older messages load as you scroll up. A blue dot shows which agents have replies you haven't read. Reading on one phone clears the dot on every phone.

The host stays the source of truth (AGENTS.md rule 3). The phone's copy is a cache: a new phone, or a fresh pairing, gets everything back from the host.

## What you see
- **Launch:** the last conversation shows at once while the app reconnects. The message bar is disabled until the connection is back. A subtitle reads "Connecting…". If the host can't be reached, the Reconnecting screen explains why, as before.
- **Scrolling up:** older messages load (100 at a time) when you scroll up to the top (a small spinner while loading). They're added once your finger is off the screen, with the message you were looking at kept at the top, so your place doesn't jump. A chat too short to scroll fetches its older messages straight away.
- **Unread dots:**
  - **Title bar:** a blue dot next to the agent's name when *another* agent you use has replies waiting.
  - **Agent switcher** (tap the title): a blue dot and "New messages" under each agent with unread replies.
  - Opening that chat clears its dot, here and on your other phones.
  - Only agent replies count. Your own messages and the small system lines don't.
- **Updating from the previous version:** everything already in your chats counts as read, so you don't get a wall of dots.

## Host (plugin)
**Change numbers (`rev`).** Every saved message gets a change number when it's stored, and a new one whenever it's changed (an agent's correction). The counter only goes up and is never reused, even after an agent is deleted. A phone that remembers the last change number it saw gets exactly what changed since: new messages *and* corrections to old ones. Before this, a correction made while the app was closed was missed.

**Replay on `hello`** (when the phone sends `since_rev`):
- **Changes** (`replay: "changes"`): every message changed after `since_rev`, oldest change first. Used when the phone has a cache and at most 1000 changes are waiting.
- **Recent** (`replay: "recent"`): the newest 50 messages of each agent. Used for a phone with no cache (`since_rev` 0) or one that has been away for a long time. The phone replaces its cached messages with these. Older ones load on demand.
- Without `since_rev` (an app from before this feature), the old behaviour is kept: everything after `last_seq`.

**Pages of older messages:** `history.fetch` returns up to 100 messages of one agent older than a given `seq`, and whether there are more.

**Read markers:** one per agent: "read up to `seq` N". These are shared by all of the user's phones, like iMessage.
- `chat.read` from a phone moves the marker forward (never back) and tells the user's other connected phones.
- `hello.ack` carries every agent's marker.
- When the marker table is first created on an existing install, everything already stored counts as read.
- Deleting an agent removes its marker with its messages.

**Your own messages:** the host now also sends a message back to the phone that sent it, with `client_id` = the `chat.send` id. That way the phone learns its number (`seq`) and the message is cached like any other.

Store (`lekora.db`):
- `events` gains `rev` (existing rows get `rev = seq`; the counter starts above the highest).
- Indexes on (`instance_id`, `profile_id`, `seq`) and (`instance_id`, `rev`).
- New `read_markers` table: `instance_id`, `profile_id`, `last_read_seq`, `updated_at`.
- User messages also store `client_id`.

## App
- **Cache file:** one file per host, in the app's private storage (Application Support, `Lekora/chat-<instance_id>.json`). It holds:
  - the saved messages,
  - the last change number,
  - the read markers,
  - which agents' histories are complete.
- **Limits:** at most 300 messages per agent are cached. Older ones stay on the host and load when you scroll up.
- **Not cached:** live (streaming) and unsent messages.
- **Saving:** the file is saved shortly after changes and when the app goes to the background.
- **Deleting:** the file is deleted by Forget Host and by pairing again.
- **Order:** messages are kept in `seq` order, so pages of older messages slot in above.
- **Gaps:** a correction to a message older than the cached part of an incomplete history is ignored, to avoid leaving a gap. When that page is loaded, it carries the corrected text.
- **Marking read:** a chat is marked read when it's on screen with the app in front: on opening it, switching to it, a new message arriving in it, or the app coming back to the front. Reading while offline is remembered and sent after reconnecting.

## Protocol
See `protocol.md` §5.

## Tests
- **Plugin (pytest):**
  - store migration of an existing database (rev backfill, read baseline),
  - rev on append and correction,
  - changes and recent replay (and the switch at the 1000-change limit),
  - pages,
  - read markers (forward only, shared, removed with the agent),
  - the echo to the sender,
  - live messages not sent twice after a replay.
- **App (`swift test`, fake host):**
  - the cache survives a relaunch and the next `hello` asks only for changes,
  - a correction made while offline arrives,
  - recent replay replaces the cache,
  - scrolling-up pages are inserted in order,
  - unread dots appear for other agents and clear when opened,
  - another phone's `chat.read` clears them,
  - Forget Host deletes the cache.
- **Real-plugin cross-check:** the app against the real plugin code over the encrypted connection.

## Also fixed along the way
"The computer that answered isn't the Hermes computer this iPhone was paired with" was shown when a connection attempt was merely cut short (or the host was down). Now that message appears only when the phone actually refused a different certificate; otherwise the app says it can't reach the computer.

## Known limits
- Messages don't show the time they were sent yet (the host has it; showing it is a later polish).
- The unread state isn't shown outside the app (push notifications and the app icon badge are out of scope, rule 10).
