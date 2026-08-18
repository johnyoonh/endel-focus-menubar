# Endel Focus Menu Bar

Endel Focus Menu Bar is a native macOS menu-bar companion for starting and
tracking Flow focus sessions from TaskForge tasks. It is intended for macOS
users who already use Flow and optionally keep TaskForge tasks in an Obsidian
vault.

This repository owns the menu-bar runtime, Flow automation, TaskForge picker,
Pomodoro logging, and travel-transition scheduler. It does not own the Flow
timer engine, the TaskForge vault format, Obsidian, the task-evaluation
Shortcut, or calendar synchronization. Despite the historical Endel name, the
current timer integration targets Flow.

## Prerequisites

- macOS 13 or later.
- Apple's Swift toolchain, available through Xcode or Xcode Command Line Tools.
- Flow installed at `/Applications/Flow.app`.
- For TaskForge integration, an Obsidian vault containing
  `10_journal/TaskForge`.
- For opening task rows in Obsidian, the Advanced URI community plugin.
- For `Inbox Task` evaluation, the `Evaluate Task Decision` Shortcut and its
  executable TaskForge wrapper.
- For the transition scheduler, `uv`; `gcalcli` is needed only with `--apply`.

## Wiki path

Set `TASKFORGE_WIKI_PATH` when the vault is not in a default location. The app
uses the environment variable first, then `$HOME/wiki` when that directory
contains `10_journal/TaskForge`, and otherwise `$HOME/Documents/wiki`.

For shell commands, resolve the same path once so an unset environment variable
never becomes an empty `--wiki-path` argument:

```sh
if [ -n "${TASKFORGE_WIKI_PATH:-}" ]; then
  WIKI_PATH="$TASKFORGE_WIKI_PATH"
elif [ -d "$HOME/wiki/10_journal/TaskForge" ]; then
  WIKI_PATH="$HOME/wiki"
else
  WIKI_PATH="$HOME/Documents/wiki"
fi
```

## Run or install

Run directly through the Swift interpreter during development:

```sh
./run.sh
```

Or build, sign, install, and launch the app under `$HOME/Applications`:

```sh
./build_app.sh
```

The build is compiled and signed in a unique staging directory. An existing
installed bundle remains intact until staging succeeds. The available Apple
Development identity is used when present; otherwise the bundle is signed
ad hoc. Rebuilds preserve the installed app's signing identity so macOS
permissions remain valid. To select a different certificate deliberately, run
`SIGNING_IDENTITY=APPLE_DEVELOPMENT_CERT_SHA1 ./build_app.sh`.

The first time the helper controls Flow, macOS may require Automation or
Accessibility permission. For the installed app, add
`$HOME/Applications/Endel Focus Menu Bar.app` under **System Settings → Privacy
& Security → Accessibility**. Enable Terminal or Swift only when launching
through `./run.sh`.

## Use the menu-bar helper

`Start Flow Session...` selects the task name, focus minutes, break minutes,
and number of sessions. The picker loads open TaskForge tasks, supports search,
shows full descriptions in tooltips, and can complete or reopen a task.
Double-clicking a task opens its source line in Obsidian.

`Inbox Task` sends typed text to the external `Evaluate Task Decision`
workflow. A task chosen for now is saved with `[status:: In Progress]`; a task
deferred until later is validated and written to the recommended existing
TaskForge list or `inbox.md`.

`Edit Latest Nudge Feedback…` opens Wiki Automation's latest private nudge
feedback note in Obsidian through the Wiki Automation helper. The item remains
disabled until a nudge has created the ignored local note under
`99_meta/system/task/scheduler/nudges/`. After the edited note has been stable
for a few seconds, its feedback is applied to later nudges.

The status item can show a progress ring, task name, and remaining time.
`Refresh State` (`Cmd+R`) resynchronizes it with Flow. `Pause Flow Session`,
`Reset Flow Cycle`, and `Reset Menu Countdown` control the timer or local
display as their names indicate. `Start at Login` manages the bundled app as a
macOS login item.

The global shortcut `Ctrl+Option+Command+F` opens the picker while idle. During
an assigned session, it pauses Flow and opens the menu. `Set Session
Progress...` corrects a running timer when the total session count is not
available from Flow.

Completed focus rounds are appended beneath the resolved wiki path:

```text
$WIKI_PATH/99_meta/tasks/pomodoro-sessions.jsonl
```

## Plan transition work

Copy and edit `examples/transition-windows.example.json`, keeping an explicit
timezone offset on every start and end time. Preview proposals without changing
the calendar:

```sh
uv run --python 3.12 python scripts/transition_scheduler.py \
  path/to/windows.json \
  --wiki-path "$WIKI_PATH"
```

The scheduler reads open TaskForge tasks and linked TaskNotes, scores them for
ride, airport, and in-flight windows, and prints JSON proposals. The explicit
windows file prevents accidental reuse of an old itinerary. The compatibility
form `--windows-json path/to/windows.json` is also supported.

After reviewing the preview, import high-confidence blocks as private ICS
events:

```sh
uv run --python 3.12 python scripts/transition_scheduler.py \
  path/to/windows.json \
  --wiki-path "$WIKI_PATH" \
  --apply \
  --calendar Gmail
```

`--apply` changes the selected calendar and requires an authenticated `gcalcli`
installation.

## Local validation

Run the Python regression suite:

```sh
PYTHONDONTWRITEBYTECODE=1 \
  uv run --python 3.12 python -m unittest discover -v
```

Check shell syntax and type-check the Swift app for its minimum macOS target:

```sh
sh -n run.sh build_app.sh
/usr/bin/swiftc \
  -typecheck \
  -target "$(uname -m)-apple-macosx13.0" \
  EndelFocusMenuBar.swift \
  -framework AppKit \
  -framework ApplicationServices \
  -framework Carbon \
  -framework ServiceManagement \
  -framework Vision
```
