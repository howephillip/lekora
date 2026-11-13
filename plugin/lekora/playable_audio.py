"""Audio the iPhone can play (spec: docs/voice.md §2).

Hermes voices can produce Ogg/Opus (Telegram's format) and other containers the iPhone can't
play. Those are converted with ffmpeg when the Hermes machine has it; otherwise a plain
explanation goes back to the phone instead of silent audio.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

PLAYABLE = {".mp3", ".m4a", ".aac", ".wav", ".aif", ".aiff", ".caf", ".flac", ".mp4"}


class UnplayableAudio(Exception):
    def __init__(self, reason: str) -> None:
        super().__init__(reason)
        self.reason = reason


def _kind(path: Path) -> str:
    """The real container (from the file's first bytes), whatever its name says."""
    try:
        head = path.read_bytes()[:12]
    except OSError:
        return path.suffix.lower()
    if head.startswith(b"OggS"):
        return ".ogg"
    if head.startswith(b"ID3") or head[:2] in (b"\xff\xfb", b"\xff\xf3", b"\xff\xf2"):
        return ".mp3"
    if head[4:8] == b"ftyp":
        return ".m4a"
    if head.startswith(b"RIFF"):
        return ".wav"
    if head.startswith(b"fLaC"):
        return ".flac"
    if head.startswith(b"\x1aE\xdf\xa3"):
        return ".webm"
    if head.startswith(b"#!AMR"):
        return ".amr"
    return path.suffix.lower()


def playable(path: Path) -> Path:
    """``path`` if the iPhone can play it; else a converted .m4a next to it; else UnplayableAudio."""
    path = Path(path)
    kind = _kind(path)
    if kind in PLAYABLE:
        if path.suffix.lower() != kind and kind in (".mp3", ".m4a", ".wav", ".flac"):
            renamed = path.with_suffix(kind)  # a misnamed file still plays once named for what it is
            try:
                path.rename(renamed)
                return renamed
            except OSError:
                return path
        return path
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise UnplayableAudio(
            f"This agent's Hermes voice makes {kind.lstrip('.').upper() or 'audio'} files, which iPhone can't play. "
            "Install ffmpeg on the Hermes machine, or set the voice's output_format to mp3 in Hermes.")
    out = path.with_name(path.stem + "-iphone.m4a")
    result = subprocess.run([ffmpeg, "-y", "-loglevel", "error", "-i", str(path), "-c:a", "aac", "-b:a", "96k", str(out)],
                            capture_output=True, timeout=120)
    if result.returncode != 0 or not out.is_file():
        raise UnplayableAudio("Couldn't convert this voice's audio for iPhone: "
                              + (result.stderr.decode(errors="replace").strip()[:200] or "ffmpeg failed"))
    return out
