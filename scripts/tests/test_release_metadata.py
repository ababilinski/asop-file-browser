from __future__ import annotations

import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "release_metadata.py"
SPEC = importlib.util.spec_from_file_location("release_metadata", SCRIPT)
assert SPEC and SPEC.loader
release_metadata = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = release_metadata
SPEC.loader.exec_module(release_metadata)


def pull_request(
    number: int,
    title: str,
    label: str,
    merged_at: str = "2026-07-15T12:00:00Z",
    extra_labels: list[str] | None = None,
) -> dict[str, object]:
    labels = [label, *(extra_labels or [])]
    return {
        "number": number,
        "title": title,
        "url": f"https://github.com/example/project/pull/{number}",
        "mergedAt": merged_at,
        "labels": [{"name": name} for name in labels],
    }


class LabelValidationTests(unittest.TestCase):
    def test_missing_release_label_is_rejected(self) -> None:
        with self.assertRaisesRegex(release_metadata.ReleaseMetadataError, "exactly one"):
            release_metadata.validate_release_labels(["bug"])

    def test_multiple_release_labels_are_rejected(self) -> None:
        with self.assertRaisesRegex(release_metadata.ReleaseMetadataError, "multiple"):
            release_metadata.validate_release_labels(["release:minor", "release:patch"])

    def test_each_release_label_returns_its_bump(self) -> None:
        for bump in ("major", "minor", "patch", "none"):
            with self.subTest(bump=bump):
                self.assertEqual(
                    release_metadata.validate_release_labels([f"release:{bump}", "documentation"]),
                    bump,
                )

    def test_validate_labels_cli_accepts_github_json(self) -> None:
        output = io.StringIO()
        with redirect_stdout(output):
            result = release_metadata.main(
                [
                    "validate-labels",
                    "--labels-json",
                    '[{"name":"bug"},{"name":"release:patch"}]',
                ]
            )
        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), "patch\n")


class ReleasePlanTests(unittest.TestCase):
    since = datetime(2026, 7, 10, tzinfo=timezone.utc)

    def test_major_minor_and_patch_versions(self) -> None:
        cases = {
            "major": "2.0.0",
            "minor": "1.5.0",
            "patch": "1.4.6",
        }
        for bump, expected in cases.items():
            with self.subTest(bump=bump):
                plan = release_metadata.create_release_plan(
                    "1.4.5", [pull_request(1, "Change", f"release:{bump}")], self.since
                )
                self.assertEqual(plan.next_version, expected)
                self.assertEqual(plan.bump, bump)

    def test_highest_bump_wins(self) -> None:
        plan = release_metadata.create_release_plan(
            "1.4.5",
            [
                pull_request(1, "Fix", "release:patch"),
                pull_request(2, "Feature", "release:minor"),
                pull_request(3, "Breaking", "release:major"),
            ],
            self.since,
        )
        self.assertEqual(plan.next_version, "2.0.0")
        self.assertEqual(plan.bump, "major")

    def test_old_none_and_release_next_pull_requests_are_filtered(self) -> None:
        release_branch_pr = pull_request(5, "Release branch", "release:major")
        release_branch_pr["headRefName"] = "release/next"
        plan = release_metadata.create_release_plan(
            "1.0.0",
            [
                pull_request(1, "Old", "release:major", "2026-07-09T23:59:59Z"),
                pull_request(2, "No release", "release:none"),
                pull_request(3, "Release PR", "release:major", extra_labels=["release/next"]),
                pull_request(4, "Included", "release:patch"),
                release_branch_pr,
            ],
            self.since,
        )
        self.assertEqual(plan.next_version, "1.0.1")
        self.assertEqual([pr.number for pr in plan.pull_requests], [4])

    def test_no_bump_has_no_next_version(self) -> None:
        plan = release_metadata.create_release_plan(
            "1.0.0", [pull_request(1, "No release", "release:none")], self.since
        )
        self.assertIsNone(plan.next_version)
        self.assertIsNone(plan.bump)
        self.assertEqual(plan.pull_requests, ())

    def test_no_boundary_keeps_pr_merged_at_equal_timestamp(self) -> None:
        merged_at = "2026-07-10T00:00:00Z"
        item = pull_request(1, "Equal timestamp", "release:patch", merged_at)

        bounded = release_metadata.create_release_plan(
            "1.0.0",
            [item],
            datetime(2026, 7, 10, tzinfo=timezone.utc),
        )
        unbounded = release_metadata.create_release_plan("1.0.0", [item], None)

        self.assertIsNone(bounded.next_version)
        self.assertEqual(unbounded.next_version, "1.0.1")
        self.assertEqual([pr.number for pr in unbounded.pull_requests], [1])


