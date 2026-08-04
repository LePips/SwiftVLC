#!/usr/bin/env python3
"""Verify cached qualification media exactly matches its manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


class FixtureVerificationError(ValueError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(root: Path) -> dict:
    root = root.resolve()
    manifest_path = root / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise FixtureVerificationError(f"cannot read fixture manifest: {error}") from error

    if manifest.get("formatVersion") != 1 or not isinstance(manifest.get("files"), dict):
        raise FixtureVerificationError("unsupported or malformed fixture manifest")

    expected = set(manifest["files"])
    actual = {
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() and path != manifest_path
    }
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        raise FixtureVerificationError(
            f"fixture file set mismatch; missing={missing}, extra={extra}"
        )

    for relative, record in sorted(manifest["files"].items()):
        path = root / relative
        if path.is_symlink() or root not in path.resolve().parents:
            raise FixtureVerificationError(f"unsafe fixture path: {relative}")
        if not isinstance(record, dict):
            raise FixtureVerificationError(f"malformed manifest entry: {relative}")
        size = path.stat().st_size
        if record.get("bytes") != size:
            raise FixtureVerificationError(
                f"fixture size mismatch for {relative}: {size} != {record.get('bytes')}"
            )
        digest = sha256(path)
        if record.get("sha256") != digest:
            raise FixtureVerificationError(f"fixture checksum mismatch for {relative}")

    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    args = parser.parse_args()
    try:
        manifest = verify(args.root)
    except FixtureVerificationError as error:
        parser.error(str(error))
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
