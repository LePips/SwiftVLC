#!/usr/bin/env python3
"""Bind an XCTest JSON attachment to an exact release candidate and device row."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


class EvidenceError(ValueError):
    pass


HOST_IDENTITY_FIELDS = {"artifactDigest", "releaseSourceDigest", "hardware"}


def find_attachment(directory: Path, expected_name: str) -> Path:
    manifest_path = directory / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text())
    except (OSError, ValueError) as error:
        raise EvidenceError(f"cannot read attachment manifest: {error}") from error

    matches = []
    if not isinstance(manifest, list):
        raise EvidenceError("attachment manifest must be an array")
    for test in manifest:
        if not isinstance(test, dict):
            continue
        for attachment in test.get("attachments", []):
            if (
                isinstance(attachment, dict)
                and attachment.get("suggestedHumanReadableName") == expected_name
            ):
                exported = attachment.get("exportedFileName")
                if not isinstance(exported, str) or not exported:
                    raise EvidenceError(f"attachment {expected_name!r} has no exported filename")
                matches.append(directory / exported)

    if len(matches) != 1:
        raise EvidenceError(
            f"expected exactly one {expected_name!r} attachment, found {len(matches)}"
        )
    if not matches[0].is_file():
        raise EvidenceError(f"exported attachment is missing: {matches[0].name}")
    return matches[0]


def materialize(
    attachments: Path,
    attachment_name: str,
    scenario: str,
    hardware: str,
    artifact_digest: str,
    source_digest: str,
) -> dict:
    attachment_path = find_attachment(attachments, attachment_name)
    try:
        payload = json.loads(attachment_path.read_text())
    except (OSError, ValueError) as error:
        raise EvidenceError(f"cannot read evidence attachment: {error}") from error
    if not isinstance(payload, dict):
        raise EvidenceError("evidence attachment must be a JSON object")
    if payload.get("scenario") != scenario:
        raise EvidenceError(
            f"attachment scenario is {payload.get('scenario')!r}, expected {scenario!r}"
        )
    forged = sorted(HOST_IDENTITY_FIELDS.intersection(payload))
    if forged:
        raise EvidenceError(
            "test attachment may not supply host identity fields: " + ", ".join(forged)
        )

    return {
        **payload,
        "artifactDigest": artifact_digest,
        "releaseSourceDigest": source_digest,
        "hardware": hardware,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--attachments", type=Path, required=True)
    parser.add_argument("--attachment-name", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--hardware", required=True)
    parser.add_argument("--artifact-digest", required=True)
    parser.add_argument("--source-digest", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        evidence = materialize(
            args.attachments,
            args.attachment_name,
            args.scenario,
            args.hardware,
            args.artifact_digest,
            args.source_digest,
        )
    except EvidenceError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
