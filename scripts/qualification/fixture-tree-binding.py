#!/usr/bin/env python3
"""Bind and recheck the exact manifest-declared qualification fixture tree."""

from __future__ import annotations

import argparse
import hashlib
import json
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

AUTHORITY = "swiftvlc-qualification-fixture-tree-v1"


class FixtureTreeBindingError(ValueError):
    pass


def fixture_binding(root: Path) -> dict:
    root = root.absolute()
    if not root.is_dir() or root.is_symlink():
        raise FixtureTreeBindingError(f"fixture root must be a real directory: {root}")
    manifest_path = root / "manifest.json"
    try:
        manifest = policy.load_json(manifest_path, "fixture manifest")
    except policy.QualificationPolicyError as error:
        raise FixtureTreeBindingError(str(error)) from error
    declared = manifest.get("files")
    if manifest.get("formatVersion") != 1 or not isinstance(declared, dict):
        raise FixtureTreeBindingError("fixture manifest is malformed or unsupported")
    for path in root.rglob("*"):
        if path.is_symlink():
            raise FixtureTreeBindingError(f"fixture tree contains a symlink: {path}")
    actual = {
        path.relative_to(root).as_posix()
        for path in root.rglob("*")
        if path.is_file() and path != manifest_path
    }
    expected = set(declared)
    if actual != expected:
        raise FixtureTreeBindingError(
            "fixture file set mismatch; "
            f"missing={sorted(expected - actual)!r}, extra={sorted(actual - expected)!r}"
        )
    records: list[dict] = []
    for relative, manifest_record in sorted(declared.items()):
        relative_path = Path(relative)
        if (
            not isinstance(relative, str)
            or not relative
            or relative_path.is_absolute()
            or ".." in relative_path.parts
            or not isinstance(manifest_record, dict)
        ):
            raise FixtureTreeBindingError(f"unsafe fixture manifest entry: {relative!r}")
        path = root / relative_path
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode):
            raise FixtureTreeBindingError(f"fixture is not a regular file: {relative}")
        digest = policy.sha256_file(path)
        size = metadata.st_size
        if manifest_record.get("sha256") != digest or manifest_record.get("bytes") != size:
            raise FixtureTreeBindingError(
                f"fixture bytes no longer match manifest: {relative}"
            )
        records.append(
            {
                "relativePath": relative,
                "sizeBytes": size,
                "digestAlgorithm": "sha256",
                "digest": digest,
            }
        )
    set_digest = hashlib.sha256(
        b"SwiftVLC qualification fixture set v1\0"
        + policy.canonical_json_bytes(records)
    ).hexdigest()
    return {
        "formatVersion": 1,
        "authority": AUTHORITY,
        "manifestDigestAlgorithm": "sha256",
        "manifestDigest": policy.sha256_file(manifest_path),
        "fixtureSetDigestAlgorithm": "swiftvlc-qualification-fixture-set-v1",
        "fixtureSetDigest": set_digest,
        "fileCount": len(records),
        "files": records,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--root", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    try:
        current = fixture_binding(args.root)
        if args.command == "create":
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        else:
            expected = policy.load_json(args.receipt, "fixture-tree receipt")
            if current != expected:
                raise FixtureTreeBindingError(
                    "fixture tree changed after preflight verification"
                )
    except (FixtureTreeBindingError, OSError, policy.QualificationPolicyError) as error:
        parser.error(str(error))
    print(json.dumps(current, sort_keys=True))


if __name__ == "__main__":
    main()
