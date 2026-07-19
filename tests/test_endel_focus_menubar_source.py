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


if __name__ == "__main__":
    unittest.main()
