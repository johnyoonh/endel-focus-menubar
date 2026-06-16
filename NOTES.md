# Flow TaskForge Pomodoro Notes

The menu-bar helper is the Pomodoro runtime for TaskForge tasks. TaskForge remains the task source of truth, and Flow remains the focus timer engine.

Current behavior:

- `Start Focus Timer...` loads open tasks from the Obsidian vault's `10_journal/TaskForge` folder.
- The picker can check or uncheck TaskForge task rows. Checking rewrites the Markdown line to `- [x]`, keeps it visible for undo while the picker is open, and hides it on the next open because only open `- [ ]` tasks are loaded.
- The picker is sorted by urgency and shows separate `Task`, `When`, and `Source` columns.
- `When` is compact because the menu space is limited:
  - upcoming today: `HH:MM`
  - past today: `HH:MM`
  - future days: `+1D`
  - past days: `-1D`
- When both Flow/task end time and due time exist, the earlier `HH:MM` is shown.
- Starting a selected TaskForge task marks its line with `[status:: In Progress]`.
- Completed focus rounds append JSONL records to `99_meta/tasks/pomodoro-sessions.jsonl`.
- `scripts/transition_scheduler.py` scores open TaskForge tasks plus linked TaskNotes for ride, airport, and in-flight work windows. It can emit JSON/ICS or import private calendar blocks with `gcalcli`.
- `Ctrl+Option+Command+F` opens the picker when idle; when a session is assigned, it pauses Flow and opens the menu-bar menu.

`build_app.sh` now rebuilds, signs, kills the old menu-bar instance, and launches the rebuilt app automatically.
