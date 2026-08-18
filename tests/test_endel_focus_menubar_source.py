from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "EndelFocusMenuBar.swift"


class TaskEvaluationScriptRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_uses_current_taskforge_automation_wrapper_paths(self) -> None:
        self.assertIn(
            "99_meta/automation/task/taskforge/run_evaluate_task_decision_shortcut.sh",
            self.source,
        )
        self.assertIn(
            "99_meta/automation/task/mobile/run_evaluate_task_decision_shortcut.sh",
            self.source,
        )
        self.assertIn(
            "99_meta/scripts/taskforge/run_evaluate_task_decision_shortcut.sh",
            self.source,
        )

    def test_preflights_evaluator_script_before_launching_zsh(self) -> None:
        guard = "FileManager.default.isExecutableFile(atPath: TaskForgeStore.evaluateTaskDecisionScriptURL.path)"
        launch = 'process.executableURL = URL(fileURLWithPath: "/bin/zsh")'
        self.assertIn(guard, self.source)
        self.assertIn("missingTaskEvaluationScriptError", self.source)
        self.assertLess(self.source.index(guard), self.source.index(launch))


class TaskPickerInteractionRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_task_rows_expose_the_full_title_as_a_tooltip(self) -> None:
        self.assertIn("cell.toolTip = task.title", self.source)
        self.assertIn("textField.toolTip = task.title", self.source)
        self.assertIn("checkbox.toolTip = task.title", self.source)

    def test_double_click_opens_the_task_line_with_advanced_uri(self) -> None:
        self.assertIn("tableView.doubleAction = #selector(openTaskInObsidian)", self.source)
        self.assertIn('components.host = "adv-uri"', self.source)
        self.assertIn("obsidianVaultIdentifier(for: vaultURL)", self.source)
        self.assertIn('URLQueryItem(name: "filepath", value: relativePath)', self.source)
        self.assertIn('URLQueryItem(name: "line", value: String(task.lineNumber))', self.source)

    def test_menu_opens_latest_nudge_feedback_in_obsidian(self) -> None:
        self.assertIn('title: "Edit Latest Nudge Feedback…"', self.source)
        self.assertIn("#selector(openLatestNudgeFeedback)", self.source)
        self.assertIn("feedbackItem.isEnabled = FileManager.default.fileExists", self.source)
        self.assertIn('process.arguments = ["open-latest-nudge"]', self.source)
        self.assertIn('environment["WIKI_AUTOMATION_NUDGE_DETAILS_PATH"]', self.source)


class AccessibilityInstructionRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_installed_app_instructions_name_the_app_and_settings_path(self) -> None:
        self.assertIn('Bundle.main.bundleURL.pathExtension.lowercased() == "app"', self.source)
        self.assertIn("System Settings → Privacy & Security → Accessibility", self.source)
        self.assertIn("choose Endel Focus Menu Bar.app from ~/Applications", self.source)

    def test_run_script_instructions_limit_terminal_permission_to_that_mode(self) -> None:
        self.assertIn("Terminal/Swift is needed only because the helper was launched with ./run.sh", self.source)
        self.assertIn("When using the installed app, enable Endel Focus Menu Bar.app instead", self.source)


class HelperShutdownRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_quitting_helper_does_not_terminate_flow(self) -> None:
        self.assertNotIn("closeFlowIfRunning", self.source)
        self.assertNotIn("flow.terminate()", self.source)
        self.assertNotIn("flow.forceTerminate()", self.source)
        self.assertNotIn("applicationWillTerminate", self.source)

    def test_helper_quit_action_remains_available(self) -> None:
        self.assertIn("@objc private func quit()", self.source)
        self.assertIn("NSApp.terminate(nil)", self.source)


class SessionStartTransactionRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SOURCE.read_text(encoding="utf-8")

    def test_flow_starts_before_local_or_taskforge_state_is_committed(self) -> None:
        start_session = self.source.index(
            "private func startSession(_ config: FocusConfig) -> Bool"
        )
        start_flow = self.source.index(
            "guard startFlow(config) else { return false }",
            start_session,
        )
        commit_config = self.source.index("self.config = config", start_session)
        mark_task = self.source.index(
            "markSelectedTaskInProgress(config)",
            start_session,
        )
        persist_snapshot = self.source.index(
            "persistSessionSnapshot()",
            start_session,
        )
        start_countdown = self.source.index(
            "startLocalCountdown()",
            start_session,
        )

        self.assertLess(start_flow, commit_config)
        self.assertLess(start_flow, mark_task)
        self.assertLess(start_flow, persist_snapshot)
        self.assertLess(start_flow, start_countdown)

    def test_new_immediate_task_stays_open_until_flow_starts(self) -> None:
        create_start = self.source.index(
            "private func createTaskAndCompleteStart("
        )
        next_method = self.source.index(
            "private func createTaskAndClose(",
            create_start,
        )
        method = self.source[create_start:next_method]
        self.assertIn("inProgress: false", method)
        self.assertIn("preferUndated: false", method)
        self.assertIn("markTaskInProgressOnStart: true", method)

    def test_prompt_closes_only_after_successful_start(self) -> None:
        self.assertIn(
            "private var completion: ((FocusConfig?) -> Bool)?",
            self.source,
        )
        self.assertIn("if shouldClose {\n            close()\n        }", self.source)
        self.assertIn(
            "private func startFlow(_ config: FocusConfig) -> Bool",
            self.source,
        )


if __name__ == "__main__":
    unittest.main()
