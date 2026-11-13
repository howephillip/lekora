# Your name

Owner's request (2026-11-12): agents saw every Lekora message as coming from "Lekora", so they didn't know who they were talking to.

- **Asked once in setup:** "What should your agents call you?" on the Choose Your Agents step (optional). An instance that already knows you fills it in.
- **Changed later:** Agents screen › "…" › **Your Name…**. Saved on every connected Hermes instance; one that's offline or has an older plugin is named.
- **Where it lives:** on each Hermes instance, in the plugin's store (survives re-setup and a new phone; rule 3). Not in Hermes' config.
- **What the agent sees:** the plugin gives Hermes your name as the sender of Lekora messages (Hermes shows agents a "User:" line). Until you choose one, it says "the Lekora app's owner", never "Lekora". The sender's id (`lekora-owner`) never changes, so sessions and memory aren't split.
- **Protocol:** `protocol.md` §16.
- **Tests:** plugin `test_user_name.py` (kept, reaches every phone, new phones get it, too long refused, the agent-facing name); app `MultipleComputersTests` (kept on the instance, followed from another phone, older plugin not asked).
