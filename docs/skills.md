# Skills (Phase 8, feature 2)

## What the user sees
- **Skills in the left menu** (owner, 2026-11-22: one page, not per agent). Hermes keeps skills per agent; the page shows every skill once, with the agents that have it. A skill's page lists every agent: on/off for those that have it, **Add to** for those that don't (a catalog skill is installed for them by Hermes; any other is copied), **Remove from** (confirmed). Installing from the catalog and New Skill ask which agents get it (all by default).
- **The list:** each skill's name, what it's for and where it came from: **Built in** (ships with Hermes), **From the catalog**, **Made here** (by you or the agent), or **From Lekora** (its lekora-tools skill, which gives every agent Lekora's artifacts and files; on/off only, docs/agent-command.md). A switch turns it **off or on**.
- **Off means off everywhere** (owner, 2026-11-22): the agent doesn't use it in any app (Lekora, Telegram…). Hermes' own `hermes-agent` skill can't be turned off.
- **Open a skill** to read its instructions; skills made here (and built-in ones) can be **edited**.
- **Add from the catalog:** search Hermes' skills catalog (official skills and community sources). Before installing, Lekora shows **who made it** (official / trusted / community) and **Hermes' safety scan** (owner, 2026-11-22): its verdict, what it found, and whether Hermes allows it. Hermes blocks what it finds dangerous; the user confirms the rest.
- **New skill:** **describe it**; Hermes' model drafts the skill (name, one-line description, instructions), which the user can edit before saving, or **write it yourself** from a blank draft (owner, 2026-11-22).
- **Remove** (always confirmed): a catalog skill is uninstalled by Hermes; any other is moved to a backup on the Hermes instance (`<Hermes>/lekora-backups/skills/<agent>/`), never deleted outright. A built-in skill removed this way stays away (Hermes doesn't bring it back); turning it off is usually better.
- Changes reach the agent from its next message.

## How it works (plugin)
- **Reading** is read-only from the agent's own skills folder (`<agent home>/skills/**/SKILL.md`): name, description and category from each skill's header; where it came from from Hermes' own records (`.hub/lock.json` for the catalog, `.bundled_manifest` for built-in).
- **On/off (owner's rule 8 exception, 2026-11-22):** only `skills.disabled` in the agent's `config.yaml` is changed, through Hermes' own config writer, after a backup to `<Hermes>/lekora-backups/config/<agent>/` (the original copy kept forever plus the 10 newest), as for OpenRouter routing. Nothing else in the config is touched.
- **Catalog:** Hermes' own `skills search --json`; the pre-install scan is Hermes' own (`quarantine_bundle`, `scan_skill`, `should_allow_install`, as its dashboard does); install and uninstall are Hermes' own `hermes -p <agent> skills install <id> --yes` / `skills uninstall <name> --yes`, after the user's confirmation in the app.
- **New and edited skills** are written as `<agent home>/skills/[<category>/]<name>/SKILL.md`, checked against Hermes' rules (name: lowercase letters, digits, `-`, `_`, `.`, up to 64; description up to 60 characters; a header with both). An edited file's previous version is kept in the Lekora backup folder.

## Protocol
See docs/protocol.md §25.

## Limits
- A skill's extra files (scripts, references) are kept but not shown or edited in the app.
