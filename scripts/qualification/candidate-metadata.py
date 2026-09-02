#!/usr/bin/env python3
"""Create and verify source identity bound to an exact signed candidate app."""

from __future__ import annotations

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
BUNDLE_IDENTIFIER = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+"
)


class CandidateMetadataError(ValueError):
    pass


def validated_bundle_identifier(value: object, description: str) -> str:
    if not isinstance(value, str) or BUNDLE_IDENTIFIER.fullmatch(value) is None:
        raise CandidateMetadataError(f"{description} has no valid bundle identifier")
    return value


def app_bundle_identifier(app: Path, description: str) -> str:
    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateMetadataError(
            f"cannot read {description} Info.plist: {error}"
        ) from error
    return validated_bundle_identifier(info.get("CFBundleIdentifier"), description)


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
        "version": version,
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": app_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": artifact_digest,
    }
    if metadata.get("formatVersion") not in {1, 2}:
        raise CandidateMetadataError("candidate metadata formatVersion must be 1 or 2")
    for key, expected in required.items():
        if metadata.get(key) != expected:
            raise CandidateMetadataError(
                f"candidate metadata {key} mismatch: {metadata.get(key)!r} != {expected!r}"
            )
    if not SHA1.fullmatch(str(metadata.get("sourceCommit", ""))):
        raise CandidateMetadataError("candidate metadata has no valid sourceCommit")
    if not SHA256.fullmatch(str(metadata.get("releaseSourceDigest", ""))):
        raise CandidateMetadataError(
            "candidate metadata has no valid releaseSourceDigest"
        )
    if metadata.get("formatVersion") == 2 or "candidateAppBundleIdentifier" in metadata:
        validated_bundle_identifier(
            metadata.get("candidateAppBundleIdentifier"),
            "candidate metadata",
        )
    if metadata.get("formatVersion") == 2:
        try:
            policy.validate_candidate_identity(metadata, strict=True)
        except policy.QualificationPolicyError as error:
            raise CandidateMetadataError(str(error)) from error
    return metadata


def source_identity(source_root: Path, version: str) -> dict:
    source_digest_script = source_root / "scripts" / "release-source-digest.py"
    dirty = command_output(
        [
            "git",
            "-C",
            str(source_root),
            "status",
            "--porcelain",
            "--untracked-files=normal",
        ]
    )
    if dirty:
        raise CandidateMetadataError(
            "candidate metadata requires a clean committed source checkout"
        )
    return {
        "sourceCommit": command_output(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"]
        ),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": command_output(
            [
                "python3",
                str(source_digest_script),
                version,
                "--root",
                str(source_root),
            ]
        ),
    }


def create(
    app: Path,
    xcframework: Path,
    version: str,
    digest_script: Path,
    bindings: dict | None = None,
) -> dict:
    try:
        with (app / "Info.plist").open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException) as error:
        raise CandidateMetadataError(
            f"cannot read candidate Info.plist: {error}"
        ) from error
    app_digest = command_output(["python3", str(digest_script), str(app)])
    artifact_digest = command_output(["python3", str(digest_script), str(xcframework)])
    embedded_artifact_digest = info.get("SwiftVLCArtifactDigest")
    if embedded_artifact_digest != artifact_digest:
        raise CandidateMetadataError(
            "candidate embedded artifact digest mismatch: "
            f"{embedded_artifact_digest!r} != {artifact_digest!r}"
        )
    metadata = {
        "formatVersion": 2 if bindings is not None else 1,
        "version": version,
        "candidateAppBundleIdentifier": validated_bundle_identifier(
            info.get("CFBundleIdentifier"), "candidate application"
        ),
        "sourceCommit": info.get("SwiftVLCSourceCommit"),
        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
        "releaseSourceDigest": info.get("SwiftVLCReleaseSourceDigest"),
        "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
        "candidateAppDigest": app_digest,
        "artifactDigestAlgorithm": "swiftvlc-tree-v1",
        "artifactDigest": embedded_artifact_digest,
        **(bindings or {}),
    }
    return validate(metadata, version, app_digest, artifact_digest)


def verify(
    metadata: dict,
    app: Path,
    xcframework: Path,
    version: str,
    digest_script: Path,
    bindings: dict | None = None,
) -> dict:
    embedded = create(app, xcframework, version, digest_script, bindings)
    validated = validate(
        metadata,
        version,
        embedded["candidateAppDigest"],
        embedded["artifactDigest"],
    )
    compared_fields = ["sourceCommit", "releaseSourceDigest"]
    if "candidateAppBundleIdentifier" in validated:
        compared_fields.append("candidateAppBundleIdentifier")
    for field in compared_fields:
        if validated.get(field) != embedded[field]:
            raise CandidateMetadataError(
                f"candidate metadata {field} does not match the signed app: "
                f"{validated.get(field)!r} != {embedded[field]!r}"
            )
    if bindings is not None and validated != embedded:
        differing = sorted(
            field
            for field in set(validated) | set(embedded)
            if validated.get(field) != embedded.get(field)
        )
        raise CandidateMetadataError(
            "candidate metadata does not match recomputed signed runner provenance: "
            + ", ".join(differing)
        )
    return validated


