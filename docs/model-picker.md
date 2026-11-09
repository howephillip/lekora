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

## Known limits
- Hermes lists up to 50 models per provider. For others, type `/model <name> --provider <slug>` (the sheet says so).
- The phone doesn't know the current model until the picker opens. Showing it in the chat header is a later polish (per-chat settings).
