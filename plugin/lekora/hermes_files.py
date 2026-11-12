"""Files between Lekora and Hermes (spec: docs/files.md).

- Phone -> agent: each file is copied into Hermes' own media cache (``cache_media_bytes``,
  as Telegram does) and listed on the message as ``media_urls`` / ``media_types``. Small text
  files are included in the message text, like Telegram (Hermes' contract:
  ``media_text_inlined``).
- Agent -> phone: the ``lekora_send_file`` tool, offered only in Lekora chats.

The Hermes calls are passed in, so this module is tested with stand-ins; the adapter wires
the real ones (checked against Hermes 0.22.5).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

log = logging.getLogger(__name__)

MAX_TEXT_INLINE_BYTES = 100 * 1024   # Telegram's limit for putting a text file in the message
TEXT_EXTENSIONS = {
    ".txt", ".md", ".markdown", ".csv", ".tsv", ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg",
    ".log", ".xml", ".html", ".htm", ".css", ".js", ".ts", ".tsx", ".jsx", ".py", ".rb", ".go",
    ".rs", ".swift", ".kt", ".java", ".c", ".h", ".cpp", ".hpp", ".cs", ".php", ".sh", ".sql",
    ".r", ".tex", ".rst", ".env.example",
}

# (bytes, file name, mime) -> (cached path, media type, kind), or None when unusable.
Cache = Callable[[bytes, str, str], Optional[tuple[str, str, str]]]


@dataclass
class InboundMedia:
    text: str
    message_kind: str = "text"   # text | photo | video | audio | document
    media_urls: list[str] = field(default_factory=list)
    media_types: list[str] = field(default_factory=list)
    media_text_inlined: list[Optional[bool]] = field(default_factory=list)


def _is_text(name: str, mime: str) -> bool:
    return (mime or "").startswith("text/") or os.path.splitext(name.lower())[1] in TEXT_EXTENSIONS


def inbound_media(text: str, files: list[dict], cache: Cache) -> InboundMedia:
    """The message Hermes gets for a phone message with files ({path, name, mime})."""
    out = InboundMedia(text=text or "")
    kinds: list[str] = []
    inlined_text: list[str] = []
    for item in files:
        name, mime = str(item.get("name") or "file"), str(item.get("mime") or "")
        data = Path(item["path"]).read_bytes()
        cached = cache(data, name, mime)
        if cached is None:
            log.warning("Lekora: Hermes couldn't use %s; skipped", name)
            continue
        path, media_type, kind = cached
        if item.get("voice"):
            kinds.append("voice")  # a voice note: Hermes transcribes it (docs/voice.md)
            out.media_urls.append(path)
            out.media_types.append(media_type if media_type.startswith("audio/") else (mime or "audio/mp4"))
            out.media_text_inlined.append(False)
            continue
        out.media_urls.append(path)
        out.media_types.append(media_type)
        kinds.append(kind)
        inline = False
        if kind == "document" and _is_text(name, mime) and len(data) <= MAX_TEXT_INLINE_BYTES:
            try:
                display = re.sub(r"[^\w.\- ]", "_", name)
                inlined_text.append(f"[Content of {display}]:\n{data.decode('utf-8')}")
                inline = True
            except UnicodeDecodeError:
                pass
        out.media_text_inlined.append(inline)
    if inlined_text:
        out.text = "\n\n".join(inlined_text + ([out.text] if out.text else []))
    if kinds:
        # One message type for the message (Hermes reads each file's own media type too).
        first = kinds[0]
        out.message_kind = {"image": "photo", "video": "video", "audio": "audio", "voice": "voice"}.get(first, "document")
    return out


# ---- voice note transcripts (docs/voice.md) ---------------------------------------------

# Hermes posts what it heard as 🎙️ "…" (gateway.voice.transcript_echo_short; the quotes vary by language).
_TRANSCRIPT_ECHO = re.compile(r'^\s*🎙\ufe0f?\s*["“«„]([\s\S]*)["”»“]\s*$')


def transcript_from_echo(content: str) -> Optional[str]:
    match = _TRANSCRIPT_ECHO.match(content or "")
    return match.group(1).strip() if match else None


# ---- the lekora_send_file tool -------------------------------------------------------

TOOL_NAME = "lekora_send_file"
TOOLSET = "lekora"
TOOL_SCHEMA = {
    "name": TOOL_NAME,
    "description": (
        "Send a file to the user in this Lekora chat: a photo, PDF, document, spreadsheet, audio, "
        "video, code or any other file on this machine. Use it whenever the user asks for a file or "
        "you made one for them. Up to 100 MB."),
    "parameters": {
        "type": "object",
        "properties": {
            "path": {"type": "string", "description": "Absolute path of the file to send."},
            "caption": {"type": "string", "description": "Optional short message shown with the file."},
            "name": {"type": "string", "description": "Optional file name to show (defaults to the file's own)."},
        },
        "required": ["path"],
    },
}


def tool_result(ok: bool, message: str) -> str:
    return json.dumps({"success": ok, "message": message} if ok else {"success": False, "error": message})


def send_file_tool(args: dict, *, platform: str, chat_id: str,
                   deliver: Optional[Callable[[str, str, str, Optional[str]], Awaitable[None]]],
                   loop: Optional[asyncio.AbstractEventLoop], validate: Callable[[str], Optional[str]],
                   timeout: float = 180) -> str:
    """The tool's work, run in Hermes' tool thread: check, then hand the file to the Lekora
    service on the gateway's event loop and wait for it to be stored and sent."""
    if platform != "lekora" or not chat_id:
        return tool_result(False, "lekora_send_file only works in Lekora chats")
    if deliver is None or loop is None:
        return tool_result(False, "Lekora isn't running")
    raw = str(args.get("path") or "").strip()
    if not raw:
        return tool_result(False, "Which file? Give its absolute path.")
    path = validate(raw)
    if path is None:
        return tool_result(False, f"Can't send {raw}: it isn't a file, or it's somewhere files may not be sent from")
    try:
        running = asyncio.get_running_loop()
    except RuntimeError:
        running = None
    if running is loop:
        return tool_result(False, "Lekora can't send files from here")
    caption = str(args.get("caption") or "")
    name = args.get("name") or None
    future = asyncio.run_coroutine_threadsafe(deliver(chat_id, path, caption, name), loop)
    try:
        future.result(timeout=timeout)
    except Exception as exc:
        reason = getattr(exc, "reason", None) or str(exc) or type(exc).__name__
        return tool_result(False, f"Couldn't send the file: {reason}")
    return tool_result(True, f"Sent {name or Path(path).name} to the user")
