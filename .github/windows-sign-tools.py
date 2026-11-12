#!/usr/bin/env python3
"""Helpers for the Windows Artifact Signing workflow.

Never print environment values or file contents that might hold secrets.
Subcommands exit 0 on success. `ready` exits 0 when every Azure signing
value is set, and 2 when any is missing (so a missing value is not a
generic failure).
"""
from __future__ import annotations

import hashlib
import json
import os
import sys
from pathlib import Path

REQUIRED_ENV = (
    "AZURE_CLIENT_ID",
    "AZURE_TENANT_ID",
    "AZURE_SUBSCRIPTION_ID",
    "AZURE_ARTIFACT_SIGNING_ACCOUNT",
    "AZURE_ARTIFACT_SIGNING_PROFILE",
    "AZURE_ARTIFACT_SIGNING_ENDPOINT",
)


def die(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def cmd_ready(_args: list[str]) -> None:
    missing = [name for name in REQUIRED_ENV if not os.environ.get(name)]
    if missing:
        print("Azure signing values absent; leaving the unsigned installer in place.")
        raise SystemExit(2)
    print("Azure signing values are present.")


def cmd_check_sha(_args: list[str]) -> None:
    if len(_args) != 1:
        die("usage: windows-sign-tools.py check-sha <file>")
    path = Path(_args[0])
    expected = path.with_name(path.name + ".sha256")
    if not path.is_file() or not expected.is_file():
        die(f"missing {path.name} or its .sha256")
    listed = expected.read_text().split()[0]
    actual = sha256_file(path)
    if listed.lower() != actual.lower():
        die(f"{path.name} does not match its .sha256")
    print(f"{path.name} matches its .sha256")


def cmd_write_sha(_args: list[str]) -> None:
    if len(_args) != 1:
        die("usage: windows-sign-tools.py write-sha <file>")
    path = Path(_args[0])
    digest = sha256_file(path)
    path.with_name(path.name + ".sha256").write_text(f"{digest}  {path.name}\n")
    print(f"wrote {path.name}.sha256")


def cmd_find_build(_args: list[str]) -> None:
    if len(_args) != 1:
        die("usage: windows-sign-tools.py find-build <extract-dir>")
    root = Path(_args[0])
    matches = sorted(root.rglob("build-manifest.json"))
    if not matches:
        die("no build-manifest.json in the extracted installer")
    if len(matches) > 1:
        die(f"expected one build-manifest.json, found {len(matches)}")
    print(matches[0].parent)


def cmd_update_manifest(_args: list[str]) -> None:
    if len(_args) != 1:
        die("usage: windows-sign-tools.py update-manifest <build-dir>")
    build = Path(_args[0])
    manifest_path = build / "build-manifest.json"
    if not manifest_path.is_file():
        die("build-manifest.json is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    files = manifest.get("files")
    if not isinstance(files, dict):
        die("build-manifest.json has no files object")
    updated = 0
    for name, entry in files.items():
        path = build / name
        if not path.is_file():
            die(f"manifest names a missing file: {name}")
        digest = sha256_file(path)
        size = path.stat().st_size
        if not isinstance(entry, dict):
            die(f"manifest entry for {name} is not an object")
        if entry.get("sha256", "").lower() != digest.lower() or entry.get("bytes") != size:
            entry["sha256"] = digest
            entry["bytes"] = size
            updated += 1
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(f"updated {updated} build-manifest.json hashes")


def cmd_check_latest(_args: list[str]) -> None:
    if len(_args) != 2:
        die("usage: windows-sign-tools.py check-latest <latest.json or -> <setup.exe.sha256>")
    latest_arg, sha_path = _args
    sha = Path(sha_path).read_text().split()[0]
    if latest_arg == "-":
        print("no latest.json on the draft; signed sha256 can be stamped later")
        return
    path = Path(latest_arg)
    if not path.is_file():
        die("latest.json path does not exist")
    note = json.loads(path.read_text(encoding="utf-8"))
    windows = note.get("windows")
    if not isinstance(windows, dict) or "sha256" not in windows:
        die("latest.json has no windows.sha256")
    if windows["sha256"].lower() != sha.lower():
        die(
            "latest.json windows.sha256 no longer matches the signed Setup.exe. "
            "Regenerate latest.json and latest.json.sig from the signed installer "
            "before running ship.yml. The signed Setup.exe and its .sha256 are already on the draft."
        )
    print("latest.json windows.sha256 matches the signed installer")


def cmd_version_from_tag(_args: list[str]) -> None:
    if len(_args) != 1:
        die("usage: windows-sign-tools.py version-from-tag <tag>")
    tag = _args[0]
    if tag.startswith("v") and len(tag) > 1 and tag[1].isdigit():
        tag = tag[1:]
    if not tag:
        die("empty version")
    print(tag)


def main() -> None:
    if len(sys.argv) < 2:
        die(
            "usage: windows-sign-tools.py "
            "ready|check-sha|write-sha|find-build|update-manifest|check-latest|version-from-tag ..."
        )
    commands = {
        "ready": cmd_ready,
        "check-sha": cmd_check_sha,
        "write-sha": cmd_write_sha,
        "find-build": cmd_find_build,
        "update-manifest": cmd_update_manifest,
        "check-latest": cmd_check_latest,
        "version-from-tag": cmd_version_from_tag,
    }
    name = sys.argv[1]
    if name not in commands:
        die(f"unknown command {name}")
    commands[name](sys.argv[2:])


if __name__ == "__main__":
    main()
