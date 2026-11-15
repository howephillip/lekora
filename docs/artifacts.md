# Artifacts (Phase 5)

Agents make web pages, documents, code and images that open in the app as their own thing, not a wall of text. Owner's choices (2026-11-15): artifacts may load anything online; edit them yourself **or** ask the agent to change them, every change a new version; a card in the chat plus each agent's Artifacts list; share as the file itself or as a PDF.

## What it is
- **Kinds:** web page (HTML, scripts and online libraries work), document (Markdown), code (with its language), image (SVG), plain text. Up to 2 million characters per version.
- **Made by the agent with real tools** (AGENTS.md rule 7), offered only in Lekora chats, in Hermes' "lekora" toolset like `lekora_send_file`:
  - `lekora_create_artifact(title, kind, content, language?)`
  - `lekora_update_artifact(artifact_id, content, note?, title?)`: a new version; earlier ones are kept
  - `lekora_read_artifact(artifact_id, version?)`: the latest (with the user's own edits) or an earlier version
  - `lekora_list_artifacts()`
- **Kept on the Hermes instance** (plugin store, `artifacts` and `artifact_versions`, every record with `instance_id` and `profile_id`), forever, like chats (rule 3). Deleting an agent puts its artifacts, every version, into that agent's backup (`<id>-<stamp>-lekora-chat.json`, `artifacts`).

## In the app
- **Card in the chat** for each artifact made or changed: title, kind, version ("Created", "Updated to v3"; your own edits show on your side as "You edited"). Tap to open full screen.
- **Code** (owner, 2026-11-15: code cards weren't coloured, and long lines looked uneven): syntax colours on the phone, offline (`CodeHighlighter`: comments, strings, numbers, keywords, types and functions for JavaScript/TypeScript, C/C++/C#/Java/Kotlin/Swift/Go/Rust/Dart/PHP, Python, Ruby, Bash/Shell, SQL, Lua, R; JSON and YAML keys; Dockerfile instructions; diffs in green and red; HTML/XML/SVG tags and attributes; any other language still gets comments, strings and numbers). Line numbers stay put while code scrolls sideways; text never enlarges unevenly; View menu: Wrap Long Lines, Larger/Smaller Text (remembered). Code blocks in documents that name their language are coloured too. **Edit Myself** on code, web pages and images opens a code editor: monospaced, coloured as you type, no autocorrect, smart quotes or capitals, and a row of coding keys above the keyboard (tab, brackets, quotes, operators); Cancel asks before throwing changes away. Language names read properly (JSON, TypeScript, SQL); a Dockerfile shares as `Dockerfile`, a diff as `.diff`.
- **Viewer:** web pages and images in a sealed web view: scripts run and online content loads (owner's choice), but the page can't reach the app, your other data or other pages' storage (no bridge to the app, nothing kept between openings). Documents are shown formatted (headings, lists, quotes, code, tables, links). Code in a monospaced, scrollable view with line numbers.
- **Versions:** the version menu shows each one (who made it, its note, when); open any; "Restore This Version" saves it as the newest.
- **Edit:** the text or code in an editor; Save makes a new version by you. If the agent changed it meanwhile, nothing is overwritten: you're told and the latest is loaded.
- **Ask to Change:** type what to change; it's sent to the agent as your message, with a chip showing which artifact. The agent gets the artifact's id with it, reads it and saves a new version.
- **Share:** the file itself (.html, .md, .svg, .txt, or code with its extension) or a PDF, through the share sheet.
- **Artifacts list:** the chat's "…" menu › Artifacts: everything this agent made, newest change first.

## Protocol
`protocol.md` §18.

## Tests
Simulator (iOS 27.0, 2026-11-15), real plugin: the owner's own 11 code test cards (Python, JSON, YAML, Bash, SQL, TypeScript, JavaScript, C, Lua, Dockerfile, diff) coloured and evenly sized, wrap and text size, the code editor and its keys, Cancel asking first. App `CodeHighlighterTests`. Earlier, with a scripted agent: card, web page with an online chart library and its script, edit → v2, versions, ask to change → v3, document layout, share as PDF, the list.
Plugin `test_artifacts.py`: a card per artifact made or changed, versions kept, your edit as yours, an edit from an older version never overwrites a newer one, each agent sees only its own, bad input refused, the agent's four tools (only in Lekora chats), list/open/save from the phone, "ask to change" tells the agent which artifact, deleting an agent backs up every version and clears them.
