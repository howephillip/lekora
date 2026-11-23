# Live voice engines for calls (Phase 8, feature 5, part 2; owner, 2026-11-22: "both options … develop for both")

## What the user sees
- The call screen has an **Engine** menu: **Your agent** (the agent's own voice, docs/voice.md §3), **GPT-Live**
  or **Fish Live 3**.
  - The choice is kept per agent until changed. Switching during a call ends the current engine and starts the
    chosen one at once.
  - Engines that can't run say why (e.g. "needs an OpenAI API key").
- With a live engine, a real-time voice talks with you and answers instantly. For anything real (questions,
  plans, actions) it asks your agent, whose turn appears in the chat as usual: your words, then its reply.
  Live calls don't make voice notes.

## GPT-Live (OpenAI)
- **Key and settings.** The key and settings stay on the Hermes instance. Hermes' own `voice.gpt_live` settings
  (model, voice, extra instructions) and its OpenAI key chain (`OPENAI_API_KEY` in the agent's `.env`, or
  `voice.gpt_live.api_key`) are read inside the agent's profile (`tools.voice_live`).
- **Starting.** The plugin opens `wss://api.openai.com/v1/live/sessions` and sends `session.start` with:
  - Hermes' session config, plus "you are the voice of <agent>";
  - client delegation;
  - 24 kHz 16-bit audio;
  - the chat's latest messages (up to 20, about 12,000 characters) as context.
- **Sound.** The phone sends its microphone (voice-processed, echo-cancelled) as `live.audio` every 100 ms. The
  voice comes back as `live.audio` and plays as it arrives.
- **Interruptions.** GPT-Live is full duplex and doesn't announce interruptions, so the phone drops whatever is
  still queued of its voice when you start talking: sound louder than its echo, about -30 dB.
- **Hand-overs.** On `session.delegation.created`, the user's words since the last hand-over (its transcript)
  go to the agent as a normal chat turn, with the call note `LIVE_NOTE` (AGENTS.md rule 7 call exception). The
  reply streams back sentence by sentence as `session.commentary.append` (up to 500 tokens each), and GPT-Live
  says it.
- **Cost.** About $0.05 a minute on the OpenAI key, plus the agent's own usage.

## Fish Live 3 (Fish Audio)
- **Key.** The key is Hermes' own `FISH_AUDIO`, used only on the instance.
- **The Fish agent.** On first use, Lekora creates and publishes a Fish agent named "Lekora": Live 3, voice Clara,
  with a client tool `ask_agent(request)` (blocking, 120 s). It's remembered in Lekora's store.
- **Starting.** Each call creates a Fish session with a per-agent system prompt ("you are the voice of <agent>…
  call ask_agent for anything beyond small talk") and gives the phone a single-use LiveKit pass.
- **During the call.**
  - The phone joins with the LiveKit SDK (`client-sdk-swift`, a new app dependency; no account needed for it).
  - `client_tool.call` arrives on the `agent-event` topic. The phone asks the agent through the instance
    (`live.ask`, a normal chat turn with the call note) and answers with `client_tool.result` on `client-event`.
  - The screen follows the agent's state (`lk.agent.state`: listening, thinking, speaking).
  - Ending the call ends the Fish session.
- **Cost.** $0.035 a minute through 2026, then $0.07.
- **Limits.** Fish's tool times out at 120 s, so longer work answers "still working; it'll be in our chat". Live 3
  is English only.

## Protocol
See docs/protocol.md §28.

## Tests
- Plugin (`test_live_calls.py`):
  - speakable pieces;
  - GPT-Live relaying sound and handing work to the agent (a fake OpenAI socket);
  - the engine kept per agent;
  - the Fish agent made once and tool calls answered by the agent;
  - call words becoming a chat turn with the call note;
  - a call ending when the phone goes away.
- App:
  - engines kept;
  - GPT-Live sound in both directions;
  - Fish tool calls read from `agent-event`.
- Real Hermes:
  - without a key GPT-Live is unavailable with a plain reason;
  - with a fake key the session config is right and OpenAI's live endpoint answers 401;
  - the Fish key lists the owner's Fish agents (read only).
