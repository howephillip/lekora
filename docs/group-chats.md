# Group chats (Phase 7, feature 2)

## What the user sees
- **Groups** sit with the agents on the home screen. **New Group**: a name and two or more agents (any agents: all are equal). A group's settings rename it, add or remove agents at any time, or delete it (confirmed first).
- In a group the user writes as usual. **@name** talks to one or a few agents (autocompletes from the members); **no @mention, or @all / @everyone, is everyone** (owner, 2026-11-19, Hermes' own rule). Each agent's reply is a bubble with its name, and live typing shows who is writing. Agents answer at the same time.
- **@mention in a one-to-one chat (owner, 2026-11-20):** typing "@" in an agent's chat suggests the other agents. Sending a message that @mentions any of them asks "Start a group with Lauren and Ashlyn?": **Start Group** reuses the group with exactly those agents or makes one ("Lauren & Ashlyn"), adds a note "From your chat with Lauren" and that chat's last 5 messages (with their own times), opens it and sends the message there; **Send to Lauren Only** sends it as it is. The one-to-one chat stays as it was.
- **One shared conversation:** every agent sees what the user and the other agents said since its last turn. An agent with nothing to add stays quiet. An agent can **@mention** another member to bring it in.
- Everything a one-to-one chat has works in a group (owner, 2026-11-19): streaming replies, approval and question cards, artifacts, files both ways, Delegated cards. Hearing replies and calls stay one-to-one for now.

## How it works (plugin)
- Lekora runs the group itself (owner's choice over Hermes' hosted rooms, 2026-11-19, because Lekora's tools and streaming work only in Lekora chats). Each member has its own Hermes chat for the group, `g.<group id>.<profile>`, routed to that profile in memory like every Lekora chat (no Hermes config written); it keeps that agent's own memory of the group.
- **Turns:** a user message goes to every addressed member at once. Each gets what was said since its last turn (up to 30 messages, the newest last) and then the new message, as one message from the user. A reply that is exactly `(pass)` is dropped and never shown. A reply that @mentions another member hands that member the conversation (it gets the same catch-up). **Loop guard:** per user message, at most 3 rounds of agents bringing each other in and 10 agent messages; a new user message starts fresh.
- **Group instruction (owner, 2026-11-20; AGENTS.md rule 7 exception):** only in group chats, Hermes' per-turn chat instruction (`MessageEvent.channel_prompt`, system prompt, never the user's message) tells the agent it is @handle in a group with the named members and the user, that the others' words reach it as a catch-up, to reply exactly `(pass)` when it has nothing to add, and to @mention a member to bring them in. Each delivered message itself is just the conversation: a factual header (group, own handle, members, user), the catch-up and the new message. Nothing is added in one-to-one chats.
- **Lekora's tools in groups:** artifacts and sending files work for every member (Lekora's tools are in Hermes' Lekora platform set, which every agent's Lekora chats include).
- Every record carries `instance_id` and `profile_id`: a group's saved messages use `group:<id>` as their chat, and each agent's message also carries `speaker` (its profile_id). Groups are saved in Lekora's store with their members, so they survive re-setup and new phones.
- **Swipe to delete (owner, 2026-11-20):** on the Agents screen, swipe a group or an agent left for **Delete**, always confirmed first: a group goes with its messages (its agents stay); an agent is deleted on the Hermes instance after a backup, as Manage Agents does. The default agent can't be deleted.
- **Details (owner, 2026-11-20):** a group's settings show each member's side as Hermes has it: its title for the conversation, model, how much of its context is used, tokens and cost, with the group's total cost and tokens (`group.details`).
- **Working on each other's artifacts (owner, 2026-11-20):** an artifact made in a group belongs to the group: any member can read, list, change and add versions to it with the artifact tools, and members are handed each artifact's id in their catch-up. Lekora's tools are in Hermes' shared tool slot too, so agents whose own config doesn't enable the Lekora plugin have them.
- Deleting an agent removes it from its groups (a group left with fewer than two members stays, read-only, until the user adds someone or deletes it).

## Protocol
See docs/protocol.md §23.

## Limits
- Hearing replies (voice mode) and hands-free calls aren't available in groups yet.
- Past chats (earlier conversations) are per agent; a group is one continuous conversation.
- Agents see each other's words, not each other's tool output.
