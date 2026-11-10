# Model picker (Phase 2, feature 5)

Change an agent's AI model from the phone. Tap the **Model** button (chip icon) in a chat, or type `/model`. A card shows the current model. **Choose a Model…** opens a searchable list of every model your Hermes computer can use, grouped by provider. Tap one and Hermes switches; its confirmation (context size, capabilities) appears as a small line. If Hermes flags a model (e.g. expensive), the app asks "Switch anyway?" first. `/reasoning` and `/fast` get a card with one button per option, with the current one ticked.

## How Hermes does it (verified in Hermes 0.22.5's code)
- **`/model` with no arguments:**
  - If the platform has a `send_model_picker(chat_id, providers, current_model, current_provider, session_key, on_model_selected, metadata)` hook, Hermes calls it with the providers and models it can switch to (`list_picker_providers`) and sends no text. Telegram, Discord and Slack have this hook.
  - The platform calls `on_model_selected(chat_id, model_id, provider_slug)`. That switches inside the agent's own profile and returns the confirmation text to show.
  - Whether the switch is for this chat only or saved is Hermes' own rule (`model.persist_switch_by_default`, `--global`).
- **The expensive-model check** (`hermes_cli.model_selection_guards.combined_selection_warning`) is run by the platform before switching, as Telegram/Discord do.
- **`/reasoning`, `/fast` and the usage-limit "switch model" offer** use `send_choice_picker(chat_id, title, choices, session_key, on_choice_selected, metadata)`. Each choice is `{value, label, is_current}`, and `on_choice_selected(chat_id, value)` returns the text to show.

## Host
- The adapter implements both hooks. `Prompts.ask_model` and `Prompts.ask_choice` save a card (roles `model` / `choice`) and keep Hermes' callback in memory.
- **An answer:**
  - the host checks the model/option is one offered;
  - for a model, it runs the expensive-model check off the event loop (`needs_confirmation` plus Hermes' message, unless `confirmed`);
  - then it runs Hermes' callback once, marks the card `chosen`, and posts Hermes' reply as a system line.
- **When cards close:**
  - a newer picker of the same kind in that chat replaces an open one;
  - pickers don't close at turn end or on typed messages (nothing in Hermes is waiting);
  - after a restart they're expired, like other cards.

## Protocol
Cards as in `protocol.md` §6, with kinds `model` and `choice`; see §8.

## App
- The Model button sends `/model` (it shows in the chat, like typing it), so Hermes decides everything as usual.
- **Model card:** "Now: model · provider", then **Choose a Model…** and a sheet with:
  - a search field;
  - sections by provider, the current provider first;
  - the current model ticked;
  - Hermes' labels (e.g. "Free");
  - a note when a provider has more models than listed.
- **Choice card:** the title (Markdown) and one button per option, the current one ticked.
- Pickers aren't "waiting on you" items: no orange label on the agents list.

## Tests
- **Plugin:**
  - the card's content;
  - switching;
  - the expensive-model confirmation;
  - unknown models refused;
  - replacement by a newer picker;
  - typing and turn end not closing it;
  - choices;
  - a failing callback.
- **App:**
  - decoding;
  - switching;
  - confirming;
  - choices;
  - the Model button sending `/model`.
- **Simulator** against the real plugin. **Real Hermes** on your machine.

## Prices, the full OpenRouter catalog, and hosts (owner's request, 2026-11-09)
- **Every model shows its price** (input · output per 1M tokens), context size, and badges for reasoning, reading images, and free.
  - OpenRouter prices come from OpenRouter.
  - Other providers' prices come from Hermes' own price table (models.dev, `agent.models_dev.get_model_info`). Unknown prices are left blank, not shown as free.
- **Browse all OpenRouter models:**
  - Hermes' own OpenRouter list is hand-picked (about 60).
  - The browser shows OpenRouter's whole catalog of models that can call tools (about 400; Hermes agents need tools, and Hermes hides tool-less models too).
  - It's grouped by maker, with search, sorting (by maker, cheapest, newest, largest context) and filters (free, reasoning, reads images).
  - Read from OpenRouter's public `/api/v1/models` by the plugin, cached an hour next to `lekora.db` (a stale copy is used if OpenRouter is unreachable).
  - Picking any of them switches through Hermes as usual (the plugin accepts OpenRouter models from that catalog, not only Hermes' picks).
- **A model's hosts** (the (i) button), from OpenRouter's public `/api/v1/models/<id>/endpoints`, cached ten minutes:
  - every company hosting it, cheapest (input + output) first, with prices, discount, uptime, context;
  - its setup (region, quantization, flex/priority tier) as badges, so same-named hosts can be told apart.
  - OpenRouter's public data has no speed or latency figures, so none are shown.
- **Routing:** which hosts OpenRouter may use for that model, saved in Hermes' own setting `provider_routing.models."<id>"` in the agent's `config.yaml`. Hermes re-reads it on every request.

  | Choice | Saved as |
  |---|---|
  | Balanced (OpenRouter's default) | no entry |
  | Cheapest | `sort: price` |
  | Fastest | `sort: throughput` |
  | One host | `only: [tag]` |
  | Prefer these | `order: [tags…]` |
  | Only these | `only: [tags…]` |
  | + No training on my data (any of the above) | `data_collection: deny` |

  A setting written by hand that Lekora doesn't recognise shows as "Custom" and isn't changed unless you save something else.
- **Backups (AGENTS.md rule 8, exception agreed 2026-11-09):**
  - Before any routing change, the agent's `config.yaml` is copied to `<Hermes>/lekora-backups/config/<agent>/`.
  - `config.yaml.original` (from before Lekora ever changed it) is kept forever, plus the ten newest dated copies.
  - Writing uses Hermes' own config writer (`hermes_cli.config.atomic_config_replace`, keeps comments). Only that model's entry changes.
  - The app asks before saving.
- **Training on your data:**
  - OpenRouter's public data doesn't say which hosts store or train on prompts (its website does), so the app can't flag them per host.
  - Instead, "No training on my data" saves `data_collection: deny`, and OpenRouter itself then only uses hosts that don't. Hermes already supports this key.
  - Each host shows where it's based (a flag, from OpenRouter's public `/api/v1/providers`, cached a day). Touch and hold a host for its privacy policy and terms.
- **In the app (your second look, 2026-11-09):**
  - tapping a model asks **This Session Only / Always Use for <agent> / Advanced… / Cancel** (button wording from your fourth look: the buttons themselves say session vs permanent, and name the agent so it's clearly that agent only). Advanced (OpenRouter models) opens the model's page. Its Use This Model button offers the same two choices.
    - These send Hermes' own `/model <id> --provider <slug> --session` or `--global` (your third look, 2026-11-09).
    - `--global` makes Hermes save it as the agent's default model in its own config. That's Hermes writing at your request, like "Always allow".
    - On this path Hermes runs its own expensive-model check, as a confirmation card if needed.
  - the page starts with a summary card: maker, name, id, price and context tiles, ability chips, Use This Model;
  - search matches every word anywhere in a model's name, id or maker;
  - the host page's Save button stays at the bottom while you pick;
  - the sheet can't be swiped away with unsaved picks;
  - switching between "Prefer" and "Only" starts the picks over.

## Known limits
- The phone doesn't know the current model until the picker opens. Showing it in the chat header is a later polish (per-chat settings).
- OpenRouter's public data has no host speed or latency; "Fastest" still works (OpenRouter measures it).
