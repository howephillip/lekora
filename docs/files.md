# Files both ways (Phase 3)

Send photos and files to an agent, and get files back, in any chat. Owner's decisions (2026-11-10): files are kept forever like chats, with the space used shown on the instance's page; 100 MB per file; voice notes wait for Phase 4 (Voice).

## What you see
- **Sending:** a **+** button next to the message box: **Photo Library** (up to 10), **Take Photo**, **Choose Files**. Attachments show as small previews above the message box (tap × to remove); add text or not, then send. While uploading, the message shows its progress; a failed upload can be retried.
- **In the chat:** photos as pictures in the bubble; everything else as a file row (icon, name, size). Tap any of them to open Apple's preview: zoom photos, read PDFs and Office files, play audio and video, and share or save (to Photos or Files) from there.
- **Instance page** (Hermes Instances → an instance): "Files: 1.2 GB · 340 files".

## Limits
- 100 MB per file, 10 files per message, both directions. Bigger files are refused with a plain message.

## Where files live (rule 3)
- On each Hermes instance, in the plugin's own folder `<Hermes>/lekora-files/<agent>/<file id>/<name>`, recorded in the plugin's database with `instance_id` and `profile_id` (rule 6). Kept forever; deleting an agent deletes its files with its chats.
- Hermes' own media cache (cleared after 24 h) only gets a copy for the agent to read.
- The phone keeps downloaded files in its cache (iOS may clear it); they're fetched again when opened.

## How it works
- **Transfers** use the existing encrypted connection, in 384 KB pieces (`file.upload.*`, `file.read`; protocol §11). An interrupted upload starts again; unfinished uploads are cleaned up after a day.
- **You → agent:** `chat.send` carries the file ids. The plugin copies each file into Hermes' media cache with Hermes' own `cache_media_bytes` and hands Hermes a normal message with `media_urls` / `media_types`, exactly as Telegram does. Hermes then does what it always does: images to vision (or a description first), small text files (≤100 KB) included in the message, other documents saved for the agent to open.
- **Agent → you**, two ways (both rule 7, no prompting):
  1. Hermes' own file sending (`MEDIA:` files from its image, speech and other tools): the adapter implements `send_image_file`, `send_document`, `send_video`, `send_voice` and `send_animation` / `send_image` for local files. Each path is checked with Hermes' own `validate_media_delivery_path` first.
  2. A real tool, **`lekora_send_file`** (`path`, optional `caption`), offered only in Lekora chats: the agent sends any file it made or found. Same path check and limits.
- Remote images (`https://…` links in a reply) stay links.

## Protocol
`protocol.md` §11.

## Tests
- **Plugin** (`tests/test_files.py`): upload in pieces, size and order checks, too large, wrong agent, reading back, chat.send with files (payload, dispatch, other phones), agent files published, usage, stale uploads cleaned, deleting an agent's files, the tool (outside Lekora, missing file, success).
- **App** (`FilesTests`): upload then send, progress, failure, too large refused locally, download and cache, file messages decode and survive the cache, usage.
- **Simulator** with the real plugin and a stand-in Hermes that echoes files back: photo, document, both directions, preview, instance storage line.
