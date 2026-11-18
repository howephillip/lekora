# Schedules (Phase 6, feature 2)

Owner's request (2026-11-15): schedule what agents do, with simple pickers and plain words, plus an advanced section that gives more control.

- **What a schedule is:** a Hermes cron job, as Hermes keeps them (each agent's `cron/jobs.json`, history in its execution log and `cron/output/`). Hermes' own scheduler runs them; Lekora reads and changes them only through Hermes' own cron code (the same functions its dashboard uses), so nothing new runs on the instance and every existing job shows. Lekora keeps nothing about schedules itself.
- **Where:** the left menu › **Schedules** (one per instance): every agent's schedules, grouped by agent (all agents equal). Also Chat Settings › Schedules for one agent.
- **A schedule shows:** its name, what the agent is asked to do, when (in plain words, e.g. "Weekdays at 9:00"), the next run, the last run and whether it worked, where results go, and Paused when paused.
- **New / Edit:**
  - **What to do:** the instruction for the agent, and a name.
  - **When, simple pickers:** Every N minutes or hours; Every day at a time; Weekdays at a time; On chosen days at a time; Monthly on a day at a time; Once at a date and time.
  - **When, plain words:** type it ("every 2h", "weekdays at 9am", "every monday 8am", "in 30m"). Hermes reads it and the screen shows what it understood and the next three times, or Hermes' own hint when it can't.
  - **Advanced:** a cron expression; how many times to run (forever, or N times); where results go (this agent's Lekora chat, kept on the instance only, or as it was, e.g. Telegram); the model to use; skills to load.
- **Results:** by default a new schedule's result arrives in that agent's Lekora chat (Hermes delivers it to `lekora:<agent>`). An existing job keeps its delivery unless you change it.
- **Actions:** Run Now (the next scheduler tick, within a minute), Pause / Resume, Delete (asks first), and History: each run with its time and outcome; open one to read what it produced.
- **Times:** shown in the phone's time zone; schedules run on the instance's clock.
- **Live:** the plugin notices changes to an agent's schedules (a run finishing, an agent or Hermes adding one) within seconds and tells phones.
- **Offline:** needs the instance; offline it says so.
- **Protocol:** `protocol.md` §21.
- **Tests:** plugin `test_schedules.py` (stand-in Hermes: list, preview, create with Lekora delivery, edit, pause/resume, run now, delete, history and output, refusals, change watching, gateway messages) and `test_schedules_hermes.py` (the same against Hermes' real cron code in a throwaway Hermes home); app `ScheduleTests` (the pickers make the right Hermes schedule, plain words preview, every action, live refresh). Simulator: menu, list, create with pickers and words, advanced, run history.
