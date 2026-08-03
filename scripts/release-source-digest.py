#!/usr/bin/env python3
"""Hash release-significant tracked source for a qualification candidate."""

from __future__ import annotations

import argparse
import hashlib
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


def source_digest(root: Path, version: str) -> str:
    entries = git_output(root, "ls-tree", "-rz", "--full-tree", "HEAD")
    digest = hashlib.sha256(ALGORITHM)
    included = 0

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
        for field in (mode, kind, object_id, raw_path):
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
