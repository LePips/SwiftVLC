#!/usr/bin/env python3
"""Create and verify source identity bound to an exact signed candidate app."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
from pathlib import Path


SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")


class CandidateMetadataError(ValueError):
    pass


def command_output(arguments: list[str]) -> str:
    try:
        return subprocess.run(
            arguments,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        detail = error.stderr.strip() or error.stdout.strip() or str(error)
        raise CandidateMetadataError(detail) from error


def validate(
    metadata: dict,
    version: str,
    app_digest: str,
    artifact_digest: str,
) -> dict:
    required = {
        "formatVersion": 1,
        "version": version,
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": app_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": artifact_digest,
    }
    for key, expected in required.items():
        if metadata.get(key) != expected:
            raise CandidateMetadataError(
                f"candidate metadata {key} mismatch: {metadata.get(key)!r} != {expected!r}"
            )
    if not SHA1.fullmatch(str(metadata.get("sourceCommit", ""))):
        raise CandidateMetadataError("candidate metadata has no valid sourceCommit")
    if not SHA256.fullmatch(str(metadata.get("releaseSourceDigest", ""))):
        raise CandidateMetadataError("candidate metadata has no valid releaseSourceDigest")
    return metadata


def source_identity(source_root: Path, version: str) -> dict:
    source_digest_script = source_root / "scripts" / "release-source-digest.py"
    dirty = command_output(
        ["git", "-C", str(source_root), "status", "--porcelain", "--untracked-files=normal"]
    )
    if dirty:
        raise CandidateMetadataError(
            "candidate metadata requires a clean committed source checkout"
        )
    return {
        "sourceCommit": command_output(["git", "-C", str(source_root), "rev-parse", "HEAD"]),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": command_output(
            ["python3", str(source_digest_script), version]
        ),
    }


def create(app: Path, xcframework: Path, version: str, digest_script: Path) -> dict:
    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateMetadataError(f"cannot read candidate Info.plist: {error}") from error
    app_digest = command_output(["python3", str(digest_script), str(app)])
    artifact_digest = command_output(
        ["python3", str(digest_script), str(xcframework)]
    )
    embedded_artifact_digest = info.get("SwiftVLCArtifactDigest")
    if embedded_artifact_digest != artifact_digest:
        raise CandidateMetadataError(
            "candidate embedded artifact digest mismatch: "
            f"{embedded_artifact_digest!r} != {artifact_digest!r}"
        )
    metadata = {
        "formatVersion": 1,
        "version": version,
        "sourceCommit": info.get("SwiftVLCSourceCommit"),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": info.get("SwiftVLCReleaseSourceDigest"),
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": app_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": embedded_artifact_digest,
    }
    return validate(metadata, version, app_digest, artifact_digest)


def verify(
    metadata: dict,
    app: Path,
    xcframework: Path,
    version: str,
    digest_script: Path,
) -> dict:
    embedded = create(app, xcframework, version, digest_script)
    validated = validate(
        metadata,
        version,
        embedded["candidateAppDigest"],
        embedded["artifactDigest"],
    )
    for field in ("sourceCommit", "releaseSourceDigest"):
        if validated.get(field) != embedded[field]:
            raise CandidateMetadataError(
                f"candidate metadata {field} does not match the signed app: "
                f"{validated.get(field)!r} != {embedded[field]!r}"
            )
    return validated


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create")
    create_parser.add_argument("--candidate-app", type=Path, required=True)
    create_parser.add_argument("--xcframework", type=Path, required=True)
    create_parser.add_argument("--version", required=True)
    create_parser.add_argument("--digest-script", type=Path, required=True)
    create_parser.add_argument("--output", type=Path, required=True)

    source_parser = subparsers.add_parser("source")
    source_parser.add_argument("--source-root", type=Path, required=True)
    source_parser.add_argument("--version", required=True)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--candidate-app", type=Path, required=True)
    verify_parser.add_argument("--xcframework", type=Path, required=True)
    verify_parser.add_argument("--metadata", type=Path, required=True)
    verify_parser.add_argument("--version", required=True)
    verify_parser.add_argument("--digest-script", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "create":
            metadata = create(
                args.candidate_app,
                args.xcframework,
                args.version,
                args.digest_script,
            )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
        elif args.command == "source":
            metadata = source_identity(args.source_root.resolve(), args.version)
        else:
            metadata = verify(
                json.loads(args.metadata.read_text()),
                args.candidate_app,
                args.xcframework,
                args.version,
                args.digest_script,
            )
    except (CandidateMetadataError, OSError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(json.dumps(metadata, sort_keys=True))


if __name__ == "__main__":
    main()