class FileOutputTests(unittest.TestCase):
    def test_prepare_groups_changes_and_writes_all_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            changelog = root / "CHANGELOG.md"
            version = root / "VERSION"
            summary = root / "summary.md"
            output = root / "github-output"
            prs = root / "prs.json"
            changelog.write_text(
                "# Changelog\n\n## [Unreleased]\n\n## [1.2.3] - 2026-07-01\n\n"
                "- Earlier change\n\n"
                "[Unreleased]: https://github.com/example/project/compare/1.2.3...HEAD\n"
                "[1.2.3]: https://github.com/example/project/releases/tag/1.2.3\n",
                encoding="utf-8",
            )
            version.write_text("1.2.3\n", encoding="utf-8")
            prs.write_text(
                json.dumps(
                    [
                        pull_request(3, "Fix [preview]", "release:patch"),
                        pull_request(2, "Add transfer view", "release:minor"),
                        pull_request(1, "Remove old format", "release:major"),
                    ]
                ),
                encoding="utf-8",
            )

            stdout = io.StringIO()
            with redirect_stdout(stdout):
                result = release_metadata.main(
                    [
                        "prepare",
                        "--prs-json",
                        str(prs),
                        "--since",
                        "2026-07-10T00:00:00Z",
                        "--release-date",
                        "2026-07-16",
                        "--repository",
                        "example/project",
                        "--changelog",
                        str(changelog),
                        "--version-file",
                        str(version),
                        "--summary",
                        str(summary),
                        "--github-output",
                        str(output),
                    ]
                )

            self.assertEqual(result, 0)
            content = changelog.read_text(encoding="utf-8")
            self.assertLess(content.index("## [Unreleased]"), content.index("## [2.0.0]"))
            self.assertLess(content.index("## [2.0.0]"), content.index("## [1.2.3]"))
            self.assertIn("### Breaking changes", content)
            self.assertIn("### New features", content)
            self.assertIn("### Fixes and improvements", content)
            self.assertIn(
                "Fix \\[preview\\] ([#3](https://github.com/example/project/pull/3))",
                content,
            )
            self.assertIn(
                "[Unreleased]: https://github.com/example/project/compare/2.0.0...HEAD",
                content,
            )
            self.assertIn(
                "[2.0.0]: https://github.com/example/project/compare/1.2.3...2.0.0",
                content,
            )
            self.assertEqual(version.read_text(encoding="utf-8"), "2.0.0\n")
            self.assertIn("## Release 2.0.0", summary.read_text(encoding="utf-8"))
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "has_release=true\nnext_version=2.0.0\nincluded_pr_numbers=1,2,3\n",
            )

    def test_no_bump_leaves_release_files_unchanged(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            changelog = root / "CHANGELOG.md"
            version = root / "VERSION"
            output = root / "github-output"
            prs = root / "prs.json"
            original_changelog = "# Changelog\n\n## [Unreleased]\n"
            changelog.write_text(original_changelog, encoding="utf-8")
            version.write_text("1.2.3\n", encoding="utf-8")
            prs.write_text(
                json.dumps([pull_request(1, "Internal work", "release:none")]),
                encoding="utf-8",
            )

            with redirect_stdout(io.StringIO()):
                release_metadata.main(
                    [
                        "prepare",
                        "--prs-json",
                        str(prs),
                        "--since",
                        "2026-07-10T00:00:00Z",
                        "--release-date",
                        "2026-07-16",
                        "--changelog",
                        str(changelog),
                        "--version-file",
                        str(version),
                        "--github-output",
                        str(output),
                    ]
                )

            self.assertEqual(changelog.read_text(encoding="utf-8"), original_changelog)
            self.assertEqual(version.read_text(encoding="utf-8"), "1.2.3\n")
            self.assertEqual(
                output.read_text(encoding="utf-8"),
                "has_release=false\nnext_version=\nincluded_pr_numbers=\n",
            )


class VersionTransitionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository = Path(self.temporary_directory.name)
        self.git("init", "--quiet")
        self.git("config", "user.name", "Release Tests")
        self.git("config", "user.email", "release-tests@example.com")
        self.write("VERSION", "0.2.0\n")
        self.commit("Initial version")
        self.git("tag", "0.2.0")

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def write(self, relative_path: str, content: str) -> None:
        path = self.repository / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")

    def commit(self, message: str) -> str:
        self.git("add", "--all")
        self.git("commit", "--quiet", "--message", message)
        return self.git("rev-parse", "HEAD")

    def run_command(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "version-transition", *arguments],
            cwd=self.repository,
            check=False,
            capture_output=True,
            text=True,
        )

    def add_transition_and_later_commit(self) -> tuple[str, str]:
        self.write("VERSION", "0.3.0\n")
        transition = self.commit("Prepare 0.3.0")
        self.write("notes.txt", "A later change\n")
        head = self.commit("Later release fix")
        return transition, head

    def test_finds_transition_before_later_linear_commits(self) -> None:
        transition, head = self.add_transition_and_later_commit()
        result = self.run_command(
            "--from-ref",
            "0.2.0",
            "--head",
            head,
            "--version",
            "0.3.0",
            "--expect-commit",
            transition,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, f"{transition}\n")

    def test_strict_semver_start_ref_can_predate_version_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)

            def git(*arguments: str) -> str:
                result = subprocess.run(
                    ["git", *arguments],
                    cwd=repository,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                return result.stdout.strip()

            git("init", "--quiet")
            git("config", "user.name", "Release Tests")
            git("config", "user.email", "release-tests@example.com")
            (repository / "README.md").write_text("Legacy release\n", encoding="utf-8")
            git("add", "README.md")
            git("commit", "--quiet", "--message", "Release 0.2.0")
            git("tag", "0.2.0")
            (repository / "VERSION").write_text("0.3.0\n", encoding="utf-8")
            git("add", "VERSION")
            git("commit", "--quiet", "--message", "Prepare 0.3.0")
            transition = git("rev-parse", "HEAD")
            (repository / "notes.txt").write_text("Later change\n", encoding="utf-8")
            git("add", "notes.txt")
            git("commit", "--quiet", "--message", "Later release fix")

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "version-transition",
                    "--from-ref",
                    "0.2.0",
                    "--head",
                    "HEAD",
                    "--version",
                    "0.3.0",
                ],
                cwd=repository,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{transition}\n")

    def test_missing_prefix_is_allowed_until_version_file_appears(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)

            def git(*arguments: str) -> str:
                result = subprocess.run(
                    ["git", *arguments],
                    cwd=repository,
                    check=True,
                    capture_output=True,
                    text=True,
                )
                return result.stdout.strip()

            def commit(path: str, content: str, message: str) -> str:
                (repository / path).write_text(content, encoding="utf-8")
                git("add", "--all")
                git("commit", "--quiet", "--message", message)
                return git("rev-parse", "HEAD")

            git("init", "--quiet")
            git("config", "user.name", "Release Tests")
            git("config", "user.email", "release-tests@example.com")
            commit("README.md", "Legacy release\n", "Release 0.2.0")
            git("tag", "0.2.0")
            commit("notes.txt", "First rebased change\n", "First rebased change")
            commit("more-notes.txt", "Second rebased change\n", "Second rebased change")
            commit("VERSION", "0.2.0\n", "Begin tracked version metadata")
            transition = commit("VERSION", "0.3.0\n", "Prepare 0.3.0")
            head = commit("release-notes.txt", "Ready\n", "Finish release notes")

            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "version-transition",
                    "--from-ref",
                    "0.2.0",
                    "--head",
                    head,
                    "--version",
                    "0.3.0",
                ],
                cwd=repository,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, f"{transition}\n")

    def test_wrong_expected_commit_is_rejected(self) -> None:
        transition, head = self.add_transition_and_later_commit()
        self.assertNotEqual(transition, head)
        result = self.run_command(
            "--from-ref",
            "0.2.0",
            "--head",
            head,
            "--version",
            "0.3.0",
            "--expect-commit",
            head,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("not expected commit", result.stderr)

    def test_wrong_head_version_is_rejected(self) -> None:
        self.write("VERSION", "0.3.0\n")
        self.commit("Prepare 0.3.0")
        self.write("VERSION", "0.3.1\n")
        head = self.commit("Advance again")
        result = self.run_command(
            "--from-ref",
            "0.2.0",
            "--head",
            head,
            "--version",
            "0.3.0",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("not requested version", result.stderr)

    def test_non_ancestor_range_is_rejected(self) -> None:
        self.git("checkout", "--quiet", "-b", "side")
        self.write("VERSION", "0.2.1\n")
        side = self.commit("Side version")
        self.git("checkout", "--quiet", "--detach", "0.2.0")
        self.write("VERSION", "0.3.0\n")
        head = self.commit("Main release")
        result = self.run_command(
            "--from-ref",
            side,
            "--head",
            head,
            "--version",
            "0.3.0",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("is not an ancestor", result.stderr)

    def test_multiple_transitions_are_rejected(self) -> None:
        self.write("VERSION", "0.3.0\n")
        self.commit("First transition")
        self.write("VERSION", "0.4.0\n")
        self.commit("Move away")
        self.write("VERSION", "0.3.0\n")
        head = self.commit("Second transition")
        result = self.run_command(
            "--from-ref",
            "0.2.0",
            "--head",
            head,
            "--version",
            "0.3.0",
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("found 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
