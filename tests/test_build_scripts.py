from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
BUILD_SCRIPT = ROOT / "build_app.sh"


class BuildScriptSafetyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = BUILD_SCRIPT.read_text(encoding="utf-8")

    def test_shell_syntax_is_valid(self) -> None:
        subprocess.run(
            ["/bin/sh", "-n", str(BUILD_SCRIPT)],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )

    def test_candidate_is_verified_before_the_installed_app_is_touched(self) -> None:
        compile_at = self.source.index('"$SWIFTC"')
        plist_lint_at = self.source.index('"$PLUTIL" -lint')
        sign_at = self.source.index('"$CODESIGN" --force')
        verify_at = self.source.index('"$CODESIGN" --verify')
        quit_at = self.source.index("quit_running_helper")
        backup_at = self.source.index('"$MV" "$APP_DIR" "$BACKUP_APP"')
        install_at = self.source.index('"$MV" "$CANDIDATE_APP" "$APP_DIR"')

        self.assertLess(compile_at, plist_lint_at)
        self.assertLess(plist_lint_at, sign_at)
        self.assertLess(sign_at, verify_at)
        self.assertLess(verify_at, quit_at)
        self.assertLess(quit_at, backup_at)
        self.assertLess(backup_at, install_at)
        self.assertNotIn('rm -rf "$APP_DIR"', self.source)

    def test_rebuild_preserves_the_installed_apps_signing_identity(self) -> None:
        preserve_at = self.source.index(
            'if [ -z "$SELECTED_SIGNING_IDENTITY" ] && [ -d "$APP_DIR" ]'
        )
        fallback_at = self.source.index(
            'if [ -z "$SELECTED_SIGNING_IDENTITY" ]; then',
            preserve_at,
        )

        self.assertLess(preserve_at, fallback_at)
        self.assertIn(
            '--extract-certificates="$TXN_DIR/installed-cert"',
            self.source[preserve_at:fallback_at],
        )
        self.assertIn(
            '"$SHASUM" -a 1 "$TXN_DIR/installed-cert0"',
            self.source[preserve_at:fallback_at],
        )
        self.assertIn(
            'SIGNING_IDENTITY=${SIGNING_IDENTITY:-}',
            self.source,
        )

    def test_launch_retries_after_a_transient_launch_services_failure(self) -> None:
        committed_at = self.source.index("COMMITTED=1")
        retry_at = self.source.index('while ! "$OPEN" "$APP_DIR"; do')
        failure_at = self.source.index(
            'fail "installed app but could not launch it: $APP_DIR"'
        )

        self.assertLess(committed_at, retry_at)
        self.assertLess(retry_at, failure_at)
        self.assertIn('"$SLEEP" 0.5', self.source[retry_at:])

    def test_failed_compile_preserves_the_existing_app(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            app_parent = Path(tmp)
            installed = app_parent / "Endel Focus Menu Bar.app"
            sentinel = installed / "Contents" / "sentinel"
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text("existing-build\n", encoding="utf-8")
            env = {
                **os.environ,
                "APP_PARENT": str(app_parent),
                "SWIFTC": "/usr/bin/false",
            }

            result = subprocess.run(
                ["/bin/sh", str(BUILD_SCRIPT)],
                cwd=ROOT,
                env=env,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "existing-build\n")
            self.assertEqual(
                list(app_parent.glob(".endel-focus-build.*")),
                [],
            )

    def test_rejects_an_unsafe_app_parent(self) -> None:
        for app_parent in ("/", "relative/path"):
            with self.subTest(app_parent=app_parent):
                result = subprocess.run(
                    ["/bin/sh", str(BUILD_SCRIPT)],
                    cwd=ROOT,
                    env={**os.environ, "APP_PARENT": app_parent},
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("build_app.sh:", result.stderr)


if __name__ == "__main__":
    unittest.main()
