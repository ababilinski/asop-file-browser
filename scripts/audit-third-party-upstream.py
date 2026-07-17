#!/usr/bin/env python3
"""Compare pinned managed tools with their official upstream release feeds."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import ssl
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "ThirdPartyLicenses/managed-tools.json"


def fetch(url: str, *, accept: str) -> bytes:
    headers = {
        "Accept": accept,
        "User-Agent": "Android-File-Browser-third-party-audit",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token and "api.github.com" in url:
        headers["Authorization"] = f"Bearer {token}"
        headers["X-GitHub-Api-Version"] = "2022-11-28"
    request = urllib.request.Request(url, headers=headers)
    verify_paths = ssl.get_default_verify_paths()
    context = None
    if not verify_paths.cafile and Path("/etc/ssl/cert.pem").is_file():
        context = ssl.create_default_context(cafile="/etc/ssl/cert.pem")
    with urllib.request.urlopen(request, timeout=45, context=context) as response:
        return response.read()


def local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def child_text(element: ET.Element, name: str, default: str = "0") -> str:
    for child in element:
        if local_name(child.tag) == name:
            return child.text or default
    return default


def platform_tools_versions(xml: bytes) -> tuple[str, str | None]:
    root = ET.fromstring(xml)
    packages: list[tuple[tuple[int, int, int], str]] = []
    for package in root.iter():
        if local_name(package.tag) != "remotePackage" or package.attrib.get("path") != "platform-tools":
            continue
        revision = next((child for child in package if local_name(child.tag) == "revision"), None)
        channel = next((child for child in package if local_name(child.tag) == "channelRef"), None)
        if revision is None:
            continue
        version = tuple(int(child_text(revision, part)) for part in ("major", "minor", "micro"))
        packages.append((version, channel.attrib.get("ref", "channel-0") if channel is not None else "channel-0"))

    stable = [version for version, channel in packages if channel == "channel-0"]
    previews = [version for version, channel in packages if channel != "channel-0"]
    if not stable:
        raise ValueError("Google's SDK repository did not list a stable Platform-Tools package")

    render = lambda value: ".".join(str(part) for part in value)
    return render(max(stable)), render(max(previews)) if previews else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--markdown", type=Path, help="Write the audit report to this file")
    arguments = parser.parse_args()

    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        upstream = manifest["upstream"]
        managed = manifest["managedToolchain"]
        scrcpy = managed["scrcpy"]
        adb = managed["adb"]

        latest_release = json.loads(
            fetch(upstream["scrcpyLatestReleaseAPI"], accept="application/vnd.github+json")
        )
        pinned_release_url = upstream["scrcpyReleaseByTagAPI"].format(tag=scrcpy["tag"])
        pinned_release = json.loads(fetch(pinned_release_url, accept="application/vnd.github+json"))
        pinned_license = fetch(
            upstream["scrcpyLicenseByTag"].format(tag=scrcpy["tag"]),
            accept="text/plain",
        )
        sdk_repository = fetch(upstream["androidSDKRepository"], accept="application/xml")
        stable_platform_tools, preview_platform_tools = platform_tools_versions(sdk_repository)
    except (OSError, KeyError, ValueError, ET.ParseError, json.JSONDecodeError, urllib.error.URLError) as error:
        print(f"Third-party upstream audit could not finish: {error}", file=sys.stderr)
        return 1

    changes: list[str] = []
    latest_tag = latest_release.get("tag_name", "unknown")
    if latest_tag != scrcpy["tag"]:
        changes.append(f"scrcpy latest release is {latest_tag}; the managed copy is {scrcpy['tag']}.")
    if stable_platform_tools != adb["version"]:
        changes.append(
            f"Stable Android SDK Platform-Tools is {stable_platform_tools}; the managed ADB copy is {adb['version']}."
        )

    upstream_license_sha = hashlib.sha256(pinned_license).hexdigest()
    if upstream_license_sha != scrcpy["upstreamLicenseSHA256"]:
        changes.append(
            "The scrcpy license file for "
            f"{scrcpy['tag']} has SHA-256 {upstream_license_sha}; expected {scrcpy['upstreamLicenseSHA256']}."
        )

    release_assets = {asset.get("name"): asset for asset in pinned_release.get("assets", [])}
    for archive in managed["archives"]:
        asset = release_assets.get(archive["assetName"])
        if asset is None:
            changes.append(f"The pinned scrcpy release no longer lists {archive['assetName']}.")
            continue
        upstream_digest = asset.get("digest")
        expected_digest = f"sha256:{archive['archiveSHA256']}"
        if not upstream_digest:
            changes.append(f"GitHub did not return a published digest for {archive['assetName']}.")
        elif upstream_digest != expected_digest:
            changes.append(
                f"The published digest for {archive['assetName']} is {upstream_digest}; expected {expected_digest}."
            )

    checked_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    preview_note = preview_platform_tools or "None listed"
    review_lines = [f"- {change}" for change in changes]
    if not review_lines:
        review_lines.append("- No managed-version or published-checksum changes were found.")
    report = "\n".join(
        [
            "# Third-party dependency audit",
            "",
            f"Checked {checked_at} against the official scrcpy release API and Google's Android SDK repository.",
            "",
            "| Dependency | Managed version | Official version |",
            "| --- | --- | --- |",
            f"| scrcpy | {scrcpy['tag']} | {latest_tag} |",
            f"| Android SDK Platform-Tools (stable) | {adb['version']} | {stable_platform_tools} |",
            f"| Android SDK Platform-Tools (preview, informational) | — | {preview_note} |",
            "",
            "## Review",
            "",
            *review_lines,
            "",
            "This check never changes downloads, checksums, license files, or notices automatically. "
            "Review upstream release notes and licensing before updating the managed-tools manifest.",
            "",
        ]
    )

    if arguments.markdown:
        arguments.markdown.write_text(report, encoding="utf-8")
    print(report)
    return 2 if changes else 0


if __name__ == "__main__":
    raise SystemExit(main())
