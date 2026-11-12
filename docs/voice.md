# Voice (Phase 4)

Talk to your agents and hear them back. Three features, built and confirmed in this order: **voice notes**, **hearing replies**, **hands-free conversation**.

Owner's decisions (2026-11-11): spoken replies use iPhone voices by default (instant, sentence by sentence) with a per-agent option to use Hermes' own voice when a cloud voice is set up there; voice note transcripts show in small print under the voice bubble, like Messages; hands-free is built in this phase.

## 1. Voice notes
- **Recording** (as in Messages; owner's request 2026-11-11): a waveform button inside the message bar, on the right, while nothing is typed (typing turns it into Send). Hold it for half a second (a red ring fills, so a stray tap does nothing); recording starts with a haptic and you can let go and talk. The bar becomes a red live waveform with the time and a stop button. Stopping (light haptic) turns the bar, with a spring animation, into: **×** on the far left to throw it away; in the bar, play it back (drag the waveform to skip), **+ 0:07** records more onto the end, and Send. Up to 10 minutes.
- **In the chat:** a voice bubble with play/pause, a waveform you can drag to skip around, and the length. Under it, in small print, what Hermes heard (its transcript), once it arrives.
- **How:** the recording (AAC in .m4a) is uploaded like any file (`docs/files.md`) and sent with `voice` details (length, waveform). The plugin hands it to Hermes as a **voice message** (`MessageType.VOICE`), so Hermes transcribes it with its own speech-to-text (by default a free local Whisper, set up by Hermes on first use; or whatever `stt.provider` is set to) and the agent answers the words. Hermes posts the transcript back (`🎙️ "…"`, its `stt.echo_transcripts` setting, on by default); the plugin attaches it to the voice message instead of showing it as a separate line.
- If Hermes can't transcribe it, the agent still gets the recording's location (Hermes' own behaviour) and no transcript shows.

## 2. Hearing replies
- **Listen:** a small speaker button under each agent reply; tap to hear it, tap again (a stop button while speaking) to stop.
- **Speak replies,** per agent in Chat Settings › Voice: **Off** (default), **After My Voice Notes** (only replies to a voice note you sent), **Always**. Only replies that arrive while the chat is open and the app is in front; recording stops the speaking.
- **iPhone voices** (default): each sentence is spoken as soon as it's complete, while the rest is still being written; Markdown symbols, link addresses and code blocks aren't read out. **Voice** lists every voice on the iPhone for your language (or all languages), Premium and Enhanced first, with a sample (tap to choose and hear it); a Personal Voice can be allowed and used. **Speed** slider. Better voices are downloaded in iPhone Settings › Accessibility › Read & Speak.
- **Hermes' voice:** "Use Hermes' Voice" appears only when the agent's own Hermes settings use a cloud voice (`tts.provider` ElevenLabs, OpenAI, Gemini, xAI, Mistral, MiniMax, DeepInfra; checked with Hermes' `check_tts_requirements`). The plugin has Hermes say the reply with its own `text_to_speech` (in that agent's profile, with its keys), keeps the audio (made once per reply), and the phone plays it. It starts once the reply is complete. If it fails, the iPhone voice says it instead. Fish Audio isn't one of Hermes' built-in voices in 0.22.5 (it would need a Hermes voice plugin).
- **Where settings live:** the plugin's store (`app_settings`, per agent, with `instance_id`), so every phone and a new phone get them (rule 3); other phones update straight away. Nothing is written to Hermes' config. Deleting an agent deletes them.

## 3. Hands-free conversation (after that)
- A headphones button: the app listens, notices when you stop talking, sends it as a voice note, speaks the reply, then listens again. Works with the screen locked or in a pocket while the conversation is open. Details are settled when it's built.

## Protocol
`protocol.md` §12.

## Tests (hearing replies)
- **Plugin** (`tests/test_voice_settings.py`): settings checked and kept per agent (deleted with it), Hermes' voice offered only for cloud voices, speech made once per reply, the requests over the connection, other phones told.
- **App** (`HearingRepliesTests`): sentences spoken as they arrive (nothing twice, the rest at the end), Markdown and code cleaned, speeds, settings loaded/saved/followed from another phone, Hermes' speech fetched.

## Tests (voice notes)
- **Plugin:** a voice chat.send is stored with its details and handed to Hermes as a voice message; Hermes' transcript line is attached to the latest voice note (and every phone updated) instead of being shown; ordinary messages that start with 🎙️ but don't follow a voice note are left alone.
- **App:** sending a voice note (upload + details), the transcript arriving on the bubble, decoding and caching voice details, waveform from a recording.
- **Simulator** with the real plugin and a stand-in Hermes that echoes a transcript: record (simulator microphone), play, scrub, transcript under the bubble.
