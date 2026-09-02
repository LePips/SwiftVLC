#!/usr/bin/env python3
"""Bind an XCTest JSON attachment to an exact release candidate and device row."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy


class EvidenceError(ValueError):
    pass


HOST_IDENTITY_FIELDS = {
    "hardware",
    "testExecution",
    "hostErrorInventory",
    "qualificationProducer",
    "sourceRequestProof",
    "deviceObservedDurationSeconds",
    "hostAttemptDurationSeconds",
    "deviceIdentifier",
    "progressiveServerTranscripts",
    *policy.CORE_IDENTITY_FIELDS,
}


def find_attachment(
    directory: Path,
    expected_name: str,
    expected_test_identifiers: list[str],
) -> Path:
    try:
        exported = policy.exported_qualification_attachments(
            directory, {expected_name: expected_test_identifiers}
        )
    except (OSError, ValueError, policy.QualificationPolicyError) as error:
        raise EvidenceError(f"cannot validate attachment export: {error}") from error
    return exported[expected_name][0]


def bind_progressive_transcripts(
    directory: Path,
    attempts: list[dict],
    retained_root_base: Path,
) -> list[dict]:
    if not attempts:
        raise EvidenceError("progressive transcripts have no runner attempts")
    try:
        expected_relative_root = directory.resolve().relative_to(
            retained_root_base.resolve()
        )
        if (
            len(expected_relative_root.parts) != 2
            or expected_relative_root.parts[0]
            != "progressive-http-range-seek-server-transcripts"
            or re.fullmatch(r"[A-Za-z0-9._-]+", expected_relative_root.parts[1]) is None
            or not expected_relative_root.parts[1].endswith(
                "-progressive-http-range-seek"
            )
        ):
            raise EvidenceError(
                "progressive transcript root has an unexpected namespace"
            )
        source_prefix = expected_relative_root.parts[1]
        retained_directory = policy.safe_relative_directory(
            retained_root_base,
            expected_relative_root.as_posix(),
            "progressive server transcripts",
        )
        if directory.resolve() != retained_directory:
            raise EvidenceError(
                "progressive transcript root has an unexpected namespace"
            )
        policy.reject_tree_symlinks(
            retained_directory, "progressive server transcripts"
        )
        relative_root = retained_directory.relative_to(retained_root_base.resolve())
    except (OSError, ValueError, policy.QualificationPolicyError) as error:
        raise EvidenceError(f"unsafe progressive transcript root: {error}") from error
    if relative_root != expected_relative_root:
        raise EvidenceError("progressive transcript root has an unexpected namespace")
    expected_names = {f"attempt-{index}.json" for index in range(1, len(attempts) + 1)}
    try:
        entries = list(retained_directory.iterdir())
        actual = {path.name for path in entries}
    except OSError as error:
        raise EvidenceError(
            f"cannot enumerate progressive transcripts: {error}"
        ) from error
    if actual != expected_names or any(
        not path.is_file() or path.is_symlink() for path in entries
    ):
        raise EvidenceError(
            "progressive transcript inventory mismatch: "
            f"{sorted(actual)!r} != {sorted(expected_names)!r}"
        )
    bindings = []
    for source_attempt in range(1, len(attempts) + 1):
        path = retained_directory / f"attempt-{source_attempt}.json"
        try:
            transcript = policy.load_json(
                path, f"progressive transcript attempt {source_attempt}"
            )
        except policy.QualificationPolicyError as error:
            raise EvidenceError(str(error)) from error
        token = transcript.get("token")
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", token):
            raise EvidenceError(
                f"progressive transcript attempt {source_attempt} has no safe token"
            )
        if token != f"{source_prefix}-attempt{source_attempt}":
            raise EvidenceError(
                f"progressive transcript attempt {source_attempt} token is not ordinal-bound"
            )
        relative = relative_root / path.name
        bindings.append(
            {
                "sourceAttempt": source_attempt,
                "attemptToken": token,
                "relativePath": relative.as_posix(),
                "digestAlgorithm": "sha256",
                "digest": policy.sha256_file(path),
                "sizeBytes": path.stat().st_size,
                "eventCount": len(transcript.get("events", [])),
            }
        )
    return bindings


def materialize(
    attachments: Path,
    attachment_name: str,
    scenario: str,
    hardware: str,
    artifact_digest: str,
    source_digest: str,
    *,
    candidate_identity: dict | None = None,
    test_execution: dict | None = None,
    error_inventory: dict | None = None,
    retained_root_base: Path | None = None,
    matrix: dict | None = None,
    duration_seconds: int | float | None = None,
    runner_scenario: str | None = None,
    attempts: list[dict] | None = None,
    expected_test_identifiers: list[str] | None = None,
    device_identifier: str | None = None,
    progressive_transcripts: Path | None = None,
    adaptive_source_metrics: Path | None = None,
) -> dict:
    authorized_identifiers = expected_test_identifiers
    attachment_expectations: dict[str, list[str]] | None = None
    authority_matrix = matrix
    if authority_matrix is None:
        try:
            authority_matrix = policy.load_json(
                Path(__file__).resolve().with_name("matrix.json"),
                "canonical qualification matrix",
            )
        except (OSError, policy.QualificationPolicyError) as error:
            raise EvidenceError(str(error)) from error
    if authority_matrix is not None:
        try:
            _, output_contracts = policy.validate_runner_contracts(authority_matrix)
            contract, output = output_contracts[scenario]
            if (
                runner_scenario is not None and contract.get("id") != runner_scenario
            ) or output.get("attachmentName") != attachment_name:
                raise EvidenceError(
                    "attachment does not match the matrix-authorized producer"
                )
            matrix_identifiers = policy.normalize_catalog_identifiers(
                output["testIdentifiers"]
            )
            if authorized_identifiers is not None and (
                policy.normalize_catalog_identifiers(authorized_identifiers)
                != matrix_identifiers
            ):
                raise EvidenceError(
                    "attachment XCTest owners differ from matrix authority"
                )
            authorized_identifiers = matrix_identifiers
            attachment_expectations = policy.runner_attachment_expectations(
                contract, {scenario}
            )
        except (KeyError, policy.QualificationPolicyError) as error:
            raise EvidenceError(str(error)) from error
    if authorized_identifiers is None:
        raise EvidenceError("attachment has no authorized XCTest producer")
    if attachment_expectations is None:
        attachment_expectations = {attachment_name: authorized_identifiers}
    try:
        exported = policy.exported_qualification_attachments(
            attachments, attachment_expectations
        )
    except policy.QualificationPolicyError as error:
        raise EvidenceError(str(error)) from error
    attachment_path, payload, attachment_test_identifier = exported[attachment_name]
    if payload.get("scenario") != scenario:
        raise EvidenceError(
            f"attachment scenario is {payload.get('scenario')!r}, expected {scenario!r}"
        )
    forged = sorted(HOST_IDENTITY_FIELDS.intersection(payload))
    if forged:
        raise EvidenceError(
            "test attachment may not supply host identity fields: " + ", ".join(forged)
        )

    identity = candidate_identity or {
        "artifactDigest": artifact_digest,
        "releaseSourceDigest": source_digest,
    }
    observed_duration = payload.get("durationSeconds")
    duration_measurements: dict[str, int | float] = {}
    if scenario in policy.STABLE_MINIMUM_DURATION_SECONDS:
        if (
            isinstance(observed_duration, bool)
            or not isinstance(observed_duration, (int, float))
            or observed_duration <= 0
        ):
            raise EvidenceError(
                f"{scenario} attachment has no positive device-observed durationSeconds"
            )
        if (
            isinstance(duration_seconds, bool)
            or not isinstance(duration_seconds, (int, float))
            or duration_seconds <= 0
        ):
            raise EvidenceError(f"{scenario} has no positive host attempt duration")
        normalized_host_duration: int | float = duration_seconds
        if isinstance(duration_seconds, float) and duration_seconds.is_integer():
            normalized_host_duration = int(duration_seconds)
        duration_measurements = {
            "deviceObservedDurationSeconds": observed_duration,
            "hostAttemptDurationSeconds": normalized_host_duration,
        }
        try:
            policy.validate_endurance_duration_measurements(
                {
                    **payload,
                    **duration_measurements,
                },
                scenario,
                stable=False,
            )
        except policy.QualificationPolicyError as error:
            raise EvidenceError(str(error)) from error
        authoritative_duration = observed_duration
    else:
        authoritative_duration = (
            observed_duration if observed_duration is not None else duration_seconds
        )
    producer = None
    if runner_scenario is not None or attempts is not None:
        if (
            not isinstance(runner_scenario, str)
            or not policy.ID.fullmatch(runner_scenario)
            or not isinstance(attempts, list)
            or not attempts
        ):
            raise EvidenceError("qualification producer inputs are incomplete")
        final_attempt = attempts[-1]
        if (
            not isinstance(final_attempt, dict)
            or final_attempt.get("classification") != "passed"
            or final_attempt.get("testExecution") != test_execution
        ):
            raise EvidenceError(
                "qualification producer has no exact final passing attempt"
            )
        if retained_root_base is None:
            raise EvidenceError("qualification producer has no retained artifact root")
        try:
            retained_attachments = attachments.resolve().relative_to(
                retained_root_base.resolve()
            )
            retained_attachment = attachment_path.resolve().relative_to(
                retained_root_base.resolve()
            )
            manifest_path = policy.safe_relative_file(
                retained_root_base,
                (retained_attachments / "manifest.json").as_posix(),
                "retained attachment manifest",
            )
            policy.reject_tree_symlinks(attachments, "retained attachment export")
        except (OSError, ValueError, policy.QualificationPolicyError) as error:
            raise EvidenceError(
                f"unsafe retained attachment export: {error}"
            ) from error
        producer = {
            "runnerScenario": runner_scenario,
            "sourceAttempt": final_attempt.get("attempt"),
            "sourceXcresultArtifact": final_attempt.get("xcresultArtifact"),
            "sourceXcresultDigestAlgorithm": final_attempt.get(
                "xcresultDigestAlgorithm"
            ),
            "sourceXcresultDigest": final_attempt.get("xcresultDigest"),
            "sourceXcresultSizeBytes": final_attempt.get("xcresultSizeBytes"),
            "attachmentName": attachment_name,
            "attachmentTestIdentifier": attachment_test_identifier,
            "retainedAttachmentRoot": retained_attachments.as_posix(),
            "manifestRelativePath": (retained_attachments / "manifest.json").as_posix(),
            "manifestDigestAlgorithm": "sha256",
            "manifestDigest": policy.sha256_file(manifest_path),
            "manifestSizeBytes": manifest_path.stat().st_size,
            "attachmentRelativePath": retained_attachment.as_posix(),
            "attachmentDigestAlgorithm": "sha256",
            "attachmentDigest": policy.sha256_file(attachment_path),
            "attachmentSizeBytes": attachment_path.stat().st_size,
        }
    apple_audio_scenarios = {
        "audio-media-services-reset",
        "audio-session-ownership",
    }
    source_request_proof = None
    if scenario in apple_audio_scenarios:
        if (
            adaptive_source_metrics is None
            or retained_root_base is None
            or runner_scenario is None
            or producer is None
        ):
            raise EvidenceError(
                f"{scenario} has no host-retained source request metrics"
            )
        try:
            source_request_proof = policy.bind_apple_audio_source_request_proof(
                adaptive_source_metrics,
                retained_base=retained_root_base,
                scenario=scenario,
                runner_scenario=runner_scenario,
                source_attempt=producer["sourceAttempt"],
            )
        except policy.QualificationPolicyError as error:
            raise EvidenceError(str(error)) from error
    elif adaptive_source_metrics is not None:
        raise EvidenceError(
            "Apple audio source metrics were supplied for an unrelated scenario"
        )
    evidence = {
        **payload,
        **{
            field: identity[field]
            for field in policy.CORE_IDENTITY_FIELDS
            if field in identity
        },
        "hardware": hardware,
        **(
            {"deviceIdentifier": device_identifier}
            if device_identifier is not None
            else {}
        ),
        **({"testExecution": test_execution} if test_execution is not None else {}),
        **(
            {
                "hostErrorInventory": policy.validate_error_inventory(
                    error_inventory,
                    retained_base=retained_root_base,
                    require_retained=retained_root_base is not None,
                    expected_test_catalog=(
                        test_execution.get("expected")
                        if isinstance(test_execution, dict)
                        else None
                    ),
                )
            }
            if error_inventory is not None
            else {}
        ),
        **(
            {"durationSeconds": authoritative_duration}
            if authoritative_duration is not None
            else {}
        ),
        **duration_measurements,
        **({"qualificationProducer": producer} if producer is not None else {}),
        **(
            {"sourceRequestProof": source_request_proof}
            if source_request_proof is not None
            else {}
        ),
        **(
            {
                "progressiveServerTranscripts": bind_progressive_transcripts(
                    progressive_transcripts,
                    attempts or [],
                    retained_root_base,
                )
            }
            if progressive_transcripts is not None and retained_root_base is not None
            else {}
        ),
    }
    if scenario == "progressive-http-range-seek" and progressive_transcripts is None:
        raise EvidenceError(
            "progressive HTTP Range evidence has no retained server transcripts"
        )
    if (
        scenario != "progressive-http-range-seek"
        and progressive_transcripts is not None
    ):
        raise EvidenceError(
            "progressive server transcripts were supplied for an unrelated scenario"
        )
    if matrix is not None:
        try:
            scenarios, _ = policy.validate_matrix(matrix)
            policy.validate_evidence(
                evidence,
                scenarios[scenario],
                identity,
                hardware,
                stable=False,
                retained_base=retained_root_base,
                require_retained=retained_root_base is not None,
                require_host_artifacts=progressive_transcripts is not None,
                require_endurance_series=False,
            )
        except (KeyError, policy.QualificationPolicyError) as error:
            raise EvidenceError(str(error)) from error
    return evidence


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--attachments", type=Path, required=True)
    parser.add_argument("--attachment-name", required=True)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--hardware", required=True)
    parser.add_argument("--device-identifier", required=True)
    parser.add_argument("--artifact-digest", required=True)
    parser.add_argument("--source-digest", required=True)
    parser.add_argument("--candidate-metadata", type=Path, required=True)
    parser.add_argument("--test-execution", type=Path, required=True)
    parser.add_argument("--error-inventory", type=Path, required=True)
    parser.add_argument("--retained-root-base", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--duration-seconds", type=float, required=True)
    parser.add_argument("--runner-scenario", required=True)
    parser.add_argument("--attempts", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--progressive-transcripts", type=Path)
    parser.add_argument("--adaptive-source-metrics", type=Path)
    args = parser.parse_args()

    try:
        candidate_identity = policy.load_json(
            args.candidate_metadata, "candidate metadata"
        )
        policy.validate_candidate_identity(candidate_identity, strict=True)
        test_execution = policy.load_json(args.test_execution, "test execution")
        error_inventory = policy.load_json(args.error_inventory, "host error inventory")
        attempts = policy.load_json(
            args.attempts, "runner attempts", object_required=False
        )
        matrix = policy.load_json(args.matrix, "qualification matrix")
        evidence = materialize(
            args.attachments,
            args.attachment_name,
            args.scenario,
            args.hardware,
            args.artifact_digest,
            args.source_digest,
            candidate_identity=candidate_identity,
            test_execution=test_execution,
            error_inventory=error_inventory,
            retained_root_base=args.retained_root_base,
            matrix=matrix,
            duration_seconds=args.duration_seconds,
            runner_scenario=args.runner_scenario,
            attempts=attempts,
            device_identifier=args.device_identifier,
            progressive_transcripts=args.progressive_transcripts,
            adaptive_source_metrics=args.adaptive_source_metrics,
        )
    except (EvidenceError, policy.QualificationPolicyError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