def qualification_bindings(
    *,
    test_runner: Path,
    test_bundle: Path,
    xctestrun: Path,
    test_catalog: Path,
    matrix: Path,
    feature_manifest: Path,
    profiles: Path,
    fixture_manifest: Path,
    digest_script: Path,
) -> dict:
    runner = test_runner.resolve()
    bundle = test_bundle.resolve()
    try:
        bundle_relative = bundle.relative_to(runner).as_posix()
    except ValueError as error:
        raise CandidateMetadataError(
            "embedded test bundle is not inside the signed UI-test runner"
        ) from error
    if not runner.is_dir() or not bundle.is_dir():
        raise CandidateMetadataError(
            "signed UI-test runner or embedded test bundle is missing"
        )
    if not xctestrun.is_file() or xctestrun.suffix != ".xctestrun":
        raise CandidateMetadataError(
            "selected base xctestrun is missing or does not end in .xctestrun"
        )
    try:
        catalog = policy.load_json(test_catalog, "XCTest catalog")
        canonical_catalog = policy.catalog_record(catalog.get("testIdentifiers", []))
    except policy.QualificationPolicyError as error:
        raise CandidateMetadataError(str(error)) from error
    if catalog != canonical_catalog:
        raise CandidateMetadataError("XCTest catalog is not canonical")
    try:
        for document, description in (
            (matrix, "qualification matrix"),
            (feature_manifest, "feature manifest"),
            (profiles, "qualification profiles"),
            (fixture_manifest, "fixture manifest"),
        ):
            policy.load_json(document, description)
        loaded_matrix = policy.load_json(matrix, "qualification matrix")
        policy.validate_release_matrix_contract(loaded_matrix)
    except policy.QualificationPolicyError as error:
        raise CandidateMetadataError(str(error)) from error
    return {
        "testRunnerBundleIdentifier": app_bundle_identifier(
            runner, "signed UI-test runner"
        ),
        "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
        "testRunnerDigest": command_output(
            ["python3", str(digest_script), str(runner)]
        ),
        "testBundleRelativePath": bundle_relative,
        "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
        "testBundleDigest": command_output(
            ["python3", str(digest_script), str(bundle)]
        ),
        "baseXCTestRunDigestAlgorithm": "sha256",
        "baseXCTestRunDigest": policy.sha256_file(xctestrun),
        "baseXCTestRunName": xctestrun.name,
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": canonical_catalog["digest"],
        "testCatalogCount": canonical_catalog["testCount"],
        "testCatalog": canonical_catalog["testIdentifiers"],
        "qualificationMatrixChecksum": policy.sha256_file(matrix),
        "featureManifestChecksum": policy.sha256_file(feature_manifest),
        "qualificationProfilesChecksum": policy.sha256_file(profiles),
        "fixtureManifestChecksum": policy.sha256_file(fixture_manifest),
        "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
        "qualificationPolicyDigest": policy.policy_digest(),
    }


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

    for operation_parser in (create_parser, verify_parser):
        operation_parser.add_argument("--test-runner", type=Path, required=True)
        operation_parser.add_argument("--test-bundle", type=Path, required=True)
        operation_parser.add_argument("--xctestrun", type=Path, required=True)
        operation_parser.add_argument("--test-catalog", type=Path, required=True)
        operation_parser.add_argument("--matrix", type=Path, required=True)
        operation_parser.add_argument("--feature-manifest", type=Path, required=True)
        operation_parser.add_argument("--profiles", type=Path, required=True)
        operation_parser.add_argument("--fixture-manifest", type=Path, required=True)

    args = parser.parse_args()
    try:
        if args.command == "create":
            bindings = qualification_bindings(
                test_runner=args.test_runner,
                test_bundle=args.test_bundle,
                xctestrun=args.xctestrun,
                test_catalog=args.test_catalog,
                matrix=args.matrix,
                feature_manifest=args.feature_manifest,
                profiles=args.profiles,
                fixture_manifest=args.fixture_manifest,
                digest_script=args.digest_script,
            )
            metadata = create(
                args.candidate_app,
                args.xcframework,
                args.version,
                args.digest_script,
                bindings,
            )
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n"
            )
        elif args.command == "source":
            metadata = source_identity(args.source_root.resolve(), args.version)
        else:
            bindings = qualification_bindings(
                test_runner=args.test_runner,
                test_bundle=args.test_bundle,
                xctestrun=args.xctestrun,
                test_catalog=args.test_catalog,
                matrix=args.matrix,
                feature_manifest=args.feature_manifest,
                profiles=args.profiles,
                fixture_manifest=args.fixture_manifest,
                digest_script=args.digest_script,
            )
            metadata = verify(
                policy.load_json(args.metadata, "candidate metadata"),
                args.candidate_app,
                args.xcframework,
                args.version,
                args.digest_script,
                bindings,
            )
    except (
        CandidateMetadataError,
        policy.QualificationPolicyError,
        OSError,
        json.JSONDecodeError,
    ) as error:
        parser.error(str(error))
    print(json.dumps(metadata, sort_keys=True))


if __name__ == "__main__":
    main()
