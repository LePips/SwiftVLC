#!/usr/bin/env python3
"""Reject host checkout paths embedded in a release XCFramework."""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path

CHUNK_SIZE = 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def contains_bytes(path: Path, needle: bytes) -> bool:
    overlap = b""
    carry = len(needle) - 1
    try:
        with path.open("rb") as source:
            while chunk := source.read(CHUNK_SIZE):
                payload = overlap + chunk
                if needle in payload:
                    return True
                overlap = payload[-carry:] if carry else b""
    except OSError as error:
        fail(f"cannot scan artifact file {path}: {error}")
    return False


def canonical_directory(
    raw_path: str | Path, description: str, *, require_canonical: bool = False
) -> Path:
    raw_text = os.fspath(raw_path)
    if not os.path.isabs(raw_text):
        fail(f"{description} must be an absolute path: {raw_text}")
    saved_directory = -1
    try:
        saved_directory = os.open(".", os.O_RDONLY)
        os.chdir(raw_text)
        # getcwd asks the filesystem for the physical spelling. Unlike
        # Path.resolve(), this also canonicalizes case and Unicode aliases on
        # the default case-insensitive Apple filesystems.
        resolved = Path(os.getcwd())
    except NotADirectoryError:
        fail(f"{description} is not a directory: {raw_text}")
    except OSError as error:
        fail(f"cannot resolve {description} {raw_text}: {error}")
    finally:
        if saved_directory >= 0:
            try:
                os.fchdir(saved_directory)
            finally:
                os.close(saved_directory)
    if require_canonical and raw_text != str(resolved):
        fail(f"{description} must use its canonical physical path: {resolved}")
    return resolved


def verify(xcframework: str | Path, forbidden_paths: list[str | Path]) -> None:
    artifact = canonical_directory(xcframework, "XCFramework")
    forbidden: list[tuple[Path, bytes]] = []
    seen: set[Path] = set()
    for raw_path in forbidden_paths:
        path = canonical_directory(
            raw_path, "forbidden build path", require_canonical=True
        )
        if path in seen:
            fail(f"duplicate forbidden build path: {path}")
        seen.add(path)
        forbidden.append((path, os.fsencode(path)))

    files: list[Path] = []
    symlinks: list[tuple[Path, bytes]] = []

    def raise_walk_error(error: OSError) -> None:
        raise error

    try:
        for raw_directory, directory_names, file_names in os.walk(
            artifact,
            topdown=True,
            followlinks=False,
            onerror=raise_walk_error,
        ):
            directory = Path(raw_directory)
            for name in sorted(directory_names + file_names):
                candidate = directory / name
                metadata = candidate.lstat()
                if stat.S_ISLNK(metadata.st_mode):
                    symlinks.append(
                        (candidate, os.fsencode(os.readlink(candidate)))
                    )
                elif stat.S_ISREG(metadata.st_mode):
                    files.append(candidate)
                elif not stat.S_ISDIR(metadata.st_mode):
                    fail(f"unsupported artifact entry type: {candidate}")
    except OSError as error:
        fail(f"cannot enumerate XCFramework {artifact}: {error}")
    if not files and not symlinks:
        fail(f"XCFramework contains no files or symlinks: {artifact}")

    leaks: list[tuple[Path, list[str]]] = []
    for forbidden_path, needle in forbidden:
        matches = [
            candidate.relative_to(artifact).as_posix()
            for candidate in sorted(files)
            if contains_bytes(candidate, needle)
        ]
        matches.extend(
            f"{candidate.relative_to(artifact).as_posix()} (symlink target)"
            for candidate, target in sorted(symlinks)
            if needle in target
        )
        if matches:
            leaks.append((forbidden_path, matches))

    if leaks:
        details = "; ".join(
            f"{path}: {', '.join(matches)}" for path, matches in leaks
        )
        fail(f"release artifact embeds forbidden build path(s): {details}")

    print(
        f"Verified {len(files)} file(s) and {len(symlinks)} symlink(s): "
        "no forbidden build paths embedded."
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reject absolute checkout/build paths in a release XCFramework."
    )
    parser.add_argument("--xcframework", required=True)
    parser.add_argument(
        "--forbidden-path",
        action="append",
        required=True,
        help="Absolute directory whose encoded path must not occur in artifact bytes.",
    )
    arguments = parser.parse_args()
    verify(arguments.xcframework, arguments.forbidden_path)


if __name__ == "__main__":
    main()
