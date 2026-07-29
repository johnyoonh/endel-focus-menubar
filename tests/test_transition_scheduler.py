from __future__ import annotations

import datetime as dt
import io
import json
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest.mock import patch

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
                    "- [ ] Finish overdue paper [estimate:: 25m] 📅 2030-01-15",
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

    def test_parses_compound_and_decimal_estimates(self) -> None:
        self.assertEqual(scheduler.parse_estimate("1h30m"), 90)
        self.assertEqual(scheduler.parse_estimate("1.5 hours"), 90)
        self.assertEqual(scheduler.parse_estimate("2 hours 15 minutes"), 135)
        self.assertEqual(scheduler.parse_estimate("45m"), 45)

    def test_ride_window_prefers_short_phone_friendly_task(self) -> None:
        with self.make_wiki() as tmp:
            tasks = scheduler.load_open_tasks(Path(tmp))
        window = scheduler.Window(
            title="Lyft",
            start=dt.datetime.fromisoformat("2030-01-15T09:00:00-06:00"),
            end=dt.datetime.fromisoformat("2030-01-15T09:45:00-06:00"),
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
            title="Flight Wi-Fi",
            start=dt.datetime.fromisoformat("2030-01-15T12:00:00-06:00"),
            end=dt.datetime.fromisoformat("2030-01-15T13:00:00-06:00"),
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
            title="Flight Wi-Fi",
            start=dt.datetime.fromisoformat("2030-01-15T12:00:00-06:00"),
            end=dt.datetime.fromisoformat("2030-01-15T13:00:00-06:00"),
            kind="flight",
            connectivity="aa-wifi",
            context="flight",
        )
        scored = {task.title: scheduler.score_task(task, window)[0] for task in tasks}
        self.assertLess(scored["Join Zoom call with client"], 0.75)
        self.assertLess(scored["Upload large video file"], 0.75)
        self.assertLess(scored["Cancel credit card and review legal settlement"], 0.75)

    def test_hard_excludes_incompatible_flight_tasks_despite_bonuses(self) -> None:
        window = scheduler.Window(
            title="Flight Wi-Fi",
            start=dt.datetime.fromisoformat("2030-01-15T12:00:00-06:00"),
            end=dt.datetime.fromisoformat("2030-01-15T13:00:00-06:00"),
            kind="flight",
            connectivity="wifi",
            context="flight",
        )
        for title in ("Review meeting plan", "Review large video upload plan"):
            task = scheduler.Task(
                title=title,
                list_name="inbox",
                file_path=Path("inbox.md"),
                line_number=1,
                raw_line=f"- [ ] {title} [estimate:: 25m] 📅 2030-01-15",
                estimate_minutes=25,
                metadata={"status": "in progress"},
                tags=(),
                task_notes_path=None,
                task_notes_text="",
            )
            with self.subTest(title=title):
                self.assertEqual(scheduler.score_task(task, window)[0], 0.0)
                self.assertEqual(
                    scheduler.build_proposals([task], [window], min_confidence=0.0),
                    [],
                )

    def test_incidental_synchronous_substring_remains_eligible(self) -> None:
        task = scheduler.Task(
            title="Recall spreadsheet review",
            list_name="inbox",
            file_path=Path("inbox.md"),
            line_number=1,
            raw_line="- [ ] Recall spreadsheet review [estimate:: 25m]",
            estimate_minutes=25,
            metadata={},
            tags=(),
            task_notes_path=None,
            task_notes_text="",
        )
        window = scheduler.Window(
            title="Flight Wi-Fi",
            start=dt.datetime.fromisoformat("2030-01-15T12:00:00-06:00"),
            end=dt.datetime.fromisoformat("2030-01-15T13:00:00-06:00"),
            kind="flight",
            connectivity="wifi",
            context="flight",
        )
        self.assertGreater(scheduler.score_task(task, window)[0], 0.75)
        proposals = scheduler.build_proposals([task], [window], min_confidence=0.75)
        self.assertEqual(proposals[0]["task"]["title"], task.title)

    def test_proposal_payloads_do_not_expose_absolute_wiki_paths(self) -> None:
        with self.make_wiki() as tmp:
            wiki_path = Path(tmp)
            tasks = scheduler.load_open_tasks(wiki_path)
            task = next(task for task in tasks if task.title == "Draft flight essay")
            window = scheduler.Window(
                title="Flight Wi-Fi",
                start=dt.datetime.fromisoformat("2030-01-15T12:00:00-06:00"),
                end=dt.datetime.fromisoformat("2030-01-15T13:00:00-06:00"),
                kind="flight",
                connectivity="wifi",
                context="flight",
            )
            proposals = scheduler.build_proposals([task], [window], min_confidence=0.75)
            json_payload = json.dumps({"proposals": proposals})
            ics_payload = scheduler.proposals_to_ics(proposals)

        self.assertEqual(
            proposals[0]["task"]["file"],
            "10_journal/TaskForge/inbox.md",
        )
        self.assertEqual(
            proposals[0]["task"]["task_notes"],
            "10_journal/TaskNotes/Flight Draft.md",
        )
        self.assertNotIn(str(wiki_path), json_payload)
        self.assertNotIn(str(wiki_path), ics_payload)

    def test_unrecognized_task_path_uses_basename_in_payload(self) -> None:
        task = scheduler.Task(
            title="Read offline notes",
            list_name="inbox",
            file_path=Path("/private/example/vault/inbox.md"),
            line_number=3,
            raw_line="- [ ] Read offline notes [estimate:: 10m]",
            estimate_minutes=10,
            metadata={},
            tags=(),
            task_notes_path=None,
            task_notes_text="",
        )
        window = scheduler.Window(
            title="Airport",
            start=dt.datetime.fromisoformat("2030-01-15T12:00:00-06:00"),
            end=dt.datetime.fromisoformat("2030-01-15T13:00:00-06:00"),
            kind="airport",
            connectivity="wifi",
            context="airport",
        )
        proposal = scheduler.build_proposals([task], [window], min_confidence=0.0)[0]
        self.assertEqual(proposal["task"]["file"], "inbox.md")
        self.assertIn("Source: inbox.md:3", proposal["description"])
        self.assertNotIn("/private/example", json.dumps(proposal))

    def test_ics_output_marks_blocks_private_and_dedupable(self) -> None:
        proposal = {
            "title": "Transition work: Reply",
            "start": "2030-01-15T09:00:00-06:00",
            "end": "2030-01-15T09:10:00-06:00",
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
                        "start": "2030-01-16T09:00:00-06:00",
                        "end": "2030-01-16T10:30:00-06:00",
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

    def test_rejects_non_array_windows_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "windows.json"
            path.write_text('{"title": "Airport"}', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "windows JSON must be an array"):
                scheduler.load_windows(path)

    def test_rejects_non_object_window(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "windows.json"
            path.write_text('["Airport"]', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "window 1 must be an object"):
                scheduler.load_windows(path)

    def test_rejects_missing_or_blank_required_window_fields(self) -> None:
        invalid_windows = (
            ({}, "field 'title' must be a non-empty string"),
            (
                {"title": " ", "start": "2030-01-16T09:00:00Z", "end": "2030-01-16T10:00:00Z"},
                "field 'title' must be a non-empty string",
            ),
            (
                {"title": "Airport", "start": "", "end": "2030-01-16T10:00:00Z"},
                "field 'start' must be a non-empty string",
            ),
            (
                {"title": "Airport", "start": "2030-01-16T09:00:00Z"},
                "field 'end' must be a non-empty string",
            ),
        )
        for item, message in invalid_windows:
            with self.subTest(item=item), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "windows.json"
                path.write_text(json.dumps([item]), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, message):
                    scheduler.load_windows(path)

    def test_rejects_naive_or_non_positive_window_datetimes(self) -> None:
        invalid_windows = (
            (
                {
                    "title": "Airport",
                    "start": "2030-01-16T09:00:00",
                    "end": "2030-01-16T10:00:00-06:00",
                },
                "field 'start': datetime must include timezone offset",
            ),
            (
                {
                    "title": "Airport",
                    "start": "2030-01-16T10:00:00-06:00",
                    "end": "2030-01-16T10:00:00-06:00",
                },
                "end must be after start",
            ),
            (
                {
                    "title": "Airport",
                    "start": "2030-01-16T10:00:00-06:00",
                    "end": "2030-01-16T09:00:00-06:00",
                },
                "end must be after start",
            ),
        )
        for item, message in invalid_windows:
            with self.subTest(item=item), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "windows.json"
                path.write_text(json.dumps([item]), encoding="utf-8")
                with self.assertRaisesRegex(ValueError, message):
                    scheduler.load_windows(path)

    def test_existing_marker_distinguishes_matches_from_no_results(self) -> None:
        proposal = {
            "dedupe_marker": "transition-scheduler:abc123",
            "start": "2030-01-15T09:00:00-06:00",
            "end": "2030-01-15T09:10:00-06:00",
        }
        with patch.object(
            scheduler.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, "\nNo Events Found...\n", ""),
        ):
            self.assertFalse(scheduler.existing_marker("Gmail", proposal))
        with patch.object(
            scheduler.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 0, "matching event", ""),
        ):
            self.assertTrue(scheduler.existing_marker("Gmail", proposal))

    def test_existing_marker_raises_on_search_failure(self) -> None:
        proposal = {
            "dedupe_marker": "transition-scheduler:abc123",
            "start": "2030-01-15T09:00:00-06:00",
            "end": "2030-01-15T09:10:00-06:00",
        }
        with patch.object(
            scheduler.subprocess,
            "run",
            return_value=subprocess.CompletedProcess([], 1, "", "authentication failed"),
        ), self.assertRaisesRegex(
            RuntimeError, "gcalcli search failed with exit code 1: authentication failed"
        ):
            scheduler.existing_marker("Gmail", proposal)

    def test_existing_marker_reports_missing_gcalcli(self) -> None:
        proposal = {
            "dedupe_marker": "transition-scheduler:abc123",
            "start": "2030-01-15T09:00:00-06:00",
            "end": "2030-01-15T09:10:00-06:00",
        }
        with patch.object(
            scheduler.subprocess, "run", side_effect=FileNotFoundError
        ), self.assertRaisesRegex(RuntimeError, "gcalcli is required"):
            scheduler.existing_marker("Gmail", proposal)

    def test_cli_requires_an_explicit_windows_file(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            scheduler.main([])
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("WINDOWS_JSON is required", stderr.getvalue())

    def test_cli_accepts_windows_file_as_primary_positional_argument(self) -> None:
        with self.make_wiki() as tmp:
            root = Path(tmp)
            windows_path = root / "windows.json"
            windows_path.write_text(
                json.dumps(
                    [
                        {
                            "title": "Ride window",
                            "start": "2030-01-15T09:00:00-06:00",
                            "end": "2030-01-15T09:30:00-06:00",
                            "kind": "lyft",
                            "connectivity": "phone",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                result = scheduler.main([str(windows_path), "--wiki-path", str(root)])
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue())["proposals"][0]["window_title"], "Ride window")

    def test_cli_keeps_windows_json_flag_as_a_compatibility_alias(self) -> None:
        with self.make_wiki() as tmp:
            root = Path(tmp)
            windows_path = root / "windows.json"
            windows_path.write_text(
                json.dumps(
                    [
                        {
                            "title": "Airport buffer",
                            "start": "2030-01-15T10:00:00-06:00",
                            "end": "2030-01-15T11:00:00-06:00",
                            "kind": "airport",
                            "connectivity": "laptop",
                        }
                    ]
                ),
                encoding="utf-8",
            )
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                result = scheduler.main(
                    ["--windows-json", str(windows_path), "--wiki-path", str(root)]
                )
        self.assertEqual(result, 0)
        self.assertEqual(json.loads(stdout.getvalue())["proposals"][0]["window_title"], "Airport buffer")

    def test_cli_rejects_both_windows_file_forms(self) -> None:
        stderr = io.StringIO()
        with redirect_stderr(stderr), self.assertRaises(SystemExit) as raised:
            scheduler.main(["first.json", "--windows-json", "second.json"])
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("cannot be used together", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
