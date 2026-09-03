#!/usr/bin/env python3
"""Validate and identify immutable libVLC archive-member inventories."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
import struct
import sys

import validate_libvlc_feature_contract as feature_contract


DIGEST_DOMAIN = b"SwiftVLC libVLC archive-member inventory v1\0"
DIGEST_PATTERN = re.compile(r"[0-9a-f]{64}")
EXPECTED_ARCHITECTURES = {
    "ios-arm64.txt": frozenset({"arm64"}),
    "ios-arm64_x86_64-maccatalyst.txt": frozenset({"arm64", "x86_64"}),
    "ios-arm64_x86_64-simulator.txt": frozenset({"arm64", "x86_64"}),
    "macos-arm64_x86_64.txt": frozenset({"arm64", "x86_64"}),
    "tvos-arm64.txt": frozenset({"arm64"}),
    "tvos-arm64_x86_64-simulator.txt": frozenset({"arm64", "x86_64"}),
    "xros-arm64.txt": frozenset({"arm64"}),
    "xros-arm64_x86_64-simulator.txt": frozenset({"arm64", "x86_64"}),
}


class InventoryError(ValueError):
    """The inventory is not a canonical SwiftVLC manifest set."""


def _length_prefix(value: bytes) -> bytes:
    return struct.pack(">Q", len(value))


def _entries(directory: Path) -> dict[str, Path]:
    if directory.is_symlink() or not directory.is_dir():
        raise InventoryError(f"inventory is not a real directory: {directory}")

    entries = {entry.name: entry for entry in directory.iterdir()}
    expected = set(EXPECTED_ARCHITECTURES)
    actual = set(entries)
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    if missing:
        raise InventoryError(f"inventory is missing slices: {', '.join(missing)}")
    if unexpected:
        raise InventoryError(
            f"inventory contains unexpected entries: {', '.join(unexpected)}"
        )
    for name, entry in entries.items():
        if entry.is_symlink() or not entry.is_file():
            raise InventoryError(f"inventory entry is not a real file: {name}")
    return entries


def _canonical_bytes(path: Path, expected_architectures: frozenset[str]) -> bytes:
    try:
        payload = path.read_bytes()
        text = payload.decode("utf-8")
    except (OSError, UnicodeError) as error:
        raise InventoryError(f"cannot read {path}: {error}") from error

    if not payload:
        raise InventoryError(f"manifest is empty: {path}")
    if not payload.endswith(b"\n"):
        raise InventoryError(f"manifest has no final newline: {path}")
    if b"\r" in payload:
        raise InventoryError(f"manifest contains a carriage return: {path}")

    lines = text.splitlines()
    if lines != sorted(lines, key=lambda line: line.encode("utf-8")):
        raise InventoryError(f"manifest is not sorted bytewise: {path}")

    architectures: set[str] = set()
    for line_number, line in enumerate(lines, start=1):
        fields = line.split(" ")
        if len(fields) != 2 or not all(fields):
            raise InventoryError(
                f"{path}:{line_number}: expected canonical '<arch> <member>' row"
            )
        architectures.add(fields[0])

    if architectures != expected_architectures:
        expected = ", ".join(sorted(expected_architectures))
        actual = ", ".join(sorted(architectures)) or "none"
        raise InventoryError(
            f"{path.name} architectures are {actual}; expected {expected}"
        )

    contract_errors = feature_contract.validate_contract(path.stem, path)
    if contract_errors:
        raise InventoryError("; ".join(contract_errors))
    return payload


def inventory_payloads(directory: Path) -> dict[str, bytes]:
    entries = _entries(directory)
    payloads = {
        name: _canonical_bytes(entries[name], EXPECTED_ARCHITECTURES[name])
        for name in sorted(EXPECTED_ARCHITECTURES)
    }
    audio_counts: dict[tuple[str, str], int] = {}
    for name, path in entries.items():
        members_by_arch, parse_errors = feature_contract.parse_members(path)
        if parse_errors:
            raise InventoryError("; ".join(parse_errors))
        for architecture in EXPECTED_ARCHITECTURES[name]:
            audio_counts[(name.removesuffix(".txt"), architecture)] = (
                members_by_arch[architecture][
                    feature_contract.APPLE_AUDIO_SESSION_OBJECT
                ]
            )
    if any(audio_counts.values()):
        invalid = [
            f"{slice_name}/{architecture}={count}"
            for (slice_name, architecture), count in sorted(audio_counts.items())
            if count != 1
        ]
        if invalid:
            raise InventoryError(
                "Apple audio-session object must occur exactly once across all "
                f"13 slice architectures once present: {', '.join(invalid)}"
            )
    return payloads


def inventory_digest(directory: Path) -> str:
    digest = hashlib.sha256()
    digest.update(DIGEST_DOMAIN)
    for name, payload in inventory_payloads(directory).items():
        encoded_name = name.encode("utf-8")
        digest.update(_length_prefix(encoded_name))
        digest.update(encoded_name)
        digest.update(_length_prefix(payload))
        digest.update(payload)
    return digest.hexdigest()


def validate_inventory(directory: Path, expected_digest: str | None = None) -> str:
    actual_digest = inventory_digest(directory)
    if expected_digest is not None:
        if DIGEST_PATTERN.fullmatch(expected_digest) is None:
            raise InventoryError(f"invalid inventory digest: {expected_digest}")
        if actual_digest != expected_digest:
            raise InventoryError(
                f"inventory digest is {actual_digest}, expected {expected_digest}"
            )
    return actual_digest


def inventory_directories(root: Path) -> list[Path]:
    if root.is_symlink() or not root.is_dir():
        raise InventoryError(f"manifest-set root is not a real directory: {root}")
    entries = sorted(root.iterdir(), key=lambda entry: entry.name)
    if not entries:
        raise InventoryError(f"manifest-set root is empty: {root}")
    for entry in entries:
        if entry.is_symlink() or not entry.is_dir():
            raise InventoryError(f"unexpected manifest-set root entry: {entry.name}")
        if DIGEST_PATTERN.fullmatch(entry.name) is None:
            raise InventoryError(f"invalid manifest-set directory name: {entry.name}")
    return entries


def validate_root(root: Path) -> int:
    inventories = inventory_directories(root)
    for directory in inventories:
        validate_inventory(directory, directory.name)
    return len(inventories)


def select_inventory(root: Path, digest: str) -> Path:
    validate_root(root)
    if DIGEST_PATTERN.fullmatch(digest) is None:
        raise InventoryError(f"invalid inventory digest: {digest}")
    selected = root / digest
    if not selected.is_dir() or selected.is_symlink():
        raise InventoryError(
            f"unknown libVLC archive-member inventory: {digest}; "
            "regenerate and review it with check-libvlc-manifest.sh --write"
        )
    validate_inventory(selected, digest)
    return selected


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    digest_parser = subparsers.add_parser("digest")
    digest_parser.add_argument("--directory", required=True, type=Path)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--directory", required=True, type=Path)
    validate_parser.add_argument("--expected-digest")

    root_parser = subparsers.add_parser("validate-root")
    root_parser.add_argument("--root", required=True, type=Path)

    select_parser = subparsers.add_parser("select")
    select_parser.add_argument("--root", required=True, type=Path)
    select_parser.add_argument("--digest", required=True)

    arguments = parser.parse_args()
    try:
        if arguments.command == "digest":
            print(inventory_digest(arguments.directory))
        elif arguments.command == "validate":
            digest = validate_inventory(
                arguments.directory, arguments.expected_digest
            )
            print(f"libVLC manifest inventory valid: {digest}")
        elif arguments.command == "validate-root":
            count = validate_root(arguments.root)
            print(f"libVLC manifest-set root valid ({count} inventories)")
        else:
            print(select_inventory(arguments.root, arguments.digest))
    except InventoryError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
