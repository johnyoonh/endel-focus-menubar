from __future__ import annotations

import datetime as dt
import json
import tempfile
import unittest
from pathlib import Path

from scripts import transition_scheduler as scheduler


class TransitionSchedulerTests(unittest.TestCase):
    def make_wiki(self) -> tempfile.TemporaryDirectory[str]:
        tmp = tempfile.TemporaryDirectory()
        root = Path(tmp.name)
        (root / "10_journal" / "TaskForge").mkdir(parents=True)
        (root / "10_journal" / "TaskNotes").mkdir(parents=True)
        (root / "10_journal" / "TaskNotes" / "Flight Draft.md").write_text(
            "Deep writing task. Good with laptop and Wi-Fi. No calls needed.",
            encoding="utf-8",
        )
        (root / "10_journal" / "TaskForge" / "inbox.md").write_text(
            "\n".join(
                [
                    "- [ ] Reply to quick email [estimate:: 10m] #email",
                    "- [ ] Draft flight essay [[10_journal/TaskNotes/Flight Draft]] [estimate:: 45m] #writing",
                    "- [ ] Join Zoom call with client [estimate:: 30m]",
                    "- [ ] Upload large video file [estimate:: 20m]",
                    "- [ ] Finish overdue paper [estimate:: 25m] 📅 2026-06-16",
                    "- [ ] Cancel credit card and review legal settlement [estimate:: 25m]",
                ]
            ),
            encoding="utf-8",
        )
        return tmp

    def test_loads_taskforge_tasks_and_linked_tasknotes(self) -> None:
        with self.make_wiki() as tmp:
            tasks = scheduler.load_open_tasks(Path(tmp))
        titles = [task.title for task in tasks]
        self.assertIn("Draft flight essay", titles)
        draft = next(task for task in tasks if task.title == "Draft flight essay")
        self.assertIn("Good with laptop", draft.task_notes_text)
        self.assertEqual(draft.estimate_minutes, 45)

    def test_ride_window_prefers_short_phone_friendly_task(self) -> None:
        with self.make_wiki() as tmp:
            tasks = scheduler.load_open_tasks(Path(tmp))
        window = scheduler.Window(
            title="Lyft",
            start=dt.datetime.fromisoformat("2026-06-16T13:15:00-05:00"),
            end=dt.datetime.fromisoformat("2026-06-16T14:15:00-05:00"),
            kind="lyft",
            connectivity="phone",
            context="ride",
        )
        proposals = scheduler.build_proposals(tasks, [window], min_confidence=0.75)
        self.assertEqual(proposals[0]["task"]["title"], "Reply to quick email")

    def test_flight_wifi_prefers_deep_laptop_task(self) -> None:
        with self.make_wiki() as tmp:
            tasks = scheduler.load_open_tasks(Path(tmp))
        window = scheduler.Window(
            title="AA Wi-Fi",
            start=dt.datetime.fromisoformat("2026-06-16T16:45:00-05:00"),
            end=dt.datetime.fromisoformat("2026-06-16T17:35:00-07:00"),
            kind="flight",
            connectivity="aa-wifi",
            context="flight",
        )
        proposals = scheduler.build_proposals(tasks, [window], min_confidence=0.75)
        self.assertEqual(proposals[0]["task"]["title"], "Draft flight essay")

    def test_avoids_synchronous_and_large_upload_tasks(self) -> None:
        with self.make_wiki() as tmp:
            tasks = scheduler.load_open_tasks(Path(tmp))
        window = scheduler.Window(
            title="AA Wi-Fi",
            start=dt.datetime.fromisoformat("2026-06-16T16:45:00-05:00"),
            end=dt.datetime.fromisoformat("2026-06-16T17:35:00-07:00"),
            kind="flight",
            connectivity="aa-wifi",
            context="flight",
        )
        scored = {task.title: scheduler.score_task(task, window)[0] for task in tasks}
        self.assertLess(scored["Join Zoom call with client"], 0.75)
        self.assertLess(scored["Upload large video file"], 0.75)
        self.assertLess(scored["Cancel credit card and review legal settlement"], 0.75)

    def test_ics_output_marks_blocks_private_and_dedupable(self) -> None:
        proposal = {
            "title": "Transition work: Reply",
            "start": "2026-06-16T13:15:00-05:00",
            "end": "2026-06-16T13:25:00-05:00",
            "description": "Marker: transition-scheduler:abc123",
            "dedupe_marker": "transition-scheduler:abc123",
        }
        ics = scheduler.proposals_to_ics([proposal])
        self.assertIn("CLASS:PRIVATE", ics)
        self.assertIn("UID:transition-scheduler:abc123@endel-focus", ics)

    def test_loads_explicit_windows_json(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            json.dump(
                [
                    {
                        "title": "Airport",
                        "start": "2026-06-17T21:15:00-07:00",
                        "end": "2026-06-17T22:45:00-07:00",
                        "kind": "airport",
                        "connectivity": "laptop",
                    }
                ],
                handle,
            )
            path = Path(handle.name)
        try:
            windows = scheduler.load_windows(path)
        finally:
            path.unlink(missing_ok=True)
        self.assertEqual(windows[0].title, "Airport")
        self.assertEqual(windows[0].minutes, 90)


if __name__ == "__main__":
    unittest.main()
