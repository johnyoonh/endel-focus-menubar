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


if __name__ == "__main__":
    unittest.main()
