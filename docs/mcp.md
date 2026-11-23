# MCP servers (Phase 8, feature 3)

MCP servers give agents extra tools: Linear, Figma, Notion, your own services. Hermes keeps them per
agent, in each agent's `config.yaml` (`mcp_servers`).

## Owner's choices (2026-11-22)
- **One page for all agents**, in the left menu, like Skills.
- **Changes are allowed** (rule 8 exception, like skills on/off). Adding, removing and on/off go
  through Hermes' own MCP helpers. The agent's `config.yaml` is backed up first, and only that
  server's entry is touched. Removing is always confirmed.
- **Library:** Hermes' own catalog (Nous-approved), plus the **official public MCP registry**,
  clearly labelled **Not vetted**, plus **Add your own** (by URL or command).
- **Sign-ins happen in the app** and are stored on the Hermes instance:
  - API keys go into the agent's own `.env` through Hermes, and are never sent back to the phone.
  - Account sign-ins (OAuth) open on the phone. The tokens are saved by Hermes on the instance.

## What the user sees
- **Left menu › MCP Servers.** Each server once, with:
  - what it is and where it came from (**Hermes catalog** / **Registry · Not vetted** / **Added by you**);
  - the bots of the agents that have it (faded where it's off);
  - a **Sign in needed** mark where an agent still has to sign in.
- **Open a server.** It shows:
  - each agent with an on/off switch, **Add** for those without it (any keys and sign-in are shared
    from an agent that has it), and swipe to **Remove** (confirmed);
  - **Sign In** for an agent that needs it;
  - **Test**: whether the server answers, and its tools.
- **+ › Hermes Catalog**: search Hermes' catalog. **+ › Public Registry**: search the official registry,
  each result marked **Not vetted**, with where it comes from. **+ › Add Your Own**: a URL, or a command.
- **Adding.** Pick the agents (all by default) and fill in any keys it needs. Then sign in if it needs
  an account. The sign-in is done once and shared with the other agents you picked.
- **When changes take effect.** Hermes connects new servers within a minute. Open chats get the new
  tools on their next message.

## How it works (plugin)
- `mcp.py` holds the logic; `hermes_mcp.py` holds the Hermes glue. Every call runs inside the agent's
  own profile (`_profile_runtime_scope`), so config, `.env` and sign-in tokens are that agent's.
- **Listing** reads each agent's `mcp_servers` with Hermes' own reader. Secrets are never sent to the
  phone: values are shown as "set" or "missing".
- **Hermes catalog:**
  - read with `list_catalog()`;
  - secret values are saved with `save_env_value` before the install;
  - the install is Hermes' own `install_entry(entry, preloaded_env=…)`, which keeps secrets as
    `${VAR}` in `config.yaml`.
- **Registry:**
  - `GET https://registry.modelcontextprotocol.io/v0/servers?search=…&version=latest`.
  - A remote (`streamable-http` / `sse`) becomes a `url` server, with any headers it needs.
  - A package becomes a command server:
    - npm becomes `npx -y <package>@<version>`;
    - PyPI becomes `uvx <package>==<version>`;
    - OCI becomes `docker run -i --rm <image>`.
  - A package is offered only when that runner exists on the Hermes machine.
  - Required settings become fields in the app. Secret ones are stored in `.env` as `${VAR}`.
- **Your own:** a URL (optional bearer token, stored by Hermes as `MCP_<NAME>_API_KEY`), or a command
  with arguments and settings.
- An address that serves the older SSE style (registry type `sse`, or a path ending in `/sse`) is saved with `transport: sse`. Without it Hermes speaks the newer style and the server answers "Not Found". Hermes' own catalog entry for PayPal lacks this (owner's test, 2026-11-22).
- Every save goes through Hermes' `_save_mcp_server`, which applies Hermes' own safety check
  (`validate_mcp_server_entry`). A rejected server is not saved.
- **On/off** sets `enabled`. **Remove** uses Hermes' `_remove_mcp_server`.
- **Before every change** the agent's `config.yaml` is backed up to
  `<Hermes>/lekora-backups/config/<agent>/`. The original is kept forever, plus the 10 newest.
- **Test** uses Hermes' own probe, `_probe_single_server`, which returns the tools or the reason it failed.
- **Sign-in:** Hermes' own OAuth worker runs with a Lekora flow.
  1. The plugin gives the phone the authorization address.
  2. The phone opens it, with `lekora://mcp-oauth` as the return address, in the system sign-in sheet.
  3. If the service refuses that address, the phone retries with `http://127.0.0.1:53682/callback`
     in an in-app browser that catches the return.
  4. The code and state go back to the plugin. Hermes checks the state, exchanges the code and saves
     the tokens in that agent's `mcp-tokens/`.
- **Sharing.** Giving a server to another agent copies its entry, and copies the secret values it
  refers to and its sign-in files on the instance, from the agent that has it. Nothing passes through
  the phone.
- **After a change**, Lekora asks Hermes to reconnect that agent's servers and refresh its open chats
  (Hermes' own MCP reload).

## Protocol
See docs/protocol.md §26.

## Limits
- A registry package needs its runner (`npx`, `uvx` or `docker`) on the Hermes machine. Otherwise
  the app says what's missing.
- Servers that only work with a sign-in client registered in advance (e.g. Asana) finish their
  sign-in on the Hermes machine. The app says so.
- Servers that other Hermes plugins provide are not in the agent's config, so they aren't listed.
