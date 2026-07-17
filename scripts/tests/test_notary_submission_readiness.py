import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
CHECK_SCRIPT = ROOT / "scripts" / "check-notary-submission-readiness.sh"

INTERNAL_XPROTECT_ERROR = """\
App has failed one or more pre-notarization checks.
---------------------------------------------------------------
Internal Xprotect Error
    Severity: Fatal
    Full Error: One or more files in your application triggered an Xprotect
        error.
    Type: Distribution Error

---------------------------------------------------------------
"""


class NotarySubmissionReadinessTests(unittest.TestCase):
    def run_check(self, responses):
        with tempfile.TemporaryDirectory() as temporary_directory:
            temporary_path = Path(temporary_directory)
            app_path = temporary_path / "Example.app"
            app_path.mkdir()
            responses_path = temporary_path / "responses"
            responses_path.mkdir()
            count_path = temporary_path / "count"
            count_path.write_text("0\n", encoding="utf-8")

            for index, (output, status) in enumerate(responses, start=1):
                (responses_path / f"output-{index}").write_text(output, encoding="utf-8")
                (responses_path / f"status-{index}").write_text(
                    f"{status}\n", encoding="utf-8"
                )

            fake_syspolicy = temporary_path / "syspolicy_check"
            fake_syspolicy.write_text(
                """#!/bin/sh
set -eu
count="$(cat "$FAKE_COUNT_FILE")"
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_COUNT_FILE"
cat "$FAKE_RESPONSES_DIR/output-$count"
exit "$(cat "$FAKE_RESPONSES_DIR/status-$count")"
""",
                encoding="utf-8",
            )
            fake_syspolicy.chmod(0o700)

            environment = os.environ.copy()
            environment.update(
                {
                    "FAKE_COUNT_FILE": str(count_path),
                    "FAKE_RESPONSES_DIR": str(responses_path),
                    "SYSPOLICY_CHECK_BIN": str(fake_syspolicy),
                    "SYSPOLICY_CHECK_RETRY_DELAY_SECONDS": "0",
                }
            )
            result = subprocess.run(
                [str(CHECK_SCRIPT), str(app_path)],
                capture_output=True,
                check=False,
                env=environment,
                text=True,
            )
            return result, int(count_path.read_text(encoding="utf-8").strip())

    def test_success_passes_without_retry(self):
        result, invocation_count = self.run_check(
            [("App passed all pre-notarization checks.\n", 0)]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(invocation_count, 1)
        self.assertNotIn("::warning", result.stdout)

    def test_exact_internal_xprotect_error_retries_then_defers_to_notary_service(self):
        result, invocation_count = self.run_check(
            [(INTERNAL_XPROTECT_ERROR, 70)] * 3
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(invocation_count, 3)
        self.assertIn("Apple XProtect preflight unavailable", result.stdout)

    def test_internal_xprotect_error_then_success_passes_without_warning(self):
        result, invocation_count = self.run_check(
            [
                (INTERNAL_XPROTECT_ERROR, 70),
                ("App passed all pre-notarization checks.\n", 0),
            ]
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(invocation_count, 2)
        self.assertNotIn("::warning", result.stdout)

    def test_actionable_exit_70_failure_stays_blocking(self):
        result, invocation_count = self.run_check(
            [("Codesign Error\n    Severity: Fatal\n", 70)]
        )

        self.assertEqual(result.returncode, 70)
        self.assertEqual(invocation_count, 1)

    def test_additional_finding_with_internal_error_stays_blocking(self):
        result, invocation_count = self.run_check(
            [(INTERNAL_XPROTECT_ERROR + "Codesign Error\n    Severity: Fatal\n", 70)]
        )

        self.assertEqual(result.returncode, 70)
        self.assertEqual(invocation_count, 1)

    def test_internal_error_with_different_exit_code_stays_blocking(self):
        result, invocation_count = self.run_check(
            [(INTERNAL_XPROTECT_ERROR, 1)]
        )

        self.assertEqual(result.returncode, 1)
        self.assertEqual(invocation_count, 1)


if __name__ == "__main__":
    unittest.main()
