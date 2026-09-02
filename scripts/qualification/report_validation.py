#!/usr/bin/env python3
"""Validate and bind one completed device report to its selected run plan."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

REPORT_FILENAME = "report.json"
PLAN_FILENAME = "validation-plan.json"
MARKER_FILENAME = "report-validation.json"
EVIDENCE_MANIFEST_FILENAME = "report-evidence-manifest.json"
FORMAT_VERSION = 3
EVIDENCE_MANIFEST_FORMAT_VERSION = 1
QUALIFICATION_AUTHORITY = "qualification-policy-v1"
REPORT_ONLY_AUTHORITY = "report-only-contract-v1"
VALID_AUTHORITIES = {QUALIFICATION_AUTHORITY, REPORT_ONLY_AUTHORITY}
VALID_SELECTION_SCOPES = {"full", "partial"}
# These files are derived from, or added after, the immutable qualification
# evidence. They never satisfy a row and therefore are deliberately outside the
# receipt's evidence-tree inventory.
POST_VALIDATION_ROOT_FILES = {
    "feature-checklist.html",
    "feature-checklist.json",
    "feature-checklist.md",
    "host-info.json",
}
VALIDATION_SNAPSHOT_PREFIX = ".report-validation-input."


class ReportValidationError(ValueError):
    pass


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def regular_file_bytes(path: Path, description: str) -> bytes:
    if path.is_symlink() or not path.is_file():
        raise ReportValidationError(f"{description} is missing or linked: {path}")
    try:
        return path.read_bytes()
    except OSError as error:
        raise ReportValidationError(f"{description} is unreadable: {error}") from error


def json_object(value: bytes, description: str) -> dict[str, Any]:
    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, child in pairs:
            if key in result:
                raise ReportValidationError(
                    f"{description} repeats JSON key {key!r}"
                )
            result[key] = child
        return result

    try:
        decoded = json.loads(value, object_pairs_hook=unique_object)
    except ReportValidationError:
        raise
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ReportValidationError(f"{description} is malformed: {error}") from error
    if not isinstance(decoded, dict):
        raise ReportValidationError(f"{description} is not a JSON object")
    return decoded


def parse_utc_timestamp(value: Any, description: str) -> datetime:
    if not isinstance(value, str):
        raise ReportValidationError(f"{description} is not a UTC timestamp")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise ReportValidationError(
            f"{description} must use canonical YYYY-MM-DDTHH:MM:SSZ form"
        ) from error
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ReportValidationError(
            f"{description} must use canonical YYYY-MM-DDTHH:MM:SSZ form"
        )
    return parsed


def _excluded_evidence_path(relative: Path) -> bool:
    if len(relative.parts) != 1:
        return False
    name = relative.name
    return (
        name in {MARKER_FILENAME, EVIDENCE_MANIFEST_FILENAME}
        or name in POST_VALIDATION_ROOT_FILES
        or name.startswith(VALIDATION_SNAPSHOT_PREFIX)
    )


def evidence_tree_manifest(run_dir: Path) -> dict[str, Any]:
    """Inventory every retained evidence-tree entry with no symlink escapes."""

    run_root = run_dir.resolve()
    if run_dir.is_symlink() or not run_root.is_dir():
        raise ReportValidationError(f"run directory is missing or linked: {run_dir}")
    entries: list[dict[str, Any]] = []
    try:
        paths = sorted(
            run_root.rglob("*"), key=lambda path: path.relative_to(run_root).as_posix()
        )
        for path in paths:
            relative = path.relative_to(run_root)
            if _excluded_evidence_path(relative):
                continue
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                raise ReportValidationError(
                    f"evidence tree contains a symbolic link: {relative.as_posix()}"
                )
            entry: dict[str, Any] = {
                "kind": "directory" if stat.S_ISDIR(metadata.st_mode) else "file",
                "mode": f"{stat.S_IMODE(metadata.st_mode):04o}",
                "path": relative.as_posix(),
            }
            if stat.S_ISREG(metadata.st_mode):
                raw = regular_file_bytes(path, f"evidence tree entry {relative}")
                entry["sha256"] = sha256_bytes(raw)
                entry["sizeBytes"] = len(raw)
            elif not stat.S_ISDIR(metadata.st_mode):
                raise ReportValidationError(
                    f"evidence tree contains an unsupported entry: {relative.as_posix()}"
                )
            entries.append(entry)
    except OSError as error:
        raise ReportValidationError(f"cannot inventory evidence tree: {error}") from error
    if not entries:
        raise ReportValidationError("evidence tree is empty")
    return {
        "algorithm": "sha256",
        "excludedPostValidationRootFiles": sorted(POST_VALIDATION_ROOT_FILES),
        "files": entries,
        "formatVersion": EVIDENCE_MANIFEST_FORMAT_VERSION,
    }


def string_list(value: Any, description: str, *, allow_empty: bool = False) -> list[str]:
    if (
        not isinstance(value, list)
        or (not value and not allow_empty)
        or any(not isinstance(item, str) or not item for item in value)
        or len(set(value)) != len(value)
    ):
        qualifier = "possibly empty " if allow_empty else ""
        raise ReportValidationError(
            f"{description} must be a {qualifier}unique string array"
        )
    return value


def validate_plan_report_contract(report: dict[str, Any], plan: dict[str, Any]) -> None:
    if plan.get("formatVersion") != 2:
        raise ReportValidationError("validation plan formatVersion is not 2")
    if plan.get("selectionScope") not in VALID_SELECTION_SCOPES:
        raise ReportValidationError("validation plan selectionScope is invalid")
    if not isinstance(plan.get("reportOnly"), bool):
        raise ReportValidationError("validation plan reportOnly is not boolean")
    if not isinstance(plan.get("qualificationEligibleEnvironment"), bool):
        raise ReportValidationError(
            "validation plan qualificationEligibleEnvironment is not boolean"
        )
    plan_started = parse_utc_timestamp(
        plan.get("startedAtUTC"), "validation plan startedAtUTC"
    )
    report_started = parse_utc_timestamp(
        report.get("startedAtUTC"), "device report startedAtUTC"
    )
    report_completed = parse_utc_timestamp(
        report.get("completedAtUTC"), "device report completedAtUTC"
    )
    wall_duration = report.get("wallDurationSeconds")
    if (
        isinstance(wall_duration, bool)
        or not isinstance(wall_duration, int)
        or wall_duration < 0
    ):
        raise ReportValidationError(
            "device report wallDurationSeconds must be a non-negative integer"
        )
    if report_started != plan_started:
        raise ReportValidationError(
            "device report startedAtUTC does not match the validation plan"
        )
    if report_completed < report_started:
        raise ReportValidationError("device report completed before it started")
    if int((report_completed - report_started).total_seconds()) != wall_duration:
        raise ReportValidationError(
            "device report wallDurationSeconds does not match its UTC interval"
        )

    requested = string_list(
        plan.get("requestedScenarioDrivers"),
        "validation plan requestedScenarioDrivers",
    )
    selected = string_list(
        plan.get("selectedScenarioDrivers"),
        "validation plan selectedScenarioDrivers",
    )
    if any(driver not in requested for driver in selected):
        raise ReportValidationError(
            "validation plan selected drivers are not a subset of requested drivers"
        )
    raw_skipped = plan.get("skippedScenarioDrivers")
    if not isinstance(raw_skipped, list) or any(
        not isinstance(row, dict)
        or not isinstance(row.get("scenario"), str)
        or not row.get("scenario")
        or not isinstance(row.get("reason"), str)
        or not row.get("reason")
        for row in raw_skipped
    ):
        raise ReportValidationError(
            "validation plan skippedScenarioDrivers is malformed"
        )
    skipped = [row["scenario"] for row in raw_skipped]
    selected_set = set(selected)
    expected_skipped = [driver for driver in requested if driver not in selected_set]
    if skipped != expected_skipped:
        raise ReportValidationError(
            "validation plan skipped drivers do not reconcile with its selection"
        )

    raw_scenarios = report.get("scenarios")
    if not isinstance(raw_scenarios, list) or not raw_scenarios:
        raise ReportValidationError("device report has no scenario rows")
    report_drivers: list[str] = []
    for index, row in enumerate(raw_scenarios):
        if not isinstance(row, dict):
            raise ReportValidationError(f"device report scenario {index} is not an object")
        driver = row.get("scenario")
        if not isinstance(driver, str) or not driver:
            raise ReportValidationError(f"device report scenario {index} has no id")
        report_drivers.append(driver)
    if len(set(report_drivers)) != len(report_drivers):
        raise ReportValidationError("device report repeats a scenario driver")
    if report_drivers != selected:
        raise ReportValidationError(
            "device report scenario drivers do not exactly match the selected validation plan"
        )

    for field in ("mode", "reportOnly", "qualificationEligibleEnvironment"):
        if report.get(field) != plan.get(field):
            raise ReportValidationError(
                f"device report {field} does not match the validation plan"
            )
    if plan["selectionScope"] == "full" and plan["reportOnly"]:
        raise ReportValidationError("a report-only validation plan cannot claim full scope")


def marker_payload_for_digests(
    report_sha256: str,
    plan_sha256: str,
    authority: str,
    *,
    evidence_manifest_sha256: str | None = None,
    evidence_entry_count: int | None = None,
) -> dict[str, Any]:
    if authority not in VALID_AUTHORITIES:
        raise ReportValidationError(
            f"unsupported report validation authority: {authority}"
        )
    payload = {
        "formatVersion": FORMAT_VERSION,
        "reportSHA256": report_sha256,
        "validationAuthority": authority,
        "validationPlanSHA256": plan_sha256,
        "validationResult": "passed",
    }
    if evidence_manifest_sha256 is not None:
        if (
            len(evidence_manifest_sha256) != 64
            or any(character not in "0123456789abcdef" for character in evidence_manifest_sha256)
            or isinstance(evidence_entry_count, bool)
            or not isinstance(evidence_entry_count, int)
            or evidence_entry_count <= 0
        ):
            raise ReportValidationError("evidence-tree manifest binding is invalid")
        payload.update(
            {
                "evidenceEntryCount": evidence_entry_count,
                "evidenceManifest": EVIDENCE_MANIFEST_FILENAME,
                "evidenceManifestSHA256": evidence_manifest_sha256,
            }
        )
    return payload


def marker_payload(
    report_bytes: bytes, plan_bytes: bytes, authority: str
) -> dict[str, Any]:
    report = json_object(report_bytes, "device report")
    plan = json_object(plan_bytes, "validation plan")
    validate_plan_report_contract(report, plan)
    expected_authority = (
        REPORT_ONLY_AUTHORITY
        if report.get("reportOnly") is True
        else QUALIFICATION_AUTHORITY
    )
    if authority != expected_authority:
        raise ReportValidationError(
            "validation authority does not match the report-only contract"
        )
    if authority == REPORT_ONLY_AUTHORITY:
        validate_report_only_contract(report)
    return marker_payload_for_digests(
        sha256_bytes(report_bytes), sha256_bytes(plan_bytes), authority
    )


def atomic_write_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, staged_name = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    staged = Path(staged_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.chmod(staged, 0o644)
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)


def write_marker_for_bytes(
    run_dir: Path,
    report_bytes: bytes,
    plan_bytes: bytes,
    authority: str,
) -> Path:
    """Write a receipt only while retained inputs equal the validated bytes."""

    run_root = run_dir.resolve()
    report_path = run_root / REPORT_FILENAME
    plan_path = run_root / PLAN_FILENAME
    marker_path = run_root / MARKER_FILENAME
    manifest_path = run_root / EVIDENCE_MANIFEST_FILENAME
    marker_path.unlink(missing_ok=True)
    manifest_path.unlink(missing_ok=True)
    marker_payload(report_bytes, plan_bytes, authority)
    if regular_file_bytes(report_path, "device report") != report_bytes:
        raise ReportValidationError("device report changed after validation")
    if regular_file_bytes(plan_path, "validation plan") != plan_bytes:
        raise ReportValidationError("validation plan changed after validation")
    manifest = evidence_tree_manifest(run_root)
    atomic_write_json(manifest_path, manifest)
    manifest_bytes = regular_file_bytes(manifest_path, "evidence-tree manifest")
    if evidence_tree_manifest(run_root) != manifest:
        raise ReportValidationError("evidence tree changed while writing its receipt")
    payload = marker_payload_for_digests(
        sha256_bytes(report_bytes),
        sha256_bytes(plan_bytes),
        authority,
        evidence_manifest_sha256=sha256_bytes(manifest_bytes),
        evidence_entry_count=len(manifest["files"]),
    )
    atomic_write_json(marker_path, payload)
    return marker_path


def validate_report_only_contract(report: dict[str, Any]) -> None:
    scenarios = report.get("scenarios")
    if not (
        report.get("reportOnly") is True
        and report.get("releaseGateSatisfied") is False
        and report.get("qualificationRows") == []
        and isinstance(scenarios, list)
        and len(scenarios) == 1
        and isinstance(scenarios[0], dict)
        and scenarios[0].get("scenario") == "cadence-semantics-probe"
        and scenarios[0].get("qualificationEvidence") == "report-only"
    ):
        raise ReportValidationError("cadence semantics report-only contract failed")


def validate_and_mark(
    run_dir: Path,
    *,
    matrix_path: Path | None,
    candidate_path: Path | None,
    stable_required: bool = False,
    report_only: bool = False,
) -> Path:
    """Validate an immutable same-directory snapshot, then bind its exact inputs."""

    run_root = run_dir.resolve()
    # A failed revalidation must never leave an older successful receipt behind.
    (run_root / MARKER_FILENAME).unlink(missing_ok=True)
    (run_root / EVIDENCE_MANIFEST_FILENAME).unlink(missing_ok=True)
    report_bytes = regular_file_bytes(run_root / REPORT_FILENAME, "device report")
    plan_bytes = regular_file_bytes(run_root / PLAN_FILENAME, "validation plan")
    report = json_object(report_bytes, "device report")
    plan = json_object(plan_bytes, "validation plan")
    validate_plan_report_contract(report, plan)

    authority = REPORT_ONLY_AUTHORITY if report_only else QUALIFICATION_AUTHORITY
    if report_only:
        validate_report_only_contract(report)
    elif matrix_path is None or candidate_path is None:
        raise ReportValidationError(
            "ordinary report validation requires matrix and candidate inputs"
        )

    descriptor, snapshot_name = tempfile.mkstemp(
        prefix=".report-validation-input.", suffix=".json", dir=run_root
    )
    snapshot = Path(snapshot_name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(report_bytes)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(snapshot, 0o444)
        if not report_only:
            # The same-directory snapshot preserves every relative retained-
            # artifact path while ensuring policy sees the captured report bytes.
            import qualification_policy as policy

            assert matrix_path is not None
            assert candidate_path is not None
            try:
                matrix = policy.load_json(matrix_path, "qualification matrix")
                candidate = policy.load_json(candidate_path, "candidate metadata")
                policy.validate_report(
                    snapshot,
                    matrix,
                    candidate=candidate,
                    stable_required=stable_required,
                )
            except policy.QualificationPolicyError as error:
                raise ReportValidationError(str(error)) from error
        if regular_file_bytes(snapshot, "validation snapshot") != report_bytes:
            raise ReportValidationError("device report validation snapshot changed")
        return write_marker_for_bytes(run_root, report_bytes, plan_bytes, authority)
    finally:
        if snapshot.exists():
            snapshot.chmod(0o600)
        snapshot.unlink(missing_ok=True)


def is_valid(
    run_dir: Path,
    report_bytes: bytes | None = None,
    plan_bytes: bytes | None = None,
) -> bool:
    run_root = run_dir.resolve()
    report_path = run_root / REPORT_FILENAME
    plan_path = run_root / PLAN_FILENAME
    marker_path = run_root / MARKER_FILENAME
    manifest_path = run_root / EVIDENCE_MANIFEST_FILENAME
    if marker_path.is_symlink() or not marker_path.is_file():
        return False
    try:
        retained_report = (
            report_bytes
            if report_bytes is not None
            else regular_file_bytes(report_path, "device report")
        )
        retained_plan = (
            plan_bytes
            if plan_bytes is not None
            else regular_file_bytes(plan_path, "validation plan")
        )
        marker = json_object(
            regular_file_bytes(marker_path, "validation receipt"),
            "validation receipt",
        )
        authority = marker.get("validationAuthority", "")
        marker_payload(retained_report, retained_plan, authority)
        manifest_bytes = regular_file_bytes(
            manifest_path, "evidence-tree manifest"
        )
        manifest = json_object(manifest_bytes, "evidence-tree manifest")
        expected_manifest = evidence_tree_manifest(run_root)
        if manifest != expected_manifest:
            return False
        expected = marker_payload_for_digests(
            sha256_bytes(retained_report),
            sha256_bytes(retained_plan),
            authority,
            evidence_manifest_sha256=sha256_bytes(manifest_bytes),
            evidence_entry_count=len(expected_manifest["files"]),
        )
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        ReportValidationError,
        AttributeError,
    ):
        return False
    return marker == expected


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    validate = subparsers.add_parser("validate-and-mark")
    validate.add_argument("--run-dir", type=Path, required=True)
    validate.add_argument("--matrix", type=Path)
    validate.add_argument("--candidate", type=Path)
    validate.add_argument("--stable-required", action="store_true")
    validate.add_argument("--report-only", action="store_true")
    verify = subparsers.add_parser("verify")
    verify.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()

    try:
        if args.command == "validate-and-mark":
            print(
                validate_and_mark(
                    args.run_dir,
                    matrix_path=args.matrix,
                    candidate_path=args.candidate,
                    stable_required=args.stable_required,
                    report_only=args.report_only,
                )
            )
        elif not is_valid(args.run_dir):
            raise ReportValidationError(
                "qualification report has no matching successful-validation marker"
            )
    except (OSError, ReportValidationError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
