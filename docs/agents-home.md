# Agents home (Phase 2, chat polish)

Like the Messages app: the app opens on a list of your agents; tap one to open its chat; the back arrow returns to the list. It replaces the agent menu under the chat's title. The chat keeps its iMessage look.

## The list
- **One row per agent** you chose, with:
  - **its avatar:** a playful critter in its own colours, the same on every phone, generated from the agent's id;
  - **its name:** bold when it has unread replies;
  - **a preview:** the last message, one or two lines, with Markdown symbols removed. Your own messages start with "You: ". Hermes' small system lines are skipped.
  - **a time:**
    - today: "4:42 PM",
    - "Yesterday",
    - a weekday within the last week,
    - otherwise a date.
  - **a blue dot** when it has unread replies, on the leading edge, as in Messages.
- **While an agent works,** its preview shows the animated thinking dots and what it's doing ("thinking…", "searching the web…"), and its avatar gently pulses.
- **Order:** most recent conversation first. Agents with no messages yet go at the end, in the host's order. No agent is pinned or featured (rule 5).
- **Title:** "Agents". A subtitle appears only while not connected ("Connecting…" / "Not connected").
- **Toolbar:** "+" adds an agent (the existing Add Agent form). The "…" menu holds Manage Agents… (choose, delete) and Forget Host.
- **Agents with no messages** show "No messages yet" with their description, if they have one.

## The chat
- Same bubbles, composer, streaming and history as before.
- **Title:** the agent's small avatar and name (plus "Connecting…" / "Not connected" only while not connected). There is no title menu any more: switching is done from the list.
- **Back:** the standard back button, so swiping right (from the edge or anywhere in the chat) goes back. Next to it, a small blue badge with the number of *other* agents with unread replies (the title-bar dot from `chat-history.md`, in iMessage's style).
- **Message times on demand:** drag the chat left and every message slides over to show its time on the right; let go and they slide back (as in Messages). Only leftward drags do this, so scrolling and swiping back are unaffected.
- **Times:** a centered time line appears above a message when more than 15 minutes have passed since the previous one, as in Messages ("Today 4:42 PM", "Yesterday 9:10 AM", "Mon 9:10 AM", "Oct 3, 9:10 AM").
- **On launch:** the list opens. A chat counts as read only while it's open.
- **Back to newest:** scrolled up into older messages, a small round ⌄ button appears at the bottom right, just above the message bar; tap it to jump to the newest message.
- **Drafts:** unsent text stays in each chat's message bar while you switch between chats (until the app quits). Sending clears the bar: the text box is replaced with a fresh one (keeping the keyboard up), so the keyboard can't write the sent text back.

## Message times (plugin)
`chat.message` and `history.page` messages carry `at`: when the host saved the message (UTC, ISO 8601, e.g. `2026-11-08T22:42:05Z`).
- Live, replayed and paged messages all carry it.
- The phone keeps it in its cache.
- `hello.ack` carries `message_times: true`. Then, if any cached messages have no time, the phone fetches each such agent's newest page again to fill the times in; nothing cached is thrown away, and messages sent from the phone keep the phone's own time.

## Avatars
- **Little visor bots:** a coloured head (round, squircle, wide or dome) with a dark visor and two glowing eyes (pill, round or bar), and on some, ears and an antenna with a ball on top. No tile behind them: they stand on their own, like cut-out characters.
- **Built from the agent's id,** using a stable hash, so the same agent looks the same on every phone and across reinstalls.
- **Colours:** among the host's agents, each gets its own colours (assigned in id order, the same on every phone) until there are more agents than colours.
- **Alive:**
  - they blink every few seconds (sometimes twice),
  - glance left, right and up, holding each look for a moment,
  - bob with a little squish,
  - and their antenna wobbles.
  
  Each agent has its own rhythm. While working they're livelier: faster glances, a bigger bob, and a glowing antenna. They stay still with Reduce Motion on.

## Tests
- **App (`swift test`):**
  - avatar choice is stable and spreads across agents,
  - previews skip system lines, strip Markdown and add "You: ",
  - list order by recency,
  - time labels,
  - time separators every 15 minutes,
  - the back-button count of other agents' unread chats,
  - `at` decoded and cached.
- **Plugin (pytest):** `at` on live, replayed and paged messages.
- **Simulator:** checked against the real plugin.
