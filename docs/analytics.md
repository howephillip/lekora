# Analytics (Phase 8, feature 1)

## What the user sees
- **Analytics** in the left menu. **Today / 7 Days / 30 Days** (calendar days on the Hermes instance's clock).
- **Spend and tokens** at the top, then a **daily chart** of spend.
- **Breakdowns:** **by agent** (tap one for just its numbers), **by model**, and **by where it came from**: Lekora chats, Telegram and other apps, scheduled jobs, helpers (sub-agents), Board workers, the terminal, and background tasks (titles, compression, image reading and the like).
- **Your accounts (real spend)** (owner, 2026-11-21): for each provider the agents use, what the provider itself reports, through Hermes' own account checks (the same as Hermes' `/usage`):
  - **OpenRouter:** spend today, this week and this month, total, credit balance and key limit.
  - **Nous Portal:** credits and plan usage.
  - **Claude (subscription sign-in)** and **OpenAI Codex:** plan usage limits and when they reset.
  - Provider plugins that report account usage to Hermes.
  - Others (Google, OpenAI or Anthropic API keys, local models): "This provider doesn't report account spend to Hermes", and the estimate stands.
- **Estimates are labelled as estimates.** Hermes works out spend from token counts and price lists; Hermes' own note says this can be well under the real bill. Where a provider reports real spend, that is shown beside it.

## How it works (plugin)
- **Usage** is read from each agent's own Hermes session database (`<agent home>/state.db`, read-only through Hermes' `SessionDB(read_only=True)`), never written:
  - sessions started in the window: `sessions` (main conversation: estimated cost, tokens) plus `session_model_usage` rows with a `task` (background tasks, which Hermes keeps out of the session totals);
  - by model from `session_model_usage`; by where from `sessions.source` (`lekora`, `telegram`, `cron`, `subagent`, `kanban`, `cli`…), background tasks as their own line;
  - cost = `actual_cost_usd` when Hermes has it, else `estimated_cost_usd` (in practice Hermes only estimates). Tokens = input + output + cache read + cache write.
- **Accounts:** the providers in the window's usage (and each agent's configured provider), each checked once per credential with Hermes' `agent.account_usage.fetch_account_usage` (Nous: Hermes' Portal account check), inside that agent's profile so its own keys are used. Results are kept 5 minutes. Nothing is sent anywhere else.

## Protocol
See docs/protocol.md §24.

## Limits
- Spend is counted by when a conversation started (Hermes' own grouping), so a long conversation counts on its first day.
- Hermes' estimates miss spend Hermes never saw (other apps using the same key); the provider's own figures don't.
