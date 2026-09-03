#!/usr/bin/env python3
"""Assemble candidate-bound device reports into one qualification record."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy
import report_validation


class AssemblyError(ValueError):
    pass


SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
ROW_ID = re.compile(r"[a-z0-9][a-z0-9-]*")


def load_object(path: Path, description: str) -> dict:
    try:
        return policy.load_json(path, description)
    except policy.QualificationPolicyError as error:
        raise AssemblyError(str(error)) from error


def required_rows(matrix: dict) -> set[tuple[str, str]]:
    try:
        return policy.required_rows(matrix)
    except policy.QualificationPolicyError as error:
        raise AssemblyError(str(error)) from error


def safe_evidence_path(report_path: Path, relative: object) -> Path:
    if not isinstance(relative, str) or not relative:
        raise AssemblyError(f"report {report_path} row has no evidence path")
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise AssemblyError(
            f"report {report_path} has unsafe evidence path {relative!r}"
        )
    resolved = (report_path.parent / candidate).resolve()
    try:
        resolved.relative_to(report_path.parent.resolve())
    except ValueError as error:
        raise AssemblyError(
            f"report {report_path} evidence escapes its directory: {relative!r}"
        ) from error
    if not resolved.is_file():
        raise AssemblyError(f"report {report_path} evidence is missing: {relative}")
    return resolved


def safe_evidence_artifact_path(
    evidence_path: Path, relative: object, description: str, *, directory: bool
) -> tuple[Path, Path]:
    if not isinstance(relative, str) or not relative:
        raise AssemblyError(f"evidence {evidence_path} has no {description} path")
    candidate = Path(relative)
    if candidate.is_absolute() or ".." in candidate.parts:
        raise AssemblyError(
            f"evidence {evidence_path} has unsafe {description} path {relative!r}"
        )
    resolved = (evidence_path.parent / candidate).resolve()
    try:
        resolved.relative_to(evidence_path.parent.resolve())
    except ValueError as error:
        raise AssemblyError(
            f"evidence {evidence_path} {description} escapes its directory"
        ) from error
    valid = resolved.is_dir() if directory else resolved.is_file()
    if not valid:
        kind = "directory" if directory else "file"
        raise AssemblyError(
            f"evidence {evidence_path} {description} {kind} is missing: {relative}"
        )
    return resolved, candidate


def tree_digest(root: Path) -> str:
    digest = hashlib.sha256(b"SwiftVLC artifact tree digest v1\0")
    entries = sorted(
        root.rglob("*"), key=lambda path: path.relative_to(root).as_posix()
    )
    if not entries:
        raise AssemblyError(f"trace is empty: {root}")

    def update(value: bytes) -> None:
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)

    for path in entries:
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            kind, payload = b"directory", b""
        elif stat.S_ISREG(metadata.st_mode):
            content = hashlib.sha256()
            with path.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    content.update(chunk)
            kind, payload = b"file", content.digest()
        elif stat.S_ISLNK(metadata.st_mode):
            kind, payload = b"symlink", os.readlink(path).encode()
        else:
            raise AssemblyError(f"unsupported trace entry: {path}")
        update(kind)
        update(path.relative_to(root).as_posix().encode())
        update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        update(payload)
    return digest.hexdigest()


def retained_trace_artifacts(
    evidence_path: Path, trace: object, description: str
) -> list[tuple[Path, Path, bool]]:
    if not isinstance(trace, dict):
        raise AssemblyError(
            f"evidence {evidence_path} has malformed {description} provenance"
        )
    if trace.get("treeDigestAlgorithm") != "swiftvlc-tree-v1":
        raise AssemblyError(
            f"evidence {evidence_path} {description} has unsupported digest algorithm"
        )
    trace_source, trace_relative = safe_evidence_artifact_path(
        evidence_path,
        trace.get("runArtifact"),
        description,
        directory=True,
    )
    toc_source, toc_relative = safe_evidence_artifact_path(
        evidence_path,
        trace.get("tableOfContents"),
        f"{description} table of contents",
        directory=False,
    )
    summary_source, summary_relative = safe_evidence_artifact_path(
        evidence_path,
        trace.get("exportSummary"),
        f"{description} xctrace export summary",
        directory=False,
    )
    if tree_digest(trace_source) != trace.get("treeDigest"):
        raise AssemblyError(f"evidence {evidence_path} {description} digest mismatch")
    if (
        trace.get("exportSummaryDigestAlgorithm") != "sha256"
        or policy.sha256_file(summary_source) != trace.get("exportSummaryDigest")
        or summary_source.stat().st_size != trace.get("exportSummarySizeBytes")
    ):
        raise AssemblyError(
            f"evidence {evidence_path} {description} export summary mismatch"
        )
    return [
        (trace_source, trace_relative, True),
        (toc_source, toc_relative, False),
        (summary_source, summary_relative, False),
    ]


def retained_file_artifact(
    evidence_path: Path, record: object, description: str
) -> list[tuple[Path, Path, bool]]:
    if not isinstance(record, dict):
        raise AssemblyError(f"evidence {evidence_path} has malformed {description}")
    if record.get("digestAlgorithm") != "sha256":
        raise AssemblyError(
            f"evidence {evidence_path} {description} has unsupported digest algorithm"
        )
    source, relative = safe_evidence_artifact_path(
        evidence_path,
        record.get("runArtifact"),
        description,
        directory=False,
    )
    digest = hashlib.sha256(source.read_bytes()).hexdigest()
    if digest != record.get("sha256"):
        raise AssemblyError(f"evidence {evidence_path} {description} digest mismatch")
    return [(source, relative, False)]


def retained_progressive_transcript_artifacts(
    report_root: Path, evidence_path: Path, records: object
) -> list[tuple[Path, Path, bool]]:
    if not isinstance(records, list) or not records:
        raise AssemblyError(
            f"evidence {evidence_path} has no progressive server transcripts"
        )
    artifacts: list[tuple[Path, Path, bool]] = []
    for transcript_index, transcript in enumerate(records, 1):
        if not isinstance(transcript, dict):
            raise AssemblyError(
                f"evidence {evidence_path} transcript {transcript_index} is malformed"
            )
        try:
            transcript_source = policy.safe_relative_file(
                report_root,
                transcript.get("relativePath"),
                f"progressive transcript {transcript_index}",
            )
        except policy.QualificationPolicyError as error:
            raise AssemblyError(str(error)) from error
        if (
            transcript.get("digestAlgorithm") != "sha256"
            or policy.sha256_file(transcript_source) != transcript.get("digest")
            or transcript_source.stat().st_size != transcript.get("sizeBytes")
        ):
            raise AssemblyError(
                f"evidence {evidence_path} transcript {transcript_index} binding mismatch"
            )
        artifacts.append(
            (
                transcript_source,
                Path(transcript["relativePath"]),
                False,
            )
        )
    return artifacts


def assemble(
    version: str,
    candidate_path: Path,
    matrix_path: Path,
    report_paths: list[Path],
    output_path: Path,
    *,
    feature_manifest_path: Path | None = None,
    profiles_path: Path | None = None,
) -> dict:
    if not report_paths:
        raise AssemblyError("at least one device report is required")
    candidate = load_object(candidate_path, "candidate metadata")
    matrix = load_object(matrix_path, "qualification matrix")
    matrix_checksum = hashlib.sha256(matrix_path.read_bytes()).hexdigest()
    required = required_rows(matrix)

    try:
        policy.validate_candidate_identity(candidate, strict=True)
    except policy.QualificationPolicyError as error:
        raise AssemblyError(str(error)) from error
    identity = {field: candidate.get(field) for field in policy.CORE_IDENTITY_FIELDS}
    identity["formatVersion"] = 2
    for field, pattern in (
        ("artifactDigest", SHA256),
        ("sourceCommit", SHA1),
        ("releaseSourceDigest", SHA256),
    ):
        if not pattern.fullmatch(str(identity[field] or "")):
            raise AssemblyError(f"candidate metadata has no valid {field}")
    if candidate.get("version") != version:
        raise AssemblyError(
            f"candidate metadata version is {candidate.get('version')!r}, expected {version!r}"
        )
    for field, expected in (
        ("artifactDigestAlgorithm", "swiftvlc-tree-v1"),
        ("releaseSourceDigestAlgorithm", "swiftvlc-git-tree-v1"),
    ):
        if candidate.get(field) != expected:
            raise AssemblyError(
                f"candidate metadata {field} mismatch: "
                f"{candidate.get(field)!r} != {expected!r}"
            )
    if identity["qualificationMatrixChecksum"] != matrix_checksum:
        raise AssemblyError(
            "candidate qualificationMatrixChecksum does not match the selected matrix"
        )
    for path, field, description in (
        (feature_manifest_path, "featureManifestChecksum", "feature manifest"),
        (profiles_path, "qualificationProfilesChecksum", "qualification profiles"),
    ):
        if path is not None:
            actual = policy.sha256_file(path)
            if candidate.get(field) != actual:
                raise AssemblyError(
                    f"candidate {field} does not match the selected {description}"
                )

    rows: dict[tuple[str, str], tuple[dict, Path, list[tuple[Path, Path, bool]]]] = {}
    runner_summaries: dict[tuple[str, str], dict] = {}
    source_report_trees: list[tuple[Path, Path, dict]] = []
    for report_path in report_paths:
        try:
            canonical_report_path = policy.safe_relative_file(
                report_path.parent,
                report_path.name,
                f"source report {report_path}",
            )
        except policy.QualificationPolicyError as error:
            raise AssemblyError(str(error)) from error
        source_root = canonical_report_path.parent
        try:
            output_path.parent.resolve().relative_to(source_root.resolve())
        except ValueError:
            pass
        else:
            raise AssemblyError(
                f"output directory may not be inside source report tree {source_root}"
            )
        try:
            report_bytes = report_validation.regular_file_bytes(
                canonical_report_path, f"source report {report_path}"
            )
        except report_validation.ReportValidationError as error:
            raise AssemblyError(str(error)) from error
        if not report_validation.is_valid(
            source_root, report_bytes=report_bytes
        ):
            raise AssemblyError(
                f"report {report_path} has no matching successful-validation receipt"
            )
        if policy.is_release_matrix(matrix) and not (
            report_validation.is_release_scope_valid(
                source_root, report_bytes=report_bytes
            )
        ):
            raise AssemblyError(
                f"report {report_path} is not a canonical full-scope release run"
            )
        try:
            report = policy.validate_report(
                canonical_report_path,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        except policy.QualificationPolicyError as error:
            raise AssemblyError(str(error)) from error
        try:
            report_unchanged = (
                report_validation.regular_file_bytes(
                    canonical_report_path, f"source report {report_path}"
                )
                == report_bytes
            )
        except report_validation.ReportValidationError as error:
            raise AssemblyError(str(error)) from error
        if not report_unchanged or not report_validation.is_valid(
            source_root, report_bytes=report_bytes
        ):
            raise AssemblyError(
                f"report {report_path} changed while its receipt was consumed"
            )
        try:
            source_tree_digest = policy.tree_digest(source_root)
            source_tree_size = policy.tree_size_bytes(source_root)
        except policy.QualificationPolicyError as error:
            raise AssemblyError(str(error)) from error
        source_tree_relative = Path("reports") / version / source_tree_digest
        source_report_trees.append(
            (
                source_root,
                source_tree_relative,
                {
                    "path": source_tree_relative.as_posix(),
                    "reportRelativePath": canonical_report_path.name,
                    "reportDigestAlgorithm": "sha256",
                    "reportDigest": policy.sha256_file(canonical_report_path),
                    "reportSizeBytes": canonical_report_path.stat().st_size,
                    "treeDigestAlgorithm": "swiftvlc-tree-v1",
                    "treeDigest": source_tree_digest,
                    "treeSizeBytes": source_tree_size,
                },
            )
        )
        if report.get("result") != "pass":
            raise AssemblyError(f"report {report_path} did not pass")
        if report.get("qualificationEligibleEnvironment") is not True:
            raise AssemblyError(
                f"report {report_path} is not from a qualifying environment"
            )
        if report.get("mode") != "qualification":
            raise AssemblyError(f"report {report_path} is not in qualification mode")
        for field, expected in identity.items():
            if report.get(field) != expected:
                raise AssemblyError(
                    f"report {report_path} {field} mismatch: "
                    f"{report.get(field)!r} != {expected!r}"
                )

        report_rows = report.get("qualificationRows")
        if not isinstance(report_rows, list) or not report_rows:
            raise AssemblyError(f"report {report_path} has no qualification rows")
        report_hardware = {
            row.get("hardware") for row in report_rows if isinstance(row, dict)
        }
        if len(report_hardware) != 1 or not all(
            isinstance(item, str) for item in report_hardware
        ):
            raise AssemblyError(
                f"report {report_path} must describe exactly one hardware row"
            )
        hardware_id = next(iter(report_hardware))
        source_report_relative = (
            source_tree_relative / canonical_report_path.name
        ).as_posix()
        for runner_row in report.get("scenarios", []):
            if not isinstance(runner_row, dict):
                raise AssemblyError(
                    f"report {report_path} contains a non-object runner row"
                )
            runner_id = runner_row.get("scenario")
            if not isinstance(runner_id, str):
                raise AssemblyError(
                    f"report {report_path} contains a runner without an id"
                )
            runner_key = (runner_id, hardware_id)
            if runner_key in runner_summaries:
                raise AssemblyError(
                    f"duplicate runner scenario {runner_id} on {hardware_id}"
                )
            runner_summaries[runner_key] = policy.runner_record_summary(
                runner_row, hardware_id, source_report_relative
            )
        for row in report_rows:
            if not isinstance(row, dict):
                raise AssemblyError(f"report {report_path} contains a non-object row")
            scenario = row.get("scenario")
            hardware = row.get("hardware")
            if not isinstance(scenario, str) or not isinstance(hardware, str):
                raise AssemblyError(
                    f"report {report_path} contains a row without string ids"
                )
            key = (scenario, hardware)
            if key not in required:
                raise AssemblyError(
                    f"report {report_path} contains unknown row {key!r}"
                )
            if key in rows:
                raise AssemblyError(f"duplicate qualification row {key[0]} on {key[1]}")
            if row.get("result") != "pass":
                raise AssemblyError(f"row {key[0]} on {key[1]} did not pass")
            if row.get("osReleaseType") != "stable":
                raise AssemblyError(
                    f"row {key[0]} on {key[1]} is not from stable OS software"
                )
            evidence_path = safe_evidence_path(report_path, row.get("evidence"))
            evidence = load_object(evidence_path, "evidence")
            artifacts: list[tuple[Path, Path, bool]] = []
            provenance = evidence.get("allocationProvenance")
            trace = (
                provenance.get("instrumentsTrace")
                if isinstance(provenance, dict)
                else None
            )
            if trace is not None:
                artifacts.extend(
                    retained_trace_artifacts(evidence_path, trace, "allocation trace")
                )
            if key[0] in {
                "pip-render-performance-1080p60",
                "pip-render-performance-4k60",
            }:
                metrics = evidence.get("metrics")
                if not isinstance(metrics, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has no performance metrics"
                    )
                conversion = metrics.get("conversionCost")
                if not isinstance(conversion, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has no conversion-cost metric"
                    )
                for performance_trace, description in (
                    (metrics.get("gpu"), "Game Performance trace"),
                    (metrics.get("energy"), "Power Profiler trace"),
                    (conversion.get("hostTrace"), "Time Profiler trace"),
                ):
                    artifacts.extend(
                        retained_trace_artifacts(
                            evidence_path, performance_trace, description
                        )
                    )
            if key[0] == "native-subtitle-matrix":
                metrics = evidence.get("metrics")
                if not isinstance(metrics, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has no native subtitle metrics"
                    )
                cpu = metrics.get("cpu")
                color = metrics.get("colorHDRImpact")
                if not isinstance(cpu, dict) or not isinstance(color, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has malformed native subtitle metrics"
                    )
                for subtitle_trace, description in (
                    (cpu.get("hostTrace"), "Time Profiler trace"),
                    (metrics.get("gpu"), "Game Performance trace"),
                    (color.get("hostTrace"), "Metal System Trace"),
                ):
                    artifacts.extend(
                        retained_trace_artifacts(
                            evidence_path, subtitle_trace, description
                        )
                    )
            if key[0] in {"timebase-vod-soak", "timebase-live-soak"}:
                audio = evidence.get("audioPresentationSeries")
                if not isinstance(audio, dict):
                    raise AssemblyError(
                        f"evidence {evidence_path} has no timebase audio series"
                    )
                artifacts.extend(
                    retained_trace_artifacts(
                        evidence_path,
                        audio.get("hostTrace"),
                        "Audio System Trace",
                    )
                )
                artifacts.extend(
                    retained_file_artifact(
                        evidence_path,
                        evidence.get("rawCapture"),
                        "raw timebase capture",
                    )
                )
            if key[0] == "progressive-http-range-seek":
                artifacts.extend(
                    retained_progressive_transcript_artifacts(
                        report_path.parent,
                        evidence_path,
                        evidence.get("progressiveServerTranscripts"),
                    )
                )
            rows[key] = (row, evidence_path, artifacts)

    evidence_directory = output_path.parent / "evidence" / version
    staged_rows = []
    for key in sorted(rows):
        row, source, _ = rows[key]
        filename = f"{key[0]}-{key[1]}.json"
        relative = Path("evidence") / version / filename
        staged = dict(row, evidence=str(relative))
        staged_rows.append(staged)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_directory.mkdir(parents=True, exist_ok=True)
    for source_root, relative, binding in source_report_trees:
        destination = output_path.parent / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            try:
                identical = (
                    policy.tree_digest(destination) == binding["treeDigest"]
                    and policy.tree_size_bytes(destination) == binding["treeSizeBytes"]
                )
            except policy.QualificationPolicyError:
                identical = False
            if not identical:
                raise AssemblyError(
                    f"retained source report tree collision: {relative}"
                )
        else:
            shutil.copytree(source_root, destination, symlinks=True)
    for key, (_, source, artifacts) in sorted(rows.items()):
        destination = evidence_directory / f"{key[0]}-{key[1]}.json"
        with tempfile.NamedTemporaryFile(
            dir=evidence_directory, prefix=f".{destination.name}.", delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
        try:
            shutil.copyfile(source, temporary_path)
            os.replace(temporary_path, destination)
        finally:
            temporary_path.unlink(missing_ok=True)
        for artifact_source, artifact_relative, is_directory in artifacts:
            artifact_destination = evidence_directory / artifact_relative
            artifact_destination.parent.mkdir(parents=True, exist_ok=True)
            if artifact_destination.exists():
                identical = (
                    is_directory
                    and artifact_destination.is_dir()
                    and tree_digest(artifact_destination)
                    == tree_digest(artifact_source)
                ) or (
                    not is_directory
                    and artifact_destination.is_file()
                    and artifact_destination.read_bytes()
                    == artifact_source.read_bytes()
                )
                if not identical:
                    raise AssemblyError(
                        f"retained evidence artifact collision: {artifact_relative}"
                    )
                continue
            if is_directory:
                shutil.copytree(artifact_source, artifact_destination, symlinks=True)
            else:
                shutil.copyfile(artifact_source, artifact_destination)

    record = {
        **identity,
        "sourceReports": [
            binding
            for _, _, binding in sorted(
                source_report_trees, key=lambda item: item[1].as_posix()
            )
        ],
        "runnerScenarios": [runner_summaries[key] for key in sorted(runner_summaries)],
        "rows": staged_rows,
    }
    with tempfile.NamedTemporaryFile(
        mode="w",
        dir=output_path.parent,
        prefix=f".{output_path.name}.",
        delete=False,
    ) as temporary:
        temporary_path = Path(temporary.name)
        json.dump(record, temporary, indent=2, sort_keys=True)
        temporary.write("\n")
    try:
        os.replace(temporary_path, output_path)
    finally:
        temporary_path.unlink(missing_ok=True)
    try:
        policy.validate_record(
            output_path,
            matrix,
            expected_identity=candidate,
            strict_provenance=True,
            require_complete=False,
        )
    except policy.QualificationPolicyError as error:
        output_path.unlink(missing_ok=True)
        raise AssemblyError(str(error)) from error
    return record


def main() -> int:
    script_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--candidate-metadata", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--report", type=Path, action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--feature-manifest",
        type=Path,
        default=script_directory / "feature-manifest-v1.json",
    )
    parser.add_argument(
        "--profiles",
        type=Path,
        default=script_directory / "profiles-v1.json",
    )
    args = parser.parse_args()
    try:
        record = assemble(
            args.version,
            args.candidate_metadata,
            args.matrix,
            args.report,
            args.output,
            feature_manifest_path=args.feature_manifest,
            profiles_path=args.profiles,
        )
    except AssemblyError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    print(f"Assembled {len(record['rows'])} candidate-bound qualification row(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
