"""The ``lekora`` command: Lekora's tools for any agent (docs/agent-command.md).

Hermes only gives a plugin's tools to the agent the plugin runs in, so every other agent reaches
Lekora's artifacts and file sending by running this command with its own terminal tool. Hermes
tells every command which chat it came from (``HERMES_SESSION_PLATFORM`` / ``HERMES_SESSION_CHAT_ID``);
the command passes that, with the request, to the running Lekora on this machine (127.0.0.1, with
the token Lekora wrote for it), which does exactly what the matching tool does.

Standard library only: it runs with any Python 3, outside Hermes.
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import sys
from pathlib import Path
from typing import Optional

KINDS = ("html", "markdown", "code", "svg", "text", "mermaid", "react")
CONTENT_LIMIT = 20 * 1024 * 1024
TIMEOUT = 240


def _fail(message: str) -> int:
    print(json.dumps({"success": False, "error": message}))
    return 1


def _content(args: argparse.Namespace) -> Optional[str]:
    if args.content is not None:
        return args.content
    if args.file == "-":
        return sys.stdin.read()
    path = Path(args.file).expanduser()
    if path.stat().st_size > CONTENT_LIMIT:
        raise ValueError(f"{path} is too big for an artifact; send it with: lekora send-file {path}")
    return path.read_text(errors="replace")


def _parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="lekora", description="Lekora's tools, in a Lekora chat: artifacts and files.")
    p.add_argument("--bridge", help=argparse.SUPPRESS)
    sub = p.add_subparsers(dest="command", required=True)

    send = sub.add_parser("send-file", help="Send a file to the user (photo, PDF, audio, any file).")
    send.add_argument("path")
    send.add_argument("--caption")
    send.add_argument("--name")

    art = sub.add_parser("artifact", help="Artifacts: cards the user opens, edits and shares.")
    acts = art.add_subparsers(dest="action", required=True)

    def content_args(q: argparse.ArgumentParser) -> None:
        g = q.add_mutually_exclusive_group(required=True)
        g.add_argument("--file", help="Read the content from this file (- for standard input).")
        g.add_argument("--content", help="The content itself.")

    create = acts.add_parser("create", help="Create an artifact.")
    create.add_argument("--title", required=True)
    create.add_argument("--kind", required=True, choices=KINDS)
    create.add_argument("--language", help="For code: its language.")
    content_args(create)

    update = acts.add_parser("update", help="Rewrite an artifact (a new version).")
    update.add_argument("artifact_id")
    update.add_argument("--note")
    update.add_argument("--title")
    content_args(update)

    edit = acts.add_parser("edit", help="Change parts of an artifact (a new version).")
    edit.add_argument("artifact_id")
    edit.add_argument("--edits", required=True,
                      help='JSON list: {"line_start", "line_end", "replacement"} and/or {"find", "replace", "all"}.')
    edit.add_argument("--note")

    read = acts.add_parser("read", help="Read an artifact (latest, or --version N).")
    read.add_argument("artifact_id")
    read.add_argument("--version", type=int)

    acts.add_parser("list", help="List this chat's artifacts.")
    return p


def request_for(args: argparse.Namespace) -> tuple[str, dict]:
    """The Lekora tool and its arguments for a command line."""
    if args.command == "send-file":
        path = str(Path(args.path).expanduser().resolve())
        return "lekora_send_file", {k: v for k, v in (("path", path), ("caption", args.caption), ("name", args.name)) if v}
    if args.action == "create":
        data = {"title": args.title, "kind": args.kind, "content": _content(args)}
        if args.language:
            data["language"] = args.language
        return "lekora_create_artifact", data
    if args.action == "update":
        data = {"artifact_id": args.artifact_id, "content": _content(args)}
        data.update({k: v for k, v in (("note", args.note), ("title", args.title)) if v})
        return "lekora_update_artifact", data
    if args.action == "edit":
        edits = json.loads(args.edits)
        if isinstance(edits, dict):
            edits = [edits]
        data = {"artifact_id": args.artifact_id, "edits": edits}
        if args.note:
            data["note"] = args.note
        return "lekora_edit_artifact", data
    if args.action == "read":
        data = {"artifact_id": args.artifact_id}
        if args.version is not None:
            data["version"] = args.version
        return "lekora_read_artifact", data
    return "lekora_list_artifacts", {}


def call(bridge: Path, request: dict, timeout: float = TIMEOUT) -> dict:
    """One request to the running Lekora; its answer."""
    try:
        info = json.loads(bridge.read_text())
    except (OSError, ValueError):
        return {"success": False, "error": "Lekora isn't running on this Hermes instance"}
    body = json.dumps({**request, "token": info.get("token")}).encode() + b"\n"
    try:
        with socket.create_connection(("127.0.0.1", int(info["port"])), timeout=timeout) as conn:
            conn.sendall(body)
            conn.shutdown(socket.SHUT_WR)
            chunks = []
            while chunk := conn.recv(65536):
                chunks.append(chunk)
    except (OSError, KeyError, ValueError, TypeError) as exc:
        return {"success": False, "error": f"Couldn't reach Lekora: {exc}"}
    try:
        return json.loads(b"".join(chunks) or b"{}") or {"success": False, "error": "Lekora didn't answer"}
    except ValueError:
        return {"success": False, "error": "Lekora's answer was unreadable"}


def main(argv: Optional[list[str]] = None, env: Optional[dict] = None) -> int:
    env = os.environ if env is None else env
    args = _parser().parse_args(argv)
    bridge = Path(args.bridge) if args.bridge else Path(__file__).resolve().parent / "bridge.json"
    platform = env.get("HERMES_SESSION_PLATFORM", "")
    chat_id = env.get("HERMES_SESSION_CHAT_ID", "")
    if platform != "lekora" or not chat_id:
        return _fail("This only works while you're answering in a Lekora chat (run it from that conversation)")
    try:
        tool, data = request_for(args)
    except (OSError, ValueError) as exc:
        return _fail(str(exc))
    answer = call(bridge, {"tool": tool, "args": data, "chat_id": chat_id,
                           "profile": env.get("HERMES_SESSION_PROFILE", "")})
    print(json.dumps(answer, ensure_ascii=False))
    return 0 if answer.get("success") else 1


if __name__ == "__main__":
    sys.exit(main())
