# Voice (Phase 4)

Talk to your agents and hear them back. Three features, built and confirmed in this order: **voice notes**, **hearing replies**, **hands-free conversation**.

Owner's decisions (2026-11-11): spoken replies use iPhone voices by default (instant, sentence by sentence) with a per-agent option to use Hermes' own voice when a cloud voice is set up there; voice note transcripts show in small print under the voice bubble, like Messages; hands-free is built in this phase.

## 1. Voice notes
- **Recording** (as in Messages; owner's request 2026-11-11): a waveform button inside the message bar, on the right, while nothing is typed (typing turns it into Send). Hold it for half a second (a red ring fills, so a stray tap does nothing); recording starts with a haptic and you can let go and talk. The bar becomes a red live waveform with the time and a stop button. Stopping (light haptic) turns the bar, with a spring animation, into: **×** on the far left to throw it away; in the bar, play it back (drag the waveform to skip), **+ 0:07** records more onto the end, and Send. Up to 10 minutes.
- **In the chat:** a voice bubble with play/pause, a waveform you can drag to skip around, and the length. Under it, in small print, what Hermes heard (its transcript), once it arrives.
- **How:** the recording (AAC in .m4a) is uploaded like any file (`docs/files.md`) and sent with `voice` details (length, waveform). The plugin hands it to Hermes as a **voice message** (`MessageType.VOICE`), so Hermes transcribes it with its own speech-to-text (by default a free local Whisper, set up by Hermes on first use; or whatever `stt.provider` is set to) and the agent answers the words. Hermes posts the transcript back (`🎙️ "…"`, its `stt.echo_transcripts` setting, on by default); the plugin attaches it to the voice message instead of showing it as a separate line.
- If Hermes can't transcribe it, the agent still gets the recording's location (Hermes' own behaviour) and no transcript shows.

## 2. Hearing replies
Owner's feedback (2026-11-11): Hermes' voice must work with any voice a user has set up in Hermes (built in, a command provider or a plugin one, e.g. their own Fish Audio), not a fixed list; and voice mode must deliver replies as voice notes in that native voice, streamed, with a quick switch in the chat.

- **Voice mode** (Chat Settings › Voice › **Voice Replies**: Off / To My Voice Notes / Always; and the **waveform button** at the top of the chat, which switches between Off and Always):
  - With a Hermes voice: replies arrive as **voice notes in the agent's own Hermes voice**. The plugin speaks each sentence with Hermes' `text_to_speech` as soon as it's written and sends it (`voice.segment`); the phone plays the parts as they arrive. When the reply is saved and spoken, the parts are attached to it (`spoken`) and it stays a voice note (play, drag to skip, real waveform and length) with its text in small print, like a voice note's transcript.
  - Without one: the iPhone voice reads the reply aloud as it's written; the reply stays text.
  - Turning it off keeps existing voice notes; the next replies come as text with the Listen button.
  - "To My Voice Notes": only replies to a voice note you sent.
- **Listen:** the speaker under a text reply. iPhone voice by default (sentence by sentence; voice and speed per agent, every iPhone voice, Personal Voice), or **Listen With Hermes' Voice** per agent.
- **Hermes' voice is offered** whenever Hermes can speak with that agent's settings (`check_tts_requirements` in the agent's profile, with its keys): any provider, including command and plugin providers. Long text comes back from Hermes in several parts; all are kept and played in order. A failed attempt is retried once and logged in Hermes' log.
- **Where settings live:** the plugin's store (`app_settings`, per agent), so every phone and a new phone get them (rule 3); other phones update straight away. Nothing is written to Hermes' config.

## 3. Hands-free conversation (after that)
- A headphones button: the app listens, notices when you stop talking, sends it as a voice note, speaks the reply, then listens again. Works with the screen locked or in a pocket while the conversation is open. Details are settled when it's built.

## Protocol
`protocol.md` §12.

## Tests (hearing replies)
- **Plugin** (`tests/test_voice_replies.py`): sentences spoken once each as a reply streams, parts sent at once and attached when saved, off / no voice means text, "to my voice notes" only after a voice note, speech trouble never stops a reply.
- **Plugin** (`tests/test_voice_settings.py`): settings checked and kept per agent (deleted with it), Hermes' voice offered only for cloud voices, speech made once per reply, the requests over the connection, other phones told.
- **App** (`HearingRepliesTests`): sentences spoken as they arrive (nothing twice, the rest at the end), Markdown and code cleaned, speeds, settings loaded/saved/followed from another phone, Hermes' speech fetched.

## Tests (voice notes)
- **Plugin:** a voice chat.send is stored with its details and handed to Hermes as a voice message; Hermes' transcript line is attached to the latest voice note (and every phone updated) instead of being shown; ordinary messages that start with 🎙️ but don't follow a voice note are left alone.
- **App:** sending a voice note (upload + details), the transcript arriving on the bubble, decoding and caching voice details, waveform from a recording.
- **Simulator** with the real plugin and a stand-in Hermes that echoes a transcript: record (simulator microphone), play, scrub, transcript under the bubble.
