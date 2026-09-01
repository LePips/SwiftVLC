#!/usr/bin/env python3
"""Compute a path-independent digest over an entire artifact directory."""

from __future__ import annotations

import argparse
import hashlib
import os
import stat
from pathlib import Path


def update_field(digest: "hashlib._Hash", value: bytes) -> None:
    digest.update(len(value).to_bytes(8, "big"))
    digest.update(value)


def tree_digest(root: Path) -> str:
    try:
        root = root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"Error: cannot resolve artifact directory {root}: {error}")
    if not root.is_dir():
        raise SystemExit(f"Error: artifact directory not found: {root}")

    digest = hashlib.sha256(b"SwiftVLC artifact tree digest v1\0")
    entries = sorted(
        root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()
    )
    if not entries:
        raise SystemExit(f"Error: artifact directory is empty: {root}")

    for path in entries:
        relative = path.relative_to(root).as_posix().encode()
        metadata = path.lstat()
        mode = stat.S_IMODE(metadata.st_mode).to_bytes(4, "big")

        if stat.S_ISDIR(metadata.st_mode):
            kind = b"directory"
            payload = b""
        elif stat.S_ISREG(metadata.st_mode):
            kind = b"file"
            content = hashlib.sha256()
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    content.update(chunk)
            payload = content.digest()
        elif stat.S_ISLNK(metadata.st_mode):
            kind = b"symlink"
            raw_target = os.readlink(path)
            try:
                resolved_target = path.resolve(strict=True)
                resolved_target.relative_to(root)
            except (OSError, RuntimeError, ValueError):
                raise SystemExit(
                    f"Error: artifact symlink target escapes the tree or is broken: {path}"
                )
            payload = os.fsencode(raw_target)
        else:
            raise SystemExit(f"Error: unsupported artifact entry type: {path}")

        update_field(digest, kind)
        update_field(digest, relative)
        update_field(digest, mode)
        update_field(digest, payload)

    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    arguments = parser.parse_args()
    print(tree_digest(arguments.artifact))


if __name__ == "__main__":
    main()
