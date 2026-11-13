# Voice (Phase 4)

Talk to your agents and hear them back. Three features, built and confirmed in this order: **voice notes**, **hearing replies**, **hands-free conversation**.

Owner's decisions (2026-11-11): spoken replies use iPhone voices by default (instant, sentence by sentence) with a per-agent option to use Hermes' own voice when a cloud voice is set up there; voice note transcripts show in small print under the voice bubble, like Messages; hands-free is built in this phase.

## 1. Voice notes
- **Recording** (as in Messages; owner's request 2026-11-11): a waveform button inside the message bar, on the right, while nothing is typed (typing turns it into Send). Hold it for half a second (a red ring fills, so a stray tap does nothing); recording starts with a haptic and you can let go and talk. The bar becomes a red live waveform with the time and a stop button. Stopping (light haptic) turns the bar, with a spring animation, into: **×** on the far left to throw it away; in the bar, play it back (drag the waveform to skip), **+ 0:07** records more onto the end, and Send. Up to 10 minutes.
- **In the chat:** a voice bubble with play/pause, a waveform you can drag to skip around, and the length. Under it, in small print, what Hermes heard (its transcript), once it arrives.
- **How:** the recording (AAC in .m4a) is uploaded like any file (`docs/files.md`) and sent with `voice` details (length, waveform). The plugin hands it to Hermes as a **voice message** (`MessageType.VOICE`), so Hermes transcribes it with its own speech-to-text (by default a free local Whisper, set up by Hermes on first use; or whatever `stt.provider` is set to) and the agent answers the words. Hermes posts the transcript back (`🎙️ "…"`, its `stt.echo_transcripts` setting, on by default); the plugin attaches it to the voice message instead of showing it as a separate line.
- If Hermes can't transcribe it, the agent still gets the recording's location (Hermes' own behaviour) and no transcript shows.

## 2. Hearing replies
Owner's feedback (2026-11-11): Hermes' voice must work with any voice a user has set up in Hermes (built in, a command provider or a plugin one), not a fixed list; voice mode must deliver replies as voice notes in that native voice, streamed, with a quick switch in the chat. (2026-11-12): it must be seamless (never text first, then swapped), play reliably to the end, and offer a **personality voice**: the reply turned into an expressive voice script with the user's own instructions before it's spoken; personality voice notes are burnt orange.

- **Voice mode** (Chat Settings › Voice › **Voice Replies**: Off / To My Voice Notes / Always; **Style**: Voice / Personality Voice; and the **waveform button** at the top of the chat: tap = on/off, hold = choose Off / Voice / Personality Voice):
  - **Decided at the start of each reply.** The plugin decides when the reply begins (first streamed words, or before saving a reply that wasn't streamed) and tells the phones at once (`voice.reply`); the saved message carries `voicing`. The phone shows a voice note from the first word (spinner and shimmering waveform until the first audio, the text filling in underneath), never a text bubble.
  - **Voice:** finished sentences (very short ones joined to the next) are spoken with Hermes' `text_to_speech` in the agent's own voice and sent as they're made (`voice.segment`); the phone fetches and plays them strictly in order, each once, to the end of the reply. When it's saved and spoken, the parts are attached (`spoken`) and it stays a voice note (play, drag to skip, real waveform and length) with its text as the transcript.
  - **Personality Voice:** a few sentences at a time are first rewritten as natural, characterful speech by the agent's model through Hermes' auxiliary client (task `tts_audio_tags`, the one Hermes uses for its own audio-tag rewrite, so it can point at a cheaper model), then spoken. Burnt-orange voice notes; the reply you read is unchanged; it costs that model's tokens. If the rewrite fails, the plain text is spoken. Per agent, in Chat Settings › Voice › **Voice Personality** (owner, 2026-11-12):
    - **Who's speaking:** the agent's own personality as set up in Hermes (its `SOUL.md` and active personality or system prompt); one of Hermes' **personalities** (catgirl, helpful, hype… whatever that agent's Hermes lists); or **My Own** (written in the app). Only how it sounds changes, not how it writes.
    - **Cadence**, on top of either: **Filler Words** None / Some / Lots ("uh", "um", "like", "you know"), **Pauses** Few / Natural / Lots, **Pace** Calm / Natural / Lively.
    - **The transcript shows what you hear** (owner, 2026-11-12): the rewritten script, sent with each spoken part (`script`) and kept on the saved reply (`spoken_text`); the written reply is one tap away ("Show Written Reply"). Plain Voice says exactly the written text.
    - Built-in speech rules: contractions, varied sentence lengths, the odd restart, numbers and symbols spoken out, delivery tags (e.g. `[laughs]`, `(whispers)`) only where the voice understands them.
  - **Transcripts are compact:** two lines under the voice note with a chevron; tap to read it all (owner, 2026-11-12).
  - **Audio the iPhone can play:** Hermes voices can produce Ogg/Opus and other formats iPhone can't play. The plugin checks each file's real format and converts it with ffmpeg when the Hermes machine has it; if not, the reply shows as text with a plain explanation ("install ffmpeg or set the voice's output_format to mp3"), instead of a silent "playing" bubble. If the phone still can't play a file, the bubble says so.
  - Without a Hermes voice: the iPhone voice reads the reply aloud as it's written (and, once it starts, to the end); the reply stays text.
  - Turning it off keeps existing voice notes; the next replies come as text with the Listen button. "To My Voice Notes": only replies to a voice note you sent.
- **Listen:** the speaker under a text reply. iPhone voice by default (sentence by sentence; voice and speed per agent, every iPhone voice, Personal Voice), or **Listen With Hermes' Voice** per agent (all of Hermes' audio parts, in order).
- **Hermes' voice is offered** whenever Hermes can speak with that agent's settings (`check_tts_requirements` in the agent's profile, with its keys; checked at most once a minute per agent). A failed attempt is retried once and logged in Hermes' log.
- **Where settings live:** the plugin's store (`app_settings`, per agent), so every phone and a new phone get them (rule 3); other phones update straight away. Nothing is written to Hermes' config.

## 3. Hands-free conversation (after that)
- A headphones button: the app listens, notices when you stop talking, sends it as a voice note, speaks the reply, then listens again. Works with the screen locked or in a pocket while the conversation is open. Details are settled when it's built.

## Protocol
`protocol.md` §12.

## Tests (hearing replies)
- **Plugin** (`tests/test_voice_replies.py`): phones told a reply is a voice note before any audio and the saved reply marked so (streamed or not, with the id its parts arrive under); short sentences joined; every word spoken once, in order, and attached; personality rewrites before speaking with the visible text unchanged; audio iPhone can't play explained instead of sent; off / no voice means text; "to my voice notes" only after a voice note; speech trouble never stops a reply.
- **Plugin** (`tests/test_voice_settings.py`): settings checked and kept per agent (deleted with it), Hermes' voice offered only for cloud voices, speech made once per reply, the requests over the connection, other phones told.
- **App** (`HearingRepliesTests`): sentences spoken as they arrive (nothing twice, the rest at the end), Markdown and code cleaned, speeds, settings loaded/saved/followed from another phone, Hermes' speech fetched.

## Tests (voice notes)
- **Plugin:** a voice chat.send is stored with its details and handed to Hermes as a voice message; Hermes' transcript line is attached to the latest voice note (and every phone updated) instead of being shown; ordinary messages that start with 🎙️ but don't follow a voice note are left alone.
- **App:** sending a voice note (upload + details), the transcript arriving on the bubble, decoding and caching voice details, waveform from a recording.
- **Simulator** with the real plugin and a stand-in Hermes that echoes a transcript: record (simulator microphone), play, scrub, transcript under the bubble.
