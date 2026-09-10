# Task state and readable output

Status: client requirements and compatibility documentation. No Swift runtime,
installed menu-bar app or checkbox semantics are changed by this document.

The canonical contract is maintained in
[wiki-automation](https://github.com/johnyoonh/wiki-automation/blob/main/docs/human-readable-day-and-task-evidence.md).
Endel remains a TaskForge client and Flow timer companion, not a second scheduler
or a parser of arbitrary ChatGPT conversations.

## Visible interface

Task names, status, When, Source and relevant human descriptions belong in the
picker. Machine-only JSON/HTML learning capsules, inference scores and internal
provenance objects do not. Raw diagnostics may be available separately on explicit
request, not copied into task titles, tooltips, notifications or spoken prompts.
The optional learning-needs sidecar is not task state and must not control
completion or prevent the picker from working when it is absent.

## Preserve fast completion

Keep the normal checkbox/Complete action one click. Do not interrupt every
completion with an obligatory date dialog. A future secondary `Done earlier...`
or `Change task status...` action should allow an optional date/time or approximate
phrase. Its time describes when the outcome became true, not merely when it was
reported. No user-maintained fields per status should be added.

Paused task means the existing on-hold state; paused Flow session only pauses the
timer. Completing a focus round, resetting the cycle, opening a task, or stopping
work is not automatically completing/cancelling the task. Reopen/Resume must be
explicit and must not be inferred from a stale synchronization event.

Endel, the proposed Obsidian TaskForge companion, Reminders and conversation
capture should eventually call one verified state-transition operation owned by
wiki-automation. Do not implement a separate state-event database or natural-date
parser in this app before that backend contract exists. Until it exists, these
new controls remain pending, not silently represented as working commands.

## Identity and completion evidence

Operate on the exact canonical task, never a copied checkbox in a nudge snapshot.
A stale location, unresolved identity, or conflicting physical duplicates must
not create a new task or guess a mutation target. Legitimate recurring occurrences
are distinct; matching titles alone do not establish duplicates. A plain checkbox
records a status observation now; retrospective date corrections must retain
uncertainty rather than fabricate precise completion times.

Existing pomodoro session logs remain separate from task-state history. Preserve
source/resume identities and the current task while showing a human-readable
result. Only a verified backend receipt can be reported as a saved state change.

## Integration acceptance cases (pending implementation)

- Completing normally does not ask another question.
- Done earlier records a retrospective effective time without changing the time
  the correction was recorded.
- A Flow pause/resume/end never changes task state on its own.
- The same completion arriving from another client does not duplicate the event
  or reopen work.
- Unavailable learning analytics do not affect the picker or existing actions.
- Conflicting task identities disable mutation rather than generating a copy.

Build, install and test any actual Swift/UI change using the repository's normal
workflow. Documentation alone requires no app replacement and is not a live test.
