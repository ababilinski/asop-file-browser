#!/usr/bin/env python3
"""Validate release labels and prepare version metadata for a release PR."""

from __future__ import annotations

import argparse
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unicodedata
from dataclasses import dataclass
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any, Iterable, Sequence


RELEASE_LABELS = {
    "release:major": "major",
    "release:minor": "minor",
    "release:patch": "patch",
    "release:none": "none",
}
IGNORED_LABEL = "release/next"
BUMP_RANK = {"none": 0, "patch": 1, "minor": 2, "major": 3}
SECTION_FOR_BUMP = {
    "major": "Breaking changes",
    "minor": "New features",
    "patch": "Fixes and improvements",
}
SEMVER_PATTERN = re.compile(r"^(?:v)?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
CHANGELOG_HEADING_PATTERN = re.compile(r"^##\s+\[([^]]+)](?:\s+-\s+.*)?\s*$", re.MULTILINE)
MARKDOWN_ESCAPES = re.compile(r"([\\`*_[\]<>])")


class ReleaseMetadataError(ValueError):
    """An invalid release label or release input."""


@dataclass(frozen=True)
class PullRequest:
    number: int
    title: str
    url: str
    merged_at: datetime
    bump: str


@dataclass(frozen=True)
class ReleasePlan:
    current_version: str
    next_version: str | None
    bump: str | None
    pull_requests: tuple[PullRequest, ...]


def parse_semver(value: str) -> tuple[int, int, int]:
    match = SEMVER_PATTERN.fullmatch(value.strip())
    if not match:
        raise ReleaseMetadataError(
            f"Invalid version {value!r}; expected three numeric parts such as 1.2.3."
        )
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def format_semver(parts: tuple[int, int, int]) -> str:
    return ".".join(str(part) for part in parts)


def bump_version(current: str, bump: str) -> str:
    major, minor, patch = parse_semver(current)
    if bump == "major":
        return f"{major + 1}.0.0"
    if bump == "minor":
        return f"{major}.{minor + 1}.0"
    if bump == "patch":
        return f"{major}.{minor}.{patch + 1}"
    raise ReleaseMetadataError(f"Cannot create a release for bump type {bump!r}.")


def label_names(labels: Any) -> list[str]:
    if isinstance(labels, dict) and "labels" in labels:
        labels = labels["labels"]
    if not isinstance(labels, list):
        raise ReleaseMetadataError("Labels must be a JSON array.")

    names: list[str] = []
    for label in labels:
        if isinstance(label, str):
            name = label
        elif isinstance(label, dict) and isinstance(label.get("name"), str):
            name = label["name"]
        else:
            raise ReleaseMetadataError("Each label must be a string or an object with a name.")
        names.append(name.strip().lower())
    return names


def validate_release_labels(labels: Iterable[str], context: str = "Pull request") -> str:
    names = {label.strip().lower() for label in labels}
    matching = sorted(names.intersection(RELEASE_LABELS))
    if len(matching) != 1:
        expected = ", ".join(sorted(RELEASE_LABELS))
        if not matching:
            raise ReleaseMetadataError(
                f"{context} must have exactly one release label. Choose one of: {expected}."
            )
        raise ReleaseMetadataError(
            f"{context} has multiple release labels: {', '.join(matching)}. Keep exactly one."
        )
    return RELEASE_LABELS[matching[0]]


def parse_timestamp(value: str, label: str) -> datetime:
    normalized = value.strip()
    if normalized.endswith("Z"):
        normalized = f"{normalized[:-1]}+00:00"
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as error:
        raise ReleaseMetadataError(f"Invalid {label} timestamp: {value!r}.") from error
    if parsed.tzinfo is None:
        raise ReleaseMetadataError(f"{label} timestamp must include a UTC offset or Z.")
    return parsed.astimezone(timezone.utc)


def normalize_title(value: str) -> str:
    """Return a single-line Markdown-safe title without invisible controls."""

    normalized = unicodedata.normalize("NFKC", value)
    normalized = "".join(
        character
        for character in normalized
        if unicodedata.category(character) not in {"Cc", "Cf", "Cs"}
    )
    normalized = " ".join(normalized.split()).strip(" -")
    if not normalized:
        return "Untitled change"
    return MARKDOWN_ESCAPES.sub(r"\\\1", normalized)


def _read_pr_list(path: Path) -> list[dict[str, Any]]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise ReleaseMetadataError(f"Could not read pull-request JSON: {error}.") from error
    except json.JSONDecodeError as error:
        raise ReleaseMetadataError(f"Pull-request JSON is invalid: {error}.") from error

    if isinstance(payload, dict):
        payload = payload.get("items", payload.get("pullRequests"))
    if not isinstance(payload, list) or not all(isinstance(item, dict) for item in payload):
        raise ReleaseMetadataError("Pull-request JSON must be an array of objects.")
    return payload


def _pr_url(item: dict[str, Any], number: int, repository: str | None) -> str:
    url = item.get("url")
    if isinstance(url, str) and re.fullmatch(r"https://github\.com/[^\s]+/pull/[0-9]+", url):
        return url
    if repository and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        return f"https://github.com/{repository}/pull/{number}"
    raise ReleaseMetadataError(
        f"Pull request #{number} needs a GitHub URL or a valid --repository owner/name."
    )


def collect_pull_requests(
    items: Sequence[dict[str, Any]],
    since: datetime | None,
    repository: str | None = None,
) -> tuple[PullRequest, ...]:
    collected: list[PullRequest] = []
    for item in items:
        raw_labels = label_names(item.get("labels", []))
        head_ref = item.get("headRefName", item.get("head_ref"))
        if IGNORED_LABEL in raw_labels or head_ref == IGNORED_LABEL:
            continue

        merged_value = item.get("mergedAt", item.get("merged_at"))
        if not isinstance(merged_value, str):
            number = item.get("number", "unknown")
            raise ReleaseMetadataError(f"Pull request #{number} needs a mergedAt timestamp.")
        merged_at = parse_timestamp(merged_value, "mergedAt")
        if since is not None and merged_at <= since:
            continue

        number = item.get("number")
        if not isinstance(number, int) or isinstance(number, bool) or number <= 0:
            raise ReleaseMetadataError("Each included pull request needs a positive number.")
        title = item.get("title")
        if not isinstance(title, str):
            raise ReleaseMetadataError(f"Pull request #{number} needs a title.")

        bump = validate_release_labels(raw_labels, f"Pull request #{number}")
        if bump == "none":
            continue
        collected.append(
            PullRequest(
                number=number,
                title=normalize_title(title),
                url=_pr_url(item, number, repository),
                merged_at=merged_at,
                bump=bump,
            )
        )

    collected.sort(key=lambda pr: (pr.merged_at, pr.number))
    return tuple(collected)


def create_release_plan(
    current_version: str,
    items: Sequence[dict[str, Any]],
    since: datetime | None,
    repository: str | None = None,
) -> ReleasePlan:
    normalized_version = format_semver(parse_semver(current_version))
    pull_requests = collect_pull_requests(items, since, repository)
    if not pull_requests:
        return ReleasePlan(normalized_version, None, None, ())
    bump = max((pr.bump for pr in pull_requests), key=BUMP_RANK.__getitem__)
    return ReleasePlan(
        normalized_version,
        bump_version(normalized_version, bump),
        bump,
        pull_requests,
    )


def render_change_groups(plan: ReleasePlan, heading_level: int = 3) -> str:
    grouped = {
        bump: [pr for pr in plan.pull_requests if pr.bump == bump]
        for bump in ("major", "minor", "patch")
    }
    lines: list[str] = []
    for bump in ("major", "minor", "patch"):
        pull_requests = grouped[bump]
        if not pull_requests:
            continue
        if lines:
            lines.append("")
        lines.extend((f"{'#' * heading_level} {SECTION_FOR_BUMP[bump]}", ""))
        for pull_request in pull_requests:
            lines.append(
                f"- {pull_request.title} "
                f"([#{pull_request.number}]({pull_request.url}))"
            )
    return "\n".join(lines)


def render_release_section(plan: ReleasePlan, release_date: date) -> str:
    if not plan.next_version:
        raise ReleaseMetadataError("A release section requires at least one releasable change.")
    return (
        f"## [{plan.next_version}] - {release_date.isoformat()}\n\n"
        f"{render_change_groups(plan)}\n"
    )


def update_changelog_links(
    content: str,
    current_version: str,
    next_version: str,
    repository: str | None,
) -> str:
    reference_pattern = re.compile(
        r"^\[Unreleased]:\s+"
        r"(?P<base>https://github\.com/[^\s]+/compare/)"
        r"(?P<from>v?[0-9]+\.[0-9]+\.[0-9]+)\.\.\.HEAD\s*$",
        re.MULTILINE,
    )
    match = reference_pattern.search(content)
    if match:
        linked_version = format_semver(parse_semver(match.group("from")))
        if linked_version != current_version:
            raise ReleaseMetadataError(
                "The Unreleased changelog link does not start at the current version "
                f"({linked_version} != {current_version})."
            )
        base = match.group("base")
        replacement = (
            f"[Unreleased]: {base}{next_version}...HEAD\n"
            f"[{next_version}]: {base}{current_version}...{next_version}"
        )
        return content[: match.start()] + replacement + content[match.end() :]

    if repository:
        base = f"https://github.com/{repository}/compare/"
        references = (
            f"[Unreleased]: {base}{next_version}...HEAD\n"
            f"[{next_version}]: {base}{current_version}...{next_version}\n"
        )
        return f"{content.rstrip()}\n\n{references}"
    return content


def update_changelog(
    content: str,
    section: str,
    version: str,
    current_version: str,
    repository: str | None = None,
) -> str:
    headings = list(CHANGELOG_HEADING_PATTERN.finditer(content))
    unreleased = next((heading for heading in headings if heading.group(1) == "Unreleased"), None)
    if unreleased is None:
        raise ReleaseMetadataError("CHANGELOG.md must contain a ## [Unreleased] section.")
    if any(heading.group(1) == version for heading in headings):
        raise ReleaseMetadataError(f"CHANGELOG.md already contains version {version}.")

    following_heading = next((heading for heading in headings if heading.start() > unreleased.start()), None)
    if following_heading is not None:
        insertion = following_heading.start()
    else:
        reference = re.search(r"^\[[^]]+]:\s+\S+\s*$", content[unreleased.end() :], re.MULTILINE)
        insertion = unreleased.end() + reference.start() if reference else len(content)

    before = content[:insertion].rstrip()
    after = content[insertion:].lstrip()
    updated = f"{before}\n\n{section.rstrip()}\n"
    if after:
        updated += f"\n{after.rstrip()}\n"
    return update_changelog_links(updated, current_version, version, repository)


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        temporary_path.chmod(mode)
        temporary_path.replace(path)
    except BaseException:
        temporary_path.unlink(missing_ok=True)
        raise


def write_github_output(path: Path, plan: ReleasePlan) -> None:
    next_version = plan.next_version or ""
    included_pr_numbers = ",".join(str(number) for number in sorted(pr.number for pr in plan.pull_requests))
    with path.open("a", encoding="utf-8", newline="\n") as stream:
        stream.write(f"has_release={'true' if plan.next_version else 'false'}\n")
        stream.write(f"next_version={next_version}\n")
        stream.write(f"included_pr_numbers={included_pr_numbers}\n")


def render_summary(plan: ReleasePlan, release_date: date) -> str:
    if not plan.next_version:
        return "## Release preparation\n\nNo release-worthy changes were found.\n"
    return (
        f"## Release {plan.next_version}\n\n"
        f"Proposed **{plan.bump}** version update from {plan.current_version}.\n\n"
        f"Release date: {release_date.isoformat()}\n\n"
        f"{render_change_groups(plan)}\n"
    )


def load_json_argument(value: str) -> Any:
    if value.startswith("@"):
        try:
            return json.loads(Path(value[1:]).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise ReleaseMetadataError(f"Could not read labels from {value[1:]}: {error}.") from error
    try:
        return json.loads(value)
    except json.JSONDecodeError as error:
        raise ReleaseMetadataError(f"Labels JSON is invalid: {error}.") from error


def run_git(repository: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ReleaseMetadataError(f"Could not run git: {error}.") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
        raise ReleaseMetadataError(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout.strip()


def resolve_commit(repository: Path, reference: str, label: str) -> str:
    if not reference or any(character in reference for character in ("\x00", "\n", "\r")):
        raise ReleaseMetadataError(f"{label} must be a non-empty git ref or commit.")
    try:
        return run_git(
            repository,
            "rev-parse",
            "--verify",
            "--end-of-options",
            f"{reference}^{{commit}}",
        )
    except ReleaseMetadataError as error:
        raise ReleaseMetadataError(f"Could not resolve {label} {reference!r}: {error}") from error


def version_at_commit(repository: Path, commit: str) -> str:
    try:
        value = run_git(repository, "show", f"{commit}:VERSION")
    except ReleaseMetadataError as error:
        raise ReleaseMetadataError(f"Commit {commit} does not contain a readable VERSION file.") from error
    return format_semver(parse_semver(value))


def path_exists_at_commit(repository: Path, commit: str, path: str) -> bool:
    entries = run_git(repository, "ls-tree", "--name-only", commit, "--", path).splitlines()
    return path in entries


def starting_version_at_ref(repository: Path, commit: str, from_ref: str) -> tuple[str, bool]:
    if path_exists_at_commit(repository, commit, "VERSION"):
        return version_at_commit(repository, commit), False

    tag_match = SEMVER_PATTERN.fullmatch(from_ref)
    if tag_match is None:
        raise ReleaseMetadataError(
            f"Commit {commit} does not contain VERSION, and start ref {from_ref!r} "
            "is not a strict X.Y.Z version ref."
        )
    return format_semver(parse_semver(from_ref)), True


def is_ancestor(repository: Path, ancestor: str, descendant: str) -> bool:
    try:
        result = subprocess.run(
            ["git", "-C", str(repository), "merge-base", "--is-ancestor", ancestor, descendant],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise ReleaseMetadataError(f"Could not run git: {error}.") from error
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
    raise ReleaseMetadataError(f"Could not verify git ancestry: {detail}")


def find_version_transition(
    repository: Path,
    from_ref: str,
    head_ref: str,
    requested_version: str,
    expected_commit: str | None = None,
) -> str:
    """Find the single first-parent commit that changes VERSION to the target."""

    repository = repository.resolve()
    if not (repository / ".git").exists():
        raise ReleaseMetadataError(f"Not a git repository: {repository}.")

    target_version = format_semver(parse_semver(requested_version))
    from_commit = resolve_commit(repository, from_ref, "start ref")
    head_commit = resolve_commit(repository, head_ref, "head ref")
    if not is_ancestor(repository, from_commit, head_commit):
        raise ReleaseMetadataError(
            f"Start ref {from_ref!r} is not an ancestor of head ref {head_ref!r}."
        )

    first_parent_history = run_git(repository, "rev-list", "--first-parent", head_commit).splitlines()
    if from_commit not in first_parent_history:
        raise ReleaseMetadataError(
            f"Start ref {from_ref!r} is not on the first-parent history of {head_ref!r}."
        )

    starting_version, inferred_starting_version = starting_version_at_ref(
        repository, from_commit, from_ref
    )
    if starting_version == target_version:
        raise ReleaseMetadataError(
            f"Start ref {from_ref!r} already contains requested version {target_version}."
        )

    head_version = version_at_commit(repository, head_commit)
    if head_version != target_version:
        raise ReleaseMetadataError(
            f"VERSION at {head_ref!r} is {head_version}, not requested version {target_version}."
        )

    commits = run_git(
        repository,
        "rev-list",
        "--first-parent",
        "--reverse",
        f"{from_commit}..{head_commit}",
    ).splitlines()
    previous_version = starting_version
    version_file_has_appeared = not inferred_starting_version
    transitions: list[str] = []
    for commit in commits:
        if path_exists_at_commit(repository, commit, "VERSION"):
            commit_version = version_at_commit(repository, commit)
            version_file_has_appeared = True
        elif inferred_starting_version and not version_file_has_appeared:
            commit_version = previous_version
        else:
            raise ReleaseMetadataError(
                f"Commit {commit} does not contain a readable VERSION file."
            )
        if commit_version == target_version and previous_version != target_version:
            transitions.append(commit)
        previous_version = commit_version

    if len(transitions) != 1:
        raise ReleaseMetadataError(
            f"Expected exactly one first-parent transition to {target_version}; "
            f"found {len(transitions)}."
        )
    transition = transitions[0]

    if expected_commit:
        expected = resolve_commit(repository, expected_commit, "expected commit")
        if transition != expected:
            raise ReleaseMetadataError(
                f"VERSION changed to {target_version} at {transition}, not expected commit {expected}."
            )
    return transition


def validate_labels_command(arguments: argparse.Namespace) -> int:
    if arguments.labels_json is not None and arguments.labels:
        raise ReleaseMetadataError("Use positional labels or --labels-json, not both.")
    labels = (
        label_names(load_json_argument(arguments.labels_json))
        if arguments.labels_json is not None
        else arguments.labels
    )
    bump = validate_release_labels(labels)
    print(bump)
    return 0


def prepare_command(arguments: argparse.Namespace) -> int:
    version_file = Path(arguments.version_file)
    if arguments.current_version:
        current_version = arguments.current_version
    elif version_file.is_file():
        current_version = version_file.read_text(encoding="utf-8").strip()
    else:
        raise ReleaseMetadataError("Provide --current-version or an existing --version-file.")

    release_date = date.fromisoformat(arguments.release_date)
    plan = create_release_plan(
        current_version=current_version,
        items=_read_pr_list(Path(arguments.prs_json)),
        since=parse_timestamp(arguments.since, "since") if arguments.since else None,
        repository=arguments.repository,
    )

    if plan.next_version:
        changelog_path = Path(arguments.changelog)
        try:
            changelog = changelog_path.read_text(encoding="utf-8")
        except OSError as error:
            raise ReleaseMetadataError(f"Could not read {changelog_path}: {error}.") from error
        section = render_release_section(plan, release_date)
        atomic_write(
            changelog_path,
            update_changelog(
                changelog,
                section,
                plan.next_version,
                plan.current_version,
                arguments.repository,
            ),
        )
        atomic_write(version_file, f"{plan.next_version}\n")

    if arguments.summary:
        atomic_write(Path(arguments.summary), render_summary(plan, release_date))

    output_path = arguments.github_output or os.environ.get("GITHUB_OUTPUT")
    if output_path:
        write_github_output(Path(output_path), plan)

    if plan.next_version:
        print(plan.next_version)
    else:
        print("No release-worthy changes found.")
    return 0


def version_transition_command(arguments: argparse.Namespace) -> int:
    transition = find_version_transition(
        repository=Path.cwd(),
        from_ref=arguments.from_ref,
        head_ref=arguments.head,
        requested_version=arguments.version,
        expected_commit=arguments.expect_commit,
    )
    print(transition)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    labels_parser = subparsers.add_parser(
        "validate-labels",
        help="Require exactly one release:major, release:minor, release:patch, or release:none label.",
    )
    labels_parser.add_argument("labels", nargs="*", help="Pull-request label names.")
    labels_parser.add_argument(
        "--labels-json",
        help="A JSON label array, or @path to a JSON file. Objects with a name field are accepted.",
    )
    labels_parser.set_defaults(handler=validate_labels_command)

    prepare_parser = subparsers.add_parser(
        "prepare",
        help="Calculate the next version and update release metadata.",
    )
    prepare_parser.add_argument("--prs-json", required=True, help="Merged pull requests as a JSON array.")
    prepare_parser.add_argument(
        "--since",
        help="Optionally include only PRs merged after this ISO timestamp.",
    )
    prepare_parser.add_argument(
        "--current-version",
        help="Current SemVer. If omitted, the version file is read.",
    )
    prepare_parser.add_argument(
        "--release-date",
        required=True,
        help="Date for the changelog entry in YYYY-MM-DD form.",
    )
    prepare_parser.add_argument("--repository", help="GitHub owner/name used when a PR has no URL.")
    prepare_parser.add_argument("--changelog", default="CHANGELOG.md")
    prepare_parser.add_argument("--version-file", default="VERSION")
    prepare_parser.add_argument("--summary", help="Optional path for a release PR summary.")
    prepare_parser.add_argument("--github-output", help="Optional GitHub Actions output file.")
    prepare_parser.set_defaults(handler=prepare_command)

    transition_parser = subparsers.add_parser(
        "version-transition",
        help="Find the single first-parent commit where VERSION changed to a release version.",
    )
    transition_parser.add_argument(
        "--from-ref",
        required=True,
        help="Semantic release tag or ref that starts the history range.",
    )
    transition_parser.add_argument("--head", required=True, help="Head ref that ends the history range.")
    transition_parser.add_argument("--version", required=True, help="Expected version at head.")
    transition_parser.add_argument(
        "--expect-commit",
        help="Optional commit that must be the VERSION transition commit.",
    )
    transition_parser.set_defaults(handler=version_transition_command)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    arguments = parser.parse_args(argv)
    try:
        return arguments.handler(arguments)
    except (ReleaseMetadataError, ValueError) as error:
        parser.error(str(error))
    return 2


if __name__ == "__main__":
    sys.exit(main())
