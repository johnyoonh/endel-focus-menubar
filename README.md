# Flow Focus Menu Bar Helper

This is a small Swift menu-bar helper for starting Flow focus sessions with:

- task name
- focus minutes
- break minutes
- number of sessions

The start dialog loads open TaskForge tasks from the Obsidian vault and lets you search/select one. The top text field filters the task list and also supplies the title for `Inbox Task`. Use `Inbox Task` to evaluate that typed text with the `Evaluate Task Decision` shortcut before saving it to TaskForge. Evaluation runs in the background with a 45-second timeout. If the decision is `now`, or you choose `Start Anyway`, it is saved to Inbox with `[status:: In Progress]` and an estimate matching the focus minutes. If you choose `Do Later`, the app validates the LLM's proposed list, tags, estimate, due date, and scheduled date, then writes to the recommended existing TaskForge list or falls back to `inbox.md`.

Use the checkbox beside a TaskForge task to mark it complete or open again. Checked tasks stay visible until you close the picker so you can undo the action, then disappear the next time the picker is opened.

Run it with:

```sh
chmod +x run.sh
./run.sh
```

Build the app bundle under `~/Applications` with:

```sh
chmod +x build_app.sh
./build_app.sh
open "$HOME/Applications/Endel Focus Menu Bar.app"
```

The first time it controls Flow, macOS may require Automation permission for `Endel Focus Menu Bar`.

The helper sets Flow's session title from the selected task, then starts or resumes Flow through its AppleScript API.

The menu-bar item shows a small circular progress ring and the remaining time. Hover it to see the current phase and session count.

Use `Refresh State` or `Cmd+R` from the menu to resync the menu-bar countdown from Flow. The helper also attempts this refresh on launch.

Display options in the menu:

- `Show Ring`
- `Show Task Name`
- `Show Time`

At least one display option must remain enabled. The ring is green during focus and orange during breaks.

Use `Start at Login` to register or unregister the bundled app as a macOS login item.

`Reset Menu Countdown` only clears the helper display. `Pause Flow Session` sends Flow's pause command. `Reset Flow Cycle` sends Flow's reset command and clears the helper display.

The global shortcut `Ctrl+Option+Command+F` opens the TaskForge picker when no session is assigned. During an assigned session, it pauses Flow and opens the menu-bar menu.

`Set Session Progress...` lets you correct an already-running timer when Endel does not expose total session count. New timers started by the helper persist their task and session count across helper restarts.

Completed focus rounds are appended to:

```text
${TASKFORGE_WIKI_PATH:-~/Documents/wiki}/99_meta/tasks/pomodoro-sessions.jsonl
```

Builds are signed with the available Apple Development identity when present. After switching from the earlier ad-hoc signature, macOS may ask you to add Accessibility permission once more; future rebuilds should keep the same signing identity.
