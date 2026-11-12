# Voice (Phase 4)

Talk to your agents and hear them back. Three features, built and confirmed in this order: **voice notes**, **hearing replies**, **hands-free conversation**.

Owner's decisions (2026-11-11): spoken replies use iPhone voices by default (instant, sentence by sentence) with a per-agent option to use Hermes' own voice when a cloud voice is set up there; voice note transcripts show in small print under the voice bubble, like Messages; hands-free is built in this phase.

## 1. Voice notes
- **Recording** (as in Messages; owner's request 2026-11-11): a waveform button inside the message bar, on the right, while nothing is typed (typing turns it into Send). Tap it (with a haptic) and talk; no need to hold. The bar becomes a red live waveform with the time and a stop button. After stopping: **×** on the far left throws it away; in the bar, play it back (drag the waveform to skip), **+ 0:07** records more onto the end, and Send. Up to 10 minutes.
- **In the chat:** a voice bubble with play/pause, a waveform you can drag to skip around, and the length. Under it, in small print, what Hermes heard (its transcript), once it arrives.
- **How:** the recording (AAC in .m4a) is uploaded like any file (`docs/files.md`) and sent with `voice` details (length, waveform). The plugin hands it to Hermes as a **voice message** (`MessageType.VOICE`), so Hermes transcribes it with its own speech-to-text (by default a free local Whisper, set up by Hermes on first use; or whatever `stt.provider` is set to) and the agent answers the words. Hermes posts the transcript back (`🎙️ "…"`, its `stt.echo_transcripts` setting, on by default); the plugin attaches it to the voice message instead of showing it as a separate line.
- If Hermes can't transcribe it, the agent still gets the recording's location (Hermes' own behaviour) and no transcript shows.

## 2. Hearing replies (next)
- A Listen button on agent replies; per agent "Speak replies" (off / after voice notes / always) in Chat Settings.
- **iPhone voices** by default: each sentence is spoken as soon as it arrives. Voice and speed per agent, chosen from every voice on the iPhone (including downloaded Enhanced/Premium voices). Saved on the Hermes instance (rule 3).
- **Hermes' voice** per agent, when a cloud voice is set up in Hermes (ElevenLabs, OpenAI, Gemini, xAI…): the plugin asks Hermes to speak the reply and sends the audio. (Fish Audio isn't one of Hermes' built-in voices in 0.22.5; it would need a Hermes voice plugin.)
- Details are settled when this feature is built.

## 3. Hands-free conversation (after that)
- A headphones button: the app listens, notices when you stop talking, sends it as a voice note, speaks the reply, then listens again. Works with the screen locked or in a pocket while the conversation is open. Details are settled when it's built.

## Protocol
`protocol.md` §12.

## Tests (voice notes)
- **Plugin:** a voice chat.send is stored with its details and handed to Hermes as a voice message; Hermes' transcript line is attached to the latest voice note (and every phone updated) instead of being shown; ordinary messages that start with 🎙️ but don't follow a voice note are left alone.
- **App:** sending a voice note (upload + details), the transcript arriving on the bubble, decoding and caching voice details, waveform from a recording.
- **Simulator** with the real plugin and a stand-in Hermes that echoes a transcript: record (simulator microphone), play, scrub, transcript under the bubble.
