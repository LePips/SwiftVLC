#!/usr/bin/env python3
"""Hash release-significant tracked source for a qualification candidate."""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import stat
import subprocess
from pathlib import Path


ALGORITHM = b"SwiftVLC release source git tree v1\0"


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def update_field(digest: object, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def git_output(root: Path, *arguments: str) -> bytes:
    try:
        return subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=True,
            capture_output=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", b"").decode(errors="replace").strip()
        fail(detail or f"git {' '.join(arguments)} failed")


def excluded(path: str, version: str) -> bool:
    return path == f"scripts/qualification/{version}.json" or path.startswith(
        f"scripts/qualification/evidence/{version}/"
    )


def normalized_package_manifest(payload: bytes) -> bytes:
    try:
        text = payload.decode()
    except UnicodeDecodeError:
        fail("Package.swift is not UTF-8")
    release_pattern = re.compile(
        r'\.binaryTarget\(\s*name:\s*"libvlc",\s*'
        r'url:\s*"https://github\.com/harflabs/SwiftVLC/releases/download/'
        r'v[^"/]+/libvlc\.xcframework\.zip",\s*'
        r'checksum:\s*"[0-9a-f]{64}"\s*\)',
        re.DOTALL,
    )
    local_pattern = re.compile(
        r'\.binaryTarget\(\s*name:\s*"libvlc",\s*'
        r'path:\s*"Vendor/libvlc\.xcframework"\s*\)',
        re.DOTALL,
    )
    matches = len(release_pattern.findall(text)) + len(local_pattern.findall(text))
    if matches != 1:
        fail("Package.swift must contain exactly one known libvlc binary target")
    text = release_pattern.sub("<SwiftVLC release-managed binary target>", text)
    text = local_pattern.sub("<SwiftVLC release-managed binary target>", text)
    return text.encode()


def normalized_showcase_project(payload: bytes) -> bytes:
    try:
        text = payload.decode()
    except UnicodeDecodeError:
        fail("Showcase project is not UTF-8")
    remote_pattern = re.compile(
        r'/\* Begin XCRemoteSwiftPackageReference section \*/\n'
        r'\t\tBA000001 /\* XCRemoteSwiftPackageReference "SwiftVLC" \*/ = \{\n'
        r'\t\t\tisa = XCRemoteSwiftPackageReference;\n'
        r'\t\t\trepositoryURL = "https://github\.com/harflabs/SwiftVLC";\n'
        r'\t\t\trequirement = \{\n'
        r'\t\t\t\tkind = (?:upToNextMajorVersion|exactVersion);\n'
        r'\t\t\t\t(?:minimumVersion|version) = [0-9][0-9A-Za-z.\-]*;\n'
        r'\t\t\t\};\n'
        r'\t\t\};\n'
        r'/\* End XCRemoteSwiftPackageReference section \*/'
    )
    local_pattern = re.compile(
        r'/\* Begin XCLocalSwiftPackageReference section \*/\n'
        r'\t\tBA000001 /\* XCLocalSwiftPackageReference "\.\." \*/ = \{\n'
        r'\t\t\tisa = XCLocalSwiftPackageReference;\n'
        r'\t\t\trelativePath = "?\.\."?;\n'
        r'\t\t\};\n'
        r'/\* End XCLocalSwiftPackageReference section \*/'
    )
    matches = len(remote_pattern.findall(text)) + len(local_pattern.findall(text))
    if matches != 1:
        fail("Showcase project must contain exactly one known SwiftVLC package reference")
    marker = "<SwiftVLC release-managed package reference>"
    text = remote_pattern.sub(marker, text)
    text = local_pattern.sub(marker, text)
    text = text.replace(
        'BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */',
        "BA000001 /* SwiftVLC package reference */",
    )
    text = text.replace(
        'BA000001 /* XCLocalSwiftPackageReference ".." */',
        "BA000001 /* SwiftVLC package reference */",
    )
    return text.encode()


def normalized_payload(path: str, payload: bytes) -> bytes:
    if path == "Package.swift":
        return normalized_package_manifest(payload)
    if path == "Showcase/SwiftVLCShowcase.xcodeproj/project.pbxproj":
        return normalized_showcase_project(payload)
    return payload


def source_digest(root: Path, version: str) -> str:
    entries = git_output(root, "ls-tree", "-rz", "--full-tree", "HEAD")
    digest = hashlib.sha256(ALGORITHM)
    included = 0

    untracked = git_output(
        root, "ls-files", "--others", "--exclude-standard", "-z"
    ).split(b"\0")
    unsafe_untracked = sorted(
        raw_path.decode("utf-8")
        for raw_path in untracked
        if raw_path and not excluded(raw_path.decode("utf-8"), version)
    )
    if unsafe_untracked:
        fail("untracked release source: " + ", ".join(unsafe_untracked))

    for raw_entry in entries.split(b"\0"):
        if not raw_entry:
            continue
        try:
            metadata, raw_path = raw_entry.split(b"\t", 1)
            mode, kind, object_id = metadata.split(b" ", 2)
            path = raw_path.decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            fail("git returned an invalid tree entry")
        if excluded(path, version):
            continue
        candidate = root / path
        if kind == b"commit":
            actual_mode = mode
            payload = object_id
        elif mode == b"120000":
            if not candidate.is_symlink():
                fail(f"tracked symlink is missing or changed type: {path}")
            actual_mode = b"120000"
            payload = os.readlink(candidate).encode()
        else:
            if not candidate.is_file() or candidate.is_symlink():
                fail(f"tracked file is missing or changed type: {path}")
            actual_mode = (
                b"100755" if candidate.stat().st_mode & stat.S_IXUSR else b"100644"
            )
            payload = normalized_payload(path, candidate.read_bytes())
        for field in (actual_mode, kind, raw_path, payload):
            update_field(digest, field)
        included += 1

    if included == 0:
        fail("release source tree contains no tracked files")
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("version")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    arguments = parser.parse_args()
    if not arguments.version:
        fail("version must not be empty")
    print(source_digest(arguments.root.resolve(), arguments.version))


if __name__ == "__main__":
    main()
