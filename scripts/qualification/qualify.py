#!/usr/bin/env python3
"""Run a named physical-device qualification profile and render its checklist."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import os
import re
import secrets
import stat
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy
import report_validation

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parents[1]
DEFAULT_PROFILES = SCRIPT_DIR / "profiles-v1.json"
DEFAULT_MATRIX = SCRIPT_DIR / "matrix.json"
DEFAULT_FEATURES = SCRIPT_DIR / "feature-manifest-v1.json"
DEFAULT_RUNNER = SCRIPT_DIR / "run-device-tests.sh"
DEFAULT_CHECKLIST = SCRIPT_DIR / "feature-checklist.py"
RELEASE_VERSION_POLICY = ROOT_DIR / "scripts" / "release-version-policy.py"
FULL_PROFILE_EXCLUDED_SCENARIOS = frozenset(
    policy.STABLE_MINIMUM_DURATION_SECONDS
)
RELEASE_MANDATORY_SCENARIOS = frozenset(
    {
        "analyzer",
        "ui-suite",
        "harness-regressions",
        *policy.STABLE_MINIMUM_DURATION_SECONDS,
    }
)
REQUIRED_SUPPORT_SCENARIOS = {
    "smoke": frozenset({"analyzer", "harness-regressions"}),
    "full": frozenset(
        {"analyzer", "ui-suite", "harness-regressions", "seek-frame-oracles"}
    ),
    "release": RELEASE_MANDATORY_SCENARIOS,
}
DEVELOPMENT_TEAM_PATTERN = re.compile(r"^[A-Z0-9]{10}$")
SOURCE_COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SOURCE_DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class ConfigurationError(ValueError):
    """A qualification profile cannot be executed safely."""


@dataclass(frozen=True)
class Profile:
    name: str
    summary: str
    expected_duration_minutes: int
    stable_environment_required: bool
    scenarios: tuple[str, ...]


@dataclass(frozen=True)
class Profiles:
    runner_scenarios: frozenset[str]
    iphone_current_only_scenarios: frozenset[str]
    profiles: dict[str, Profile]


def _source_authority_identity(version: str) -> dict[str, str]:
    """Resolve a clean committed source identity with the runner's authority."""

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT_DIR / "candidate-metadata.py"),
            "source",
            "--source-root",
            str(ROOT_DIR),
            "--version",
            version,
        ],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "source authority rejected the checkout"
        raise ConfigurationError(detail)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ConfigurationError("source authority returned malformed JSON") from error
    if (
        not isinstance(value, dict)
        or SOURCE_COMMIT_PATTERN.fullmatch(str(value.get("sourceCommit", "")))
        is None
        or value.get("releaseSourceDigestAlgorithm") != "swiftvlc-git-tree-v1"
        or SOURCE_DIGEST_PATTERN.fullmatch(
            str(value.get("releaseSourceDigest", ""))
        )
        is None
    ):
        raise ConfigurationError("source authority returned an invalid identity")
    return {
        "sourceCommit": value["sourceCommit"],
        "releaseSourceDigestAlgorithm": value["releaseSourceDigestAlgorithm"],
        "releaseSourceDigest": value["releaseSourceDigest"],
    }


def _assert_source_authority_unchanged(
    expected: dict[str, str], version: str
) -> None:
    if _source_authority_identity(version) != expected:
        raise ConfigurationError(
            "source authority identity changed during qualification"
        )


def _snapshot_trusted_postprocessor(
    session_dir: Path, source_identity: dict[str, str]
) -> dict[str, Any]:
    """Materialize trusted report tooling from the exact claimed Git commit."""

    destination_root = session_dir / "trusted-source"
    destination_root.mkdir(parents=True, exist_ok=False)
    source_commit = source_identity["sourceCommit"]

    def committed_bytes(arguments: list[str], description: str) -> bytes:
        process = subprocess.Popen(
            arguments,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        stdout, stderr = process.communicate()
        if process.returncode != 0:
            detail = stderr.decode("utf-8", errors="replace").strip()
            raise ConfigurationError(f"{description}: {detail or 'git failed'}")
        return stdout

    try:
        raw_tree = committed_bytes(
            [
                "git",
                "-C",
                str(ROOT_DIR),
                "ls-tree",
                "-r",
                "-z",
                source_commit,
                "--",
                "scripts/qualification",
                "scripts/release-source-digest.py",
                "scripts/release-version-policy.py",
            ],
            "cannot enumerate trusted files from the claimed source commit",
        )
    except OSError as error:
        raise ConfigurationError("cannot execute Git for trusted source") from error
    selected: list[tuple[str, str]] = []
    for raw_entry in raw_tree.split(b"\0"):
        if not raw_entry:
            continue
        try:
            raw_metadata, raw_path = raw_entry.split(b"\t", 1)
            mode, kind, _ = raw_metadata.decode("ascii").split(" ", 2)
            relative = raw_path.decode("utf-8")
        except (UnicodeError, ValueError) as error:
            raise ConfigurationError("claimed source tree is malformed") from error
        candidate = Path(relative)
        is_top_level_qualification_input = (
            candidate.parent == Path("scripts/qualification")
            and candidate.suffix in {".json", ".py", ".sh"}
        )
        is_release_helper = relative in {
            "scripts/release-source-digest.py",
            "scripts/release-version-policy.py",
        }
        if not (is_top_level_qualification_input or is_release_helper):
            continue
        if kind != "blob" or mode not in {"100644", "100755"}:
            raise ConfigurationError(
                f"trusted committed input has unsupported Git mode: {relative}"
            )
        selected.append((relative, mode))
    required = {
        "scripts/qualification/feature-checklist.py",
        "scripts/qualification/feature-manifest-v1.json",
        "scripts/qualification/matrix.json",
        "scripts/qualification/qualification_policy.py",
        "scripts/qualification/report_validation.py",
    }
    selected_paths = {relative for relative, _ in selected}
    if not required.issubset(selected_paths):
        raise ConfigurationError(
            "claimed source commit omits required trusted postprocessor inputs"
        )
    if len(selected_paths) != len(selected):
        raise ConfigurationError("claimed source tree repeats a trusted input")

    records: list[dict[str, Any]] = []
    for relative, source_mode in sorted(selected):
        try:
            content = committed_bytes(
                [
                    "git",
                    "-C",
                    str(ROOT_DIR),
                    "show",
                    f"{source_commit}:{relative}",
                ],
                f"cannot materialize trusted committed input: {relative}",
            )
        except OSError as error:
            raise ConfigurationError(
                f"cannot execute Git for trusted input: {relative}"
            ) from error
        destination = destination_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)
        os.chmod(destination, 0o444)
        records.append(
            {
                "path": relative,
                "sourceMode": source_mode,
                "snapshotMode": "0444",
                "digestAlgorithm": "sha256",
                "digest": hashlib.sha256(content).hexdigest(),
                "sizeBytes": len(content),
            }
        )
    manifest = {
        "formatVersion": 1,
        **source_identity,
        "files": records,
    }
    manifest_path = destination_root / "trusted-source-manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    os.chmod(manifest_path, 0o444)
    for directory in sorted(
        (path for path in destination_root.rglob("*") if path.is_dir()),
        key=lambda path: len(path.parts),
        reverse=True,
    ):
        os.chmod(directory, 0o555)
    os.chmod(destination_root, 0o555)
    manifest_digest = policy.sha256_file(manifest_path)
    return {
        "root": destination_root,
        "manifest": manifest_path,
        "checklist": destination_root / "scripts/qualification/feature-checklist.py",
        "features": destination_root / "scripts/qualification/feature-manifest-v1.json",
        "matrix": destination_root / "scripts/qualification/matrix.json",
        "profiles": destination_root / "scripts/qualification/profiles-v1.json",
        "manifestDigest": manifest_digest,
    }


def _validate_trusted_postprocessor(
    trusted: dict[str, Any], source_identity: dict[str, str]
) -> None:
    root = trusted["root"]
    manifest_path = trusted["manifest"]
    expected_manifest_digest = trusted["manifestDigest"]
    if (
        not isinstance(root, Path)
        or root.is_symlink()
        or not root.is_dir()
        or not isinstance(manifest_path, Path)
        or manifest_path.is_symlink()
        or not manifest_path.is_file()
        or policy.sha256_file(manifest_path) != expected_manifest_digest
    ):
        raise ConfigurationError("trusted postprocessor snapshot identity changed")
    try:
        manifest = json.loads(manifest_path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ConfigurationError("trusted postprocessor manifest is malformed") from error
    if (
        not isinstance(manifest, dict)
        or set(manifest)
        != {
            "formatVersion",
            "sourceCommit",
            "releaseSourceDigestAlgorithm",
            "releaseSourceDigest",
            "files",
        }
        or manifest.get("formatVersion") != 1
        or any(manifest.get(field) != value for field, value in source_identity.items())
        or not isinstance(manifest.get("files"), list)
        or not manifest["files"]
    ):
        raise ConfigurationError("trusted postprocessor manifest contract changed")
    expected_paths: set[str] = set()
    for record in manifest["files"]:
        if (
            not isinstance(record, dict)
            or set(record)
            != {
                "path",
                "sourceMode",
                "snapshotMode",
                "digestAlgorithm",
                "digest",
                "sizeBytes",
            }
            or not isinstance(record.get("path"), str)
            or record["path"] in expected_paths
            or record.get("sourceMode") not in {"100644", "100755"}
            or record.get("snapshotMode") != "0444"
            or record.get("digestAlgorithm") != "sha256"
            or SOURCE_DIGEST_PATTERN.fullmatch(str(record.get("digest", "")))
            is None
            or type(record.get("sizeBytes")) is not int
            or record["sizeBytes"] < 0
        ):
            raise ConfigurationError("trusted postprocessor file binding is malformed")
        expected_paths.add(record["path"])
        path = root / record["path"]
        try:
            path.relative_to(root)
            metadata = path.lstat()
        except (OSError, ValueError) as error:
            raise ConfigurationError(
                "trusted postprocessor file is missing or escapes its snapshot"
            ) from error
        if (
            path.is_symlink()
            or not stat.S_ISREG(metadata.st_mode)
            or stat.S_IMODE(metadata.st_mode) != 0o444
            or metadata.st_size != record["sizeBytes"]
            or policy.sha256_file(path) != record["digest"]
        ):
            raise ConfigurationError(
                f"trusted postprocessor file identity changed: {record['path']}"
            )
    actual_paths: set[str] = set()
    for path in root.rglob("*"):
        metadata = path.lstat()
        if stat.S_ISLNK(metadata.st_mode):
            raise ConfigurationError("trusted postprocessor snapshot contains a link")
        if stat.S_ISREG(metadata.st_mode):
            if path == manifest_path:
                continue
            actual_paths.add(path.relative_to(root).as_posix())
        elif not stat.S_ISDIR(metadata.st_mode):
            raise ConfigurationError(
                "trusted postprocessor snapshot contains an unsupported entry"
            )
    if actual_paths != expected_paths:
        raise ConfigurationError("trusted postprocessor snapshot file set changed")


def _read_json(path: Path) -> Any:
    try:
        return policy.load_json(path, "qualification profiles")
    except (OSError, policy.QualificationPolicyError) as error:
        raise ConfigurationError(f"cannot read JSON from {path}: {error}") from error


def validate_candidate_version(version: str, feature_manifest_path: Path) -> None:
    """Fail before device/build work unless VERSION belongs to this release series."""

    try:
        manifest = policy.load_json(feature_manifest_path, "feature manifest")
    except (OSError, policy.QualificationPolicyError) as error:
        raise ConfigurationError(
            f"cannot read feature manifest {feature_manifest_path}: {error}"
        ) from error
    release_prefix = manifest.get("releaseVersionPrefix")
    if not isinstance(release_prefix, str) or not release_prefix:
        raise ConfigurationError("feature manifest has no releaseVersionPrefix")
    try:
        spec = importlib.util.spec_from_file_location(
            "_swiftvlc_release_version_policy", RELEASE_VERSION_POLICY
        )
        if spec is None or spec.loader is None:
            raise OSError("cannot load the release version policy")
        version_policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(version_policy)
        version_policy.require_series(version, release_prefix)
    except (OSError, ValueError, AttributeError) as error:
        raise ConfigurationError(str(error)) from error


def _automated_feature_runner_scenarios(path: Path) -> frozenset[str]:
    try:
        manifest = policy.load_json(path, "feature manifest")
    except policy.QualificationPolicyError as error:
        raise ConfigurationError(str(error)) from error
    features = manifest.get("features")
    if not isinstance(features, list) or not features:
        raise ConfigurationError("feature manifest has no features")
    required_ids = {
        feature.get("id")
        for feature in features
        if isinstance(feature, dict) and feature.get("releaseRequirement") == "required"
    }
    if required_ids != policy.REQUIRED_FEATURE_IDS:
        missing = sorted(policy.REQUIRED_FEATURE_IDS - required_ids)
        extra = sorted(required_ids - policy.REQUIRED_FEATURE_IDS)
        raise ConfigurationError(
            "canonical required feature-ID obligations changed; "
            f"missing={missing}, extra={extra}"
        )
    runner_ids: set[str] = set()
    for feature in features:
        if not isinstance(feature, dict) or feature.get("execution") != "automated":
            continue
        values = feature.get("runnerScenarioIds")
        if (
            not isinstance(values, list)
            or not values
            or any(not isinstance(value, str) or not value for value in values)
        ):
            raise ConfigurationError(
                f"automated feature {feature.get('id')!r} has no runner lanes"
            )
        runner_ids.update(values)
    return frozenset(runner_ids)


def load_profiles(
    path: Path, feature_manifest_path: Path = DEFAULT_FEATURES
) -> Profiles:
    payload = _read_json(path)
    if not isinstance(payload, dict) or payload.get("formatVersion") != 1:
        raise ConfigurationError("profile manifest formatVersion must be 1")

    runner_values = payload.get("runnerScenarios")
    current_values = payload.get("iphoneCurrentOnlyScenarios")
    profile_values = payload.get("profiles")
    if not isinstance(runner_values, list) or not runner_values:
        raise ConfigurationError("runnerScenarios must be a non-empty array")
    if not all(isinstance(item, str) and item for item in runner_values):
        raise ConfigurationError("runnerScenarios must contain non-empty strings")
    if len(set(runner_values)) != len(runner_values):
        raise ConfigurationError("runnerScenarios contains duplicates")
    runner_scenarios = frozenset(runner_values)

    if not isinstance(current_values, list) or not all(
        isinstance(item, str) and item for item in current_values
    ):
        raise ConfigurationError(
            "iphoneCurrentOnlyScenarios must be an array of strings"
        )
    if len(set(current_values)) != len(current_values):
        raise ConfigurationError("iphoneCurrentOnlyScenarios contains duplicates")
    current_only = frozenset(current_values)
    unknown_current = current_only - runner_scenarios
    if unknown_current:
        raise ConfigurationError(
            "iphoneCurrentOnlyScenarios contains unknown scenarios: "
            + ", ".join(sorted(unknown_current))
        )

    if not isinstance(profile_values, dict) or not profile_values:
        raise ConfigurationError("profiles must be a non-empty object")
    profiles: dict[str, Profile] = {}
    for name, value in profile_values.items():
        if not isinstance(name, str) or not name or not isinstance(value, dict):
            raise ConfigurationError("every profile must be a named object")
        summary = value.get("summary")
        duration = value.get("expectedDurationMinutes")
        stable = value.get("stableEnvironmentRequired")
        scenarios = value.get("scenarios")
        if not isinstance(summary, str) or not summary:
            raise ConfigurationError(f"profile {name} has no summary")
        if isinstance(duration, bool) or not isinstance(duration, int) or duration <= 0:
            raise ConfigurationError(
                f"profile {name} expectedDurationMinutes must be a positive integer"
            )
        if not isinstance(stable, bool):
            raise ConfigurationError(
                f"profile {name} stableEnvironmentRequired must be boolean"
            )
        if not isinstance(scenarios, list) or not scenarios:
            raise ConfigurationError(f"profile {name} has no scenarios")
        if not all(isinstance(item, str) and item for item in scenarios):
            raise ConfigurationError(f"profile {name} scenarios must be strings")
        if len(set(scenarios)) != len(scenarios):
            raise ConfigurationError(f"profile {name} contains duplicate scenarios")
        unknown = set(scenarios) - runner_scenarios
        if unknown:
            raise ConfigurationError(
                f"profile {name} contains unknown scenarios: "
                + ", ".join(sorted(unknown))
            )
        profiles[name] = Profile(
            name=name,
            summary=summary,
            expected_duration_minutes=duration,
            stable_environment_required=stable,
            scenarios=tuple(scenarios),
        )

    for name, required_support in REQUIRED_SUPPORT_SCENARIOS.items():
        profile = profiles.get(name)
        if profile is None:
            raise ConfigurationError(f"required profile {name!r} is missing")
        missing_support = sorted(required_support - set(profile.scenarios))
        if missing_support:
            raise ConfigurationError(
                f"profile {name} omits required support scenarios: "
                + ", ".join(missing_support)
            )

    if "release" not in profiles or not profiles["release"].stable_environment_required:
        raise ConfigurationError("release profile must require a stable environment")
    actual_release_order = profiles["release"].scenarios
    actual_release = set(actual_release_order)
    if actual_release_order != policy.REQUIRED_RELEASE_RUNNER_SCENARIO_ORDER:
        raise ConfigurationError(
            "release profile differs from immutable runner coverage or order; "
            f"missing={sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS - actual_release)}, "
            f"extra={sorted(actual_release - policy.REQUIRED_RELEASE_RUNNER_SCENARIOS)}"
        )
    expected_full = (
        policy.REQUIRED_RELEASE_RUNNER_SCENARIOS
        - FULL_PROFILE_EXCLUDED_SCENARIOS
    )
    actual_full = set(profiles["full"].scenarios)
    if actual_full != expected_full:
        raise ConfigurationError(
            "full profile differs from immutable release-rehearsal coverage; "
            f"missing={sorted(expected_full - actual_full)}, "
            f"extra={sorted(actual_full - expected_full)}"
        )
    expected_full_order = tuple(
        scenario
        for scenario in profiles["release"].scenarios
        if scenario in expected_full
    )
    if profiles["full"].scenarios != expected_full_order:
        raise ConfigurationError(
            "full profile order must match the release profile after excluding "
            "immutable endurance lanes"
        )
    if current_only != policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS:
        raise ConfigurationError(
            "iphoneCurrentOnlyScenarios differs from immutable runner coverage"
        )
    automated_lanes = _automated_feature_runner_scenarios(feature_manifest_path)
    unknown_automated = sorted(automated_lanes - runner_scenarios)
    if unknown_automated:
        raise ConfigurationError(
            "automated feature lanes are absent from runnerScenarios: "
            + ", ".join(unknown_automated)
        )
    missing_release = sorted(automated_lanes - set(profiles["release"].scenarios))
    if missing_release:
        raise ConfigurationError(
            "release profile omits automated feature runner lanes: "
            + ", ".join(missing_release)
        )
    return Profiles(runner_scenarios, current_only, profiles)


def applicable_scenarios(
    profile: Profile,
    profiles: Profiles,
    device: dict[str, Any],
    exploratory_current_only: bool,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    matching_rows = device.get("matchingHardwareRows")
    if not isinstance(matching_rows, list):
        raise ConfigurationError("device record has no matchingHardwareRows array")
    if not matching_rows and not exploratory_current_only:
        raise ConfigurationError(
            "selected device does not match a qualification hardware row; "
            "a future iPhone requires --exploratory-current-only"
        )
    can_run_current = "iphone-current" in matching_rows or exploratory_current_only
    selected: list[str] = []
    inapplicable: list[str] = []
    for scenario in profile.scenarios:
        if scenario in profiles.iphone_current_only_scenarios and not can_run_current:
            inapplicable.append(scenario)
        else:
            selected.append(scenario)
    if not selected:
        raise ConfigurationError("no profile scenarios apply to the selected device")
    return tuple(selected), tuple(inapplicable)


def _device_command(device_selector: str | None, require_stable: bool) -> list[str]:
    command = [
        sys.executable,
        str(SCRIPT_DIR / "device-info.py"),
        "--matrix",
        str(DEFAULT_MATRIX),
    ]
    if device_selector:
        command.extend(["--device", device_selector])
    if require_stable:
        command.append("--require-stable")
    return command


def resolve_device(device_selector: str | None, require_stable: bool) -> dict[str, Any]:
    result = subprocess.run(
        _device_command(device_selector, require_stable),
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        if result.stderr:
            sys.stderr.write(result.stderr)
        raise ConfigurationError(
            "no connected, trusted, unlocked physical iOS device matched the request"
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ConfigurationError("device discovery returned invalid JSON") from error
    selected = payload.get("selected")
    if not isinstance(selected, dict):
        raise ConfigurationError("device discovery did not select a device")
    return selected


def build_runner_command(
    args: argparse.Namespace,
    profile: Profile,
    device_identifier: str | None,
    scenarios: Sequence[str],
    runner_output: Path,
    require_stable: bool,
) -> list[str]:
    command = [
        str(args.runner),
        "--version",
        args.version,
        "--output",
        str(runner_output),
    ]
    session_binding = getattr(args, "orchestrator_session_binding", None)
    if session_binding is not None:
        command.extend(["--orchestrator-session-binding", session_binding])
    orchestrator_started = getattr(args, "orchestrator_started_at_utc", None)
    if orchestrator_started is not None:
        command.extend(["--orchestrator-started-at-utc", orchestrator_started])
    if device_identifier:
        command.extend(["--device", device_identifier])
    if args.development_team:
        command.extend(["--development-team", args.development_team])
    for option, value in (
        ("--candidate-app", args.candidate_app),
        ("--candidate-metadata", args.candidate_metadata),
        ("--xctestrun", args.xctestrun),
        ("--derived-data", args.derived_data),
        ("--work-root", args.work_root),
        ("--fixtures", args.fixtures),
    ):
        if value is not None:
            command.extend([option, str(value)])
    if require_stable:
        command.append("--require-stable")
    if profile.name == "release":
        command.append("--full-suite-selection")
    if args.exploratory_current_only:
        command.append("--exploratory-current-only")
    if args.skip_build:
        command.append("--skip-build")
    for scenario in scenarios:
        command.extend(["--only", scenario])
    return command


def build_checklist_command(
    args: argparse.Namespace, report: Path, require_complete: bool
) -> list[str]:
    command = [
        sys.executable,
        str(args.checklist),
        "--manifest",
        str(args.features),
        "--matrix",
        str(args.matrix),
        "--input",
        str(report),
        "--output-dir",
        str(report.parent),
    ]
    if require_complete:
        command.append("--enforce-canonical-policy")
        command.append("--require-complete")
    return command


def _expected_checklist_outputs(
    args: argparse.Namespace,
    source: dict[str, Any],
    report: Path,
) -> tuple[dict[str, Any], str, str, str]:
    trusted_checklist = getattr(args, "trusted_checklist", DEFAULT_CHECKLIST)
    trusted_features = getattr(args, "trusted_features", DEFAULT_FEATURES)
    trusted_matrix = getattr(args, "trusted_matrix", DEFAULT_MATRIX)
    renderer_script = r"""
import importlib.util
import json
import sys
from pathlib import Path

checklist_path, feature_path, matrix_path, report_path = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location(
    "_swiftvlc_independent_checklist_renderer", checklist_path
)
if spec is None or spec.loader is None:
    raise SystemExit("cannot load trusted checklist renderer")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
report_bytes = renderer.report_validation.regular_file_bytes(
    report_path, "independent device report"
)
source = renderer.report_validation.json_object(
    report_bytes, "independent device report"
)
manifest = renderer.load_json(feature_path, "feature manifest")
matrix = renderer.load_json(matrix_path, "qualification matrix")
validated_manifest = renderer.validate_manifest(
    manifest,
    matrix,
    enforce_canonical_required_ids=(
        manifest.get("id") == "swiftvlc-release-features"
    ),
)
exploratory_durations = renderer.load_exploratory_evidence_durations(
    source,
    report_path,
    validated_manifest,
)
checklist = renderer.build_checklist(
    source,
    manifest,
    matrix,
    manifest_checksum=renderer.file_checksum(feature_path),
    matrix_checksum=renderer.file_checksum(matrix_path),
    exploratory_evidence_durations=exploratory_durations,
    release_scope_valid=renderer.report_validation.is_release_scope_valid(
        report_path.parent, report_bytes=report_bytes
    ),
)
json_output = json.dumps(checklist, indent=2, sort_keys=True) + "\n"
print(json.dumps({
    "checklist": checklist,
    "json": json_output,
    "markdown": renderer.render_markdown(checklist, manifest),
    "html": renderer.render_html(checklist, manifest),
}, sort_keys=True))
"""
    try:
        result = subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                renderer_script,
                str(trusted_checklist),
                str(trusted_features),
                str(trusted_matrix),
                str(report),
            ],
            text=True,
            capture_output=True,
        )
        if result.returncode != 0:
            raise OSError(
                result.stderr.strip() or "independent checklist renderer failed"
            )
        payload = json.loads(result.stdout)
        if not isinstance(payload, dict) or set(payload) != {
            "checklist",
            "json",
            "markdown",
            "html",
        }:
            raise ValueError("independent checklist renderer returned malformed output")
        checklist = payload["checklist"]
        if not isinstance(checklist, dict):
            raise ValueError("independent checklist is not an object")
        return (
            checklist,
            payload["json"],
            payload["markdown"],
            payload["html"],
        )
    except Exception as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        raise ConfigurationError(
            f"cannot independently render expected checklist outputs: {error}"
        ) from error


def validate_checklist_handoff(
    args: argparse.Namespace,
    profile: Profile,
    report: Path,
    checklist_exit_code: int,
    *,
    expected_device: dict[str, Any] | None = None,
    expected_scenarios: Sequence[str] | None = None,
    expected_session_binding: str | None = None,
    expected_orchestrator_started_at: str | None = None,
    expected_source_authority: dict[str, str] | None = None,
) -> dict[str, Any]:
    """Verify that the renderer's exit code has a complete, bound artifact set."""

    if checklist_exit_code not in {0, 1}:
        raise ConfigurationError(
            f"checklist process returned unsupported exit {checklist_exit_code}"
        )
    expected_paths = {
        "json": report.parent / "feature-checklist.json",
        "markdown": report.parent / "feature-checklist.md",
        "html": report.parent / "feature-checklist.html",
    }
    try:
        report_bytes = report_validation.regular_file_bytes(
            report, "device report handoff"
        )
        if (
            report.name != report_validation.REPORT_FILENAME
            or not report_validation.is_valid(
                report.parent, report_bytes=report_bytes
            )
        ):
            raise ConfigurationError(
                "device report handoff has no matching successful-validation receipt"
            )
        source = report_validation.json_object(
            report_bytes, "device report handoff"
        )
        rendered: dict[str, str] = {}
        for description, path in expected_paths.items():
            if path.is_symlink() or not path.is_file() or path.stat().st_size == 0:
                raise ConfigurationError(
                    "checklist output is missing, empty, or not a regular file: "
                    f"{path}"
                )
            rendered[description] = path.read_text()
        checklist = report_validation.json_object(
            rendered["json"].encode(), "feature checklist handoff"
        )
    except ConfigurationError:
        raise
    except (
        OSError,
        UnicodeError,
        report_validation.ReportValidationError,
    ) as error:
        raise ConfigurationError(
            f"cannot validate checklist handoff: {error}"
        ) from error
    if source.get("version") != args.version:
        raise ConfigurationError(
            "device report handoff version differs from the requested candidate"
        )
    if expected_source_authority is not None:
        for field in ("sourceCommit", "releaseSourceDigestAlgorithm", "releaseSourceDigest"):
            if source.get(field) != expected_source_authority.get(field):
                raise ConfigurationError(
                    f"device report handoff {field} differs from the session source authority"
                )
    if (
        expected_session_binding is not None
        and source.get("orchestratorSessionBinding") != expected_session_binding
    ):
        raise ConfigurationError(
            "device report handoff differs from the current orchestrator session"
        )
    if (
        expected_orchestrator_started_at is not None
        and source.get("orchestratorStartedAtUTC")
        != expected_orchestrator_started_at
    ):
        raise ConfigurationError(
            "device report handoff differs from the orchestrator start time"
        )
    if expected_device is not None:
        report_device = source.get("device")
        if not isinstance(report_device, dict):
            raise ConfigurationError("device report handoff has no device object")
        for field in (
            "id",
            "udid",
            "ecidHex",
            "deviceFamily",
            "productType",
            "osVersion",
            "osBuild",
            "osReleaseType",
            "matchingHardwareRows",
            "qualificationEligible",
        ):
            if report_device.get(field) != expected_device.get(field):
                raise ConfigurationError(
                    f"device report handoff device {field} differs from the selected device"
                )
        if source.get("qualificationEligibleEnvironment") != expected_device.get(
            "qualificationEligible"
        ):
            raise ConfigurationError(
                "device report handoff eligibility differs from the selected device"
            )
    if expected_scenarios is not None:
        scenario_rows = source.get("scenarios")
        report_scenarios = (
            [row.get("scenario") for row in scenario_rows]
            if isinstance(scenario_rows, list)
            and all(isinstance(row, dict) for row in scenario_rows)
            else None
        )
        if report_scenarios != list(expected_scenarios):
            raise ConfigurationError(
                "device report handoff scenarios differ from the selected profile plan"
            )
    expected_checklist, expected_json, expected_markdown, expected_html = (
        _expected_checklist_outputs(args, source, report)
    )
    for description, actual, expected in (
        ("json", rendered["json"], expected_json),
        ("markdown", rendered["markdown"], expected_markdown),
        ("html", rendered["html"], expected_html),
    ):
        if actual != expected:
            raise ConfigurationError(
                f"checklist {description} output differs from an independent rendering"
            )
    if checklist != expected_checklist:
        raise ConfigurationError(
            "checklist handoff JSON differs from its independently rendered value"
        )
    if checklist.get("formatVersion") != 2:
        raise ConfigurationError("checklist handoff formatVersion must be 2")
    if checklist.get("sourceKind") != "deviceReport":
        raise ConfigurationError("checklist handoff is not bound to a device report")
    for field in (
        "version",
        "sourceCommit",
        "releaseSourceDigest",
        "artifactDigest",
        "candidateAppDigest",
    ):
        if checklist.get(field) != source.get(field):
            raise ConfigurationError(
                f"checklist handoff {field} differs from its device report"
            )
    expected_bindings = {
        "featureManifestChecksum": policy.sha256_file(
            getattr(args, "trusted_features", DEFAULT_FEATURES)
        ),
        "qualificationMatrixChecksum": policy.sha256_file(
            getattr(args, "trusted_matrix", DEFAULT_MATRIX)
        ),
    }
    for field, expected in expected_bindings.items():
        if checklist.get(field) != expected or source.get(field) != expected:
            raise ConfigurationError(
                f"checklist handoff {field} differs from selected policy input"
            )
    summary = checklist.get("summary")
    if not isinstance(summary, dict) or not isinstance(
        summary.get("requiredFeaturesSatisfied"), bool
    ):
        raise ConfigurationError("checklist handoff has no boolean completion result")
    if summary.get("releaseReady") is not False:
        raise ConfigurationError(
            "a per-device checklist cannot claim release readiness"
        )
    expected_exit_code = (
        0 if profile.name != "release" or summary["requiredFeaturesSatisfied"] else 1
    )
    if checklist_exit_code != expected_exit_code:
        raise ConfigurationError(
            "checklist exit code contradicts its retained completion result"
        )
    try:
        report_unchanged = (
            report_validation.regular_file_bytes(
                report, "device report handoff"
            )
            == report_bytes
        )
    except report_validation.ReportValidationError as error:
        raise ConfigurationError(
            f"cannot recheck device report handoff: {error}"
        ) from error
    if not report_unchanged or not report_validation.is_valid(
        report.parent, report_bytes=report_bytes
    ):
        raise ConfigurationError(
            "device report or retained evidence changed during checklist handoff"
        )
    return checklist


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def _write_text(path: Path, value: str) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value)
    temporary.replace(path)


def _retained_validation_plans(
    runner_output: Path,
) -> tuple[list[dict[str, Any]], list[str]]:
    plans: list[dict[str, Any]] = []
    warnings: list[str] = []
    for path in sorted(runner_output.glob("*/validation-plan.json")):
        record: dict[str, Any] = {"path": str(path), "readable": False}
        try:
            value = json.loads(path.read_text())
        except (OSError, UnicodeError, json.JSONDecodeError):
            warnings.append(f"retained validation plan is unreadable: {path}")
        else:
            if not isinstance(value, dict):
                warnings.append(f"retained validation plan is not an object: {path}")
            else:
                record.update(
                    {
                        "readable": True,
                        "formatVersion": value.get("formatVersion"),
                        "selectionScope": value.get("selectionScope"),
                        "reportOnly": value.get("reportOnly"),
                        "requestedScenarioDrivers": value.get(
                            "requestedScenarioDrivers"
                        ),
                        "selectedScenarioDrivers": value.get("selectedScenarioDrivers"),
                        "skippedScenarioDrivers": value.get("skippedScenarioDrivers"),
                        "matrixScenarioOutputsPlanned": value.get(
                            "matrixScenarioOutputsPlanned"
                        ),
                    }
                )
        plans.append(record)
    return plans, warnings


def _retained_scenario_diagnostics(
    runner_output: Path, selected_lanes: Sequence[str]
) -> tuple[list[dict[str, Any]], list[str]]:
    diagnostics: list[dict[str, Any]] = []
    warnings: list[str] = []
    selected = set(selected_lanes)
    observed_selected: set[str] = set()
    for path in sorted(runner_output.glob("*/scenario-results.tsv")):
        try:
            lines = path.read_text().splitlines()
        except (OSError, UnicodeError):
            warnings.append(f"retained scenario ledger is unreadable: {path}")
            continue
        for line_number, line in enumerate(lines, start=1):
            fields = line.split("\t")
            if len(fields) != 11 or not fields[0]:
                warnings.append(
                    f"ignored malformed scenario ledger row: {path}:{line_number}"
                )
                continue
            (
                scenario,
                raw_outcome,
                xcodebuild_exit_code,
                library_error_count,
                app_log,
                qualification_evidence,
                duration_seconds,
                _,
                _,
                _,
                _,
            ) = fields
            outcome = {
                "pass": "runner-reported-success",
                "fail": "runner-reported-failure",
            }.get(raw_outcome, "runner-reported-unrecognized-outcome")

            def diagnostic_integer(raw: str, field: str) -> int | None:
                try:
                    return int(raw)
                except ValueError:
                    warnings.append(
                        f"invalid {field} in scenario ledger: {path}:{line_number}"
                    )
                    return None

            selected_lane = scenario in selected
            if selected_lane:
                observed_selected.add(scenario)
            diagnostics.append(
                {
                    "scenario": scenario,
                    "selectedLane": selected_lane,
                    "diagnosticStatus": "completed-but-unvalidated",
                    "runnerOutcome": outcome,
                    "xcodebuildExitCode": diagnostic_integer(
                        xcodebuild_exit_code, "xcodebuild exit code"
                    ),
                    "libraryErrorCount": diagnostic_integer(
                        library_error_count, "library error count"
                    ),
                    "appLog": app_log,
                    "qualificationEvidence": qualification_evidence,
                    "durationSeconds": diagnostic_integer(duration_seconds, "duration"),
                    "releaseCreditEligible": False,
                    "sourceLedger": str(path),
                    "sourceLine": line_number,
                }
            )
    duplicate_selected = sorted(
        scenario
        for scenario in observed_selected
        if sum(
            row["scenario"] == scenario and row["selectedLane"] for row in diagnostics
        )
        > 1
    )
    for scenario in duplicate_selected:
        warnings.append(f"selected lane has duplicate diagnostic rows: {scenario}")
    return diagnostics, warnings


def _incomplete_execution_summary(
    session: dict[str, Any],
    runner_output: Path,
    *,
    termination: str,
    reason: str,
    runner_exit_code: int,
    checklist_exit_code: int | None,
    summary_json: Path,
    summary_markdown: Path,
) -> dict[str, Any]:
    selected_lanes = session.get("selectedScenarios", [])
    if not isinstance(selected_lanes, list) or not all(
        isinstance(lane, str) for lane in selected_lanes
    ):
        selected_lanes = []
    diagnostics, ledger_warnings = _retained_scenario_diagnostics(
        runner_output, selected_lanes
    )
    plans, plan_warnings = _retained_validation_plans(runner_output)
    completed_selected = {row["scenario"] for row in diagnostics if row["selectedLane"]}
    report_candidates = sorted(runner_output.glob("*/report.json"))
    retained_run_directories = sorted(
        path for path in runner_output.glob("*") if path.is_dir()
    )
    return {
        "formatVersion": 1,
        "kind": "swiftvlc-incomplete-unvalidated-execution",
        "status": "incomplete",
        "termination": termination,
        "failure": reason,
        "profile": session.get("profile"),
        "profileSummary": session.get("profileSummary"),
        "expectedDurationMinutes": session.get("expectedDurationMinutes"),
        "version": session.get("version"),
        "stableEnvironmentRequired": session.get("stableEnvironmentRequired"),
        "requiredFeatureCompletenessEnforced": session.get(
            "requiredFeatureCompletenessEnforced"
        ),
        "selectedDevice": session.get("selectedDevice"),
        "selectedLanes": selected_lanes,
        "inapplicableLanes": session.get("inapplicableScenarios", []),
        "runnerExitCode": runner_exit_code,
        "checklistExitCode": checklist_exit_code,
        "reportValidationStatus": "no-validated-report",
        "validatedReport": None,
        "validatedFeatureResults": [],
        "validatedScenarioResults": [],
        "releaseCreditEligible": False,
        "releasePublished": False,
        "releaseCreditReason": (
            "No report was accepted through the validated checklist path."
        ),
        "completedLaneDiagnostics": diagnostics,
        "notCompletedSelectedLanes": [
            lane for lane in selected_lanes if lane not in completed_selected
        ],
        "reportCandidateCount": len(report_candidates),
        "unvalidatedReportCandidates": [str(path) for path in report_candidates],
        "retainedEvidenceDirectory": str(runner_output),
        "retainedRunDirectories": [str(path) for path in retained_run_directories],
        "retainedValidationPlans": plans,
        "retainedScenarioLedgers": [
            str(path) for path in sorted(runner_output.glob("*/scenario-results.tsv"))
        ],
        "diagnosticWarnings": ledger_warnings + plan_warnings,
        "summaryJSONPath": str(summary_json),
        "summaryMarkdownPath": str(summary_markdown),
    }


def _markdown_value(value: object) -> str:
    return str(value).replace("\r", " ").replace("\n", " ").replace("`", "'")


def _incomplete_execution_markdown(summary: dict[str, Any]) -> str:
    lines = [
        "# SwiftVLC incomplete qualification execution",
        "",
        "> **NO RELEASE CREDIT.** No validated device report was accepted. "
        "Every completed lane below is an unvalidated runner diagnostic only.",
        "",
        f"- Profile: `{_markdown_value(summary['profile'])}`",
        f"- Candidate version: `{_markdown_value(summary['version'])}`",
        f"- Termination: `{_markdown_value(summary['termination'])}`",
        f"- Runner exit code: `{_markdown_value(summary['runnerExitCode'])}`",
        *(
            [
                "- Checklist/validator exit code: "
                f"`{_markdown_value(summary['checklistExitCode'])}`"
            ]
            if summary.get("checklistExitCode") is not None
            else []
        ),
        f"- Reason: {_markdown_value(summary['failure'])}",
        f"- Retained evidence: `{_markdown_value(summary['retainedEvidenceDirectory'])}`",
        f"- Machine summary: `{_markdown_value(summary['summaryJSONPath'])}`",
        "",
        "## Completed lane diagnostics (unvalidated)",
        "",
    ]
    diagnostics = summary["completedLaneDiagnostics"]
    if diagnostics:
        for row in diagnostics:
            lines.append(
                f"- `{_markdown_value(row['scenario'])}`: "
                f"{_markdown_value(row['runnerOutcome'])}; "
                "not validated and not eligible for release credit"
            )
    else:
        lines.append("- None retained.")
    lines.extend(["", "## Selected lanes not completed", ""])
    not_completed = summary["notCompletedSelectedLanes"]
    if not_completed:
        lines.extend(f"- `{_markdown_value(lane)}`" for lane in not_completed)
    else:
        lines.append(
            "- None; all selected lanes emitted raw diagnostics, but remain unvalidated."
        )
    lines.extend(["", "## Retained control artifacts", ""])
    plans = summary["retainedValidationPlans"]
    ledgers = summary["retainedScenarioLedgers"]
    if plans:
        lines.extend(
            f"- Validation plan: `{_markdown_value(plan['path'])}`" for plan in plans
        )
    if ledgers:
        lines.extend(
            f"- Scenario ledger: `{_markdown_value(path)}`" for path in ledgers
        )
    if not plans and not ledgers:
        lines.append("- No validation plan or scenario ledger was retained.")
    if summary["unvalidatedReportCandidates"]:
        lines.extend(["", "## Unvalidated report candidates", ""])
        lines.extend(
            f"- `{_markdown_value(path)}`"
            for path in summary["unvalidatedReportCandidates"]
        )
    if summary["diagnosticWarnings"]:
        lines.extend(["", "## Diagnostic warnings", ""])
        lines.extend(
            f"- {_markdown_value(warning)}" for warning in summary["diagnosticWarnings"]
        )
    return "\n".join(lines) + "\n"


def _finish_incomplete_execution(
    session_dir: Path,
    runner_output: Path,
    session: dict[str, Any],
    *,
    session_status: str,
    termination: str,
    reason: str,
    runner_exit_code: int,
    checklist_exit_code: int | None = None,
) -> None:
    summary_json = session_dir / "incomplete-execution-summary.json"
    summary_markdown = session_dir / "incomplete-execution-summary.md"
    session.update(
        {
            "status": session_status,
            "runnerExitCode": runner_exit_code,
            "checklistExitCode": checklist_exit_code,
            "failure": reason,
            "releaseCreditEligible": False,
            "validatedReportAvailable": False,
            "reportValidationStatus": "unavailable",
            "requiredFeaturesSatisfied": False,
            "releaseQualificationComplete": False,
            "checklistCompletionStatus": "unavailable",
            "evidenceClass": "unvalidated",
            "executionCompleted": False,
            "retainedEvidenceDirectory": str(runner_output),
        }
    )
    session_path = session_dir / "session.json"
    recovery_errors: list[str] = []
    try:
        # Persist the terminal no-credit state before inspecting any possibly
        # malformed retained artifact.
        _write_json(session_path, session)
    except Exception as error:
        recovery_errors.append(f"cannot persist terminal session state: {error}")

    summary_written = False
    markdown_written = False
    try:
        summary = _incomplete_execution_summary(
            session,
            runner_output,
            termination=termination,
            reason=reason,
            runner_exit_code=runner_exit_code,
            checklist_exit_code=checklist_exit_code,
            summary_json=summary_json,
            summary_markdown=summary_markdown,
        )
        _write_json(summary_json, summary)
        summary_written = True
        _write_text(summary_markdown, _incomplete_execution_markdown(summary))
        markdown_written = True
    except Exception as error:
        recovery_errors.append(f"cannot render incomplete execution summary: {error}")

    if summary_written:
        session["incompleteExecutionSummaryJSON"] = str(summary_json)
    if markdown_written:
        session["incompleteExecutionSummaryMarkdown"] = str(summary_markdown)
    if recovery_errors:
        session["incompleteExecutionRecoveryErrors"] = recovery_errors
    try:
        _write_json(session_path, session)
    except Exception as error:
        recovery_errors.append(f"cannot update terminal session details: {error}")
        print(
            "Warning: " + recovery_errors[-1],
            file=sys.stderr,
        )

    if summary_written:
        print(f"Incomplete execution summary (no release credit): {summary_json}")
    if markdown_written:
        print(f"Incomplete execution notes: {summary_markdown}")
    for error in recovery_errors:
        print(f"Warning: {error}", file=sys.stderr)
    print(f"Retained evidence: {runner_output}")
    print("No release was published.")


def _session_directory(output_root: Path, profile: str) -> Path:
    timestamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return output_root / f"{timestamp}-{profile}-{os.getpid()}"


def _print_profiles(profiles: Profiles) -> None:
    for profile in profiles.profiles.values():
        stability = (
            "stable physical OS required"
            if profile.stable_environment_required
            else "stable or exploratory physical OS"
        )
        print(
            f"{profile.name:8} ~{profile.expected_duration_minutes:>3} min  "
            f"{stability}\n         {profile.summary}"
        )


def _development_team(value: str) -> str:
    if DEVELOPMENT_TEAM_PATTERN.fullmatch(value) is None:
        raise argparse.ArgumentTypeError(
            "development team must be a 10-character Apple team identifier"
        )
    return value


def _parser(profile_names: Sequence[str]) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Run candidate-bound SwiftVLC checks on one connected physical device and "
            "produce JSON, Markdown, and HTML feature checklists. This never publishes a release."
        )
    )
    parser.add_argument("profile", nargs="?", choices=profile_names)
    parser.add_argument("--list-profiles", action="store_true")
    parser.add_argument(
        "--version",
        help="Exact candidate version recorded in every retained artifact",
    )
    parser.add_argument(
        "--device", help="CoreDevice id, UDID, ECID, or exact device name"
    )
    parser.add_argument(
        "--development-team",
        default=os.environ.get("SWIFTVLC_DEVELOPMENT_TEAM"),
        type=_development_team,
        help=(
            "Apple development team used to sign a disposable build with "
            "team-scoped bundle identifiers"
        ),
    )
    parser.add_argument("--candidate-app", type=Path)
    parser.add_argument("--candidate-metadata", type=Path)
    parser.add_argument("--xctestrun", type=Path)
    parser.add_argument("--derived-data", type=Path)
    parser.add_argument(
        "--work-root",
        type=Path,
        help="Temporary source/build scratch root (use an external SSD for long runs)",
    )
    parser.add_argument("--fixtures", type=Path)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(
            os.environ.get(
                "SWIFTVLC_DEVICE_RESULTS", str(ROOT_DIR / ".qualification-results")
            )
        ),
        help="Parent directory for this qualification session",
    )
    parser.add_argument(
        "--require-stable",
        action="store_true",
        help="Require stable matching hardware even for smoke/full",
    )
    parser.add_argument("--exploratory-current-only", action="store_true")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the complete unfiltered plan without discovering a device",
    )
    parser.set_defaults(
        profiles=DEFAULT_PROFILES,
        runner=DEFAULT_RUNNER,
        checklist=DEFAULT_CHECKLIST,
        features=DEFAULT_FEATURES,
        matrix=DEFAULT_MATRIX,
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    try:
        profiles = load_profiles(DEFAULT_PROFILES, DEFAULT_FEATURES)
    except ConfigurationError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    parser = _parser(tuple(profiles.profiles))
    args = parser.parse_args(argv)
    if args.list_profiles:
        _print_profiles(profiles)
        return 0
    if args.profile is None:
        parser.error("a profile is required (smoke, full, or release)")
    if args.version is None:
        parser.error(
            "--version is required so a beta run cannot be mislabeled as a stable candidate"
        )
    try:
        validate_candidate_version(args.version, DEFAULT_FEATURES)
    except ConfigurationError as error:
        parser.error(str(error))
    if not args.skip_build and not args.development_team:
        parser.error(
            "--development-team (or SWIFTVLC_DEVELOPMENT_TEAM) is required "
            "when building a signed candidate"
        )
    if args.skip_build and args.development_team:
        parser.error(
            "--development-team cannot be combined with --skip-build; "
            "the retained apps already own their signing identity"
        )
    profile = profiles.profiles[args.profile]
    require_stable = profile.stable_environment_required or args.require_stable
    if require_stable and args.exploratory_current_only:
        parser.error("--exploratory-current-only cannot be combined with a stable run")

    runner_output = args.output / "DRY-RUN"
    if args.dry_run:
        command = build_runner_command(
            args,
            profile,
            args.device,
            profile.scenarios,
            runner_output,
            require_stable,
        )
        print(f"Profile: {profile.name}")
        print(f"Expected duration: about {profile.expected_duration_minutes} minutes")
        print("Scenarios:")
        for scenario in profile.scenarios:
            suffix = (
                " (iphone-current only)"
                if scenario in profiles.iphone_current_only_scenarios
                else ""
            )
            print(f"  - {scenario}{suffix}")
        print("Command:")
        print("  " + " ".join(command))
        print("Dry run only; no device was discovered and no release was published.")
        return 0

    try:
        source_authority = _source_authority_identity(args.version)
        device = resolve_device(args.device, require_stable)
        scenarios, inapplicable = applicable_scenarios(
            profile, profiles, device, args.exploratory_current_only
        )
    except ConfigurationError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    identifier = device.get("id")
    if not isinstance(identifier, str) or not identifier:
        print("Error: selected device has no CoreDevice identifier", file=sys.stderr)
        return 2

    session_dir = _session_directory(args.output.resolve(), profile.name)
    runner_output = session_dir / "device-run"
    session_dir.mkdir(parents=True, exist_ok=False)
    runner_output.mkdir(parents=True, exist_ok=False)
    orchestrator_session_binding = secrets.token_hex(32)
    args.orchestrator_session_binding = orchestrator_session_binding
    orchestrator_started_at_utc = dt.datetime.now(dt.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    args.orchestrator_started_at_utc = orchestrator_started_at_utc
    session = {
        "formatVersion": 1,
        "profile": profile.name,
        "profileSummary": profile.summary,
        "expectedDurationMinutes": profile.expected_duration_minutes,
        "version": args.version,
        "orchestratorSessionBinding": orchestrator_session_binding,
        "startedAtUTC": orchestrator_started_at_utc,
        "sourceAuthority": source_authority,
        "stableEnvironmentRequired": require_stable,
        "selectedDevice": device,
        "selectedScenarios": list(scenarios),
        "inapplicableScenarios": list(inapplicable),
        "requiredFeatureCompletenessEnforced": profile.name == "release",
        "releasePublished": False,
        "releaseCreditEligible": False,
        "validatedReportAvailable": False,
        "reportValidationStatus": "pending",
        "requiredFeaturesSatisfied": False,
        "releaseQualificationComplete": False,
        "checklistCompletionStatus": "pending",
        "evidenceClass": None,
        "executionCompleted": False,
        "status": "running",
    }
    _write_json(session_dir / "session.json", session)

    try:
        trusted = _snapshot_trusted_postprocessor(session_dir, source_authority)
        _validate_trusted_postprocessor(trusted, source_authority)
        _assert_source_authority_unchanged(source_authority, args.version)
    except (ConfigurationError, OSError) as error:
        reason = f"trusted qualification source could not be frozen: {error}"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="trusted-source-snapshot-failure",
            reason=reason,
            runner_exit_code=1,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 1
    args.checklist = trusted["checklist"]
    args.features = trusted["features"]
    args.matrix = trusted["matrix"]
    args.trusted_checklist = trusted["checklist"]
    args.trusted_features = trusted["features"]
    args.trusted_matrix = trusted["matrix"]
    session["trustedSourceSnapshot"] = str(trusted["root"])
    session["trustedSourceManifest"] = str(trusted["manifest"])
    session["trustedSourceManifestDigestAlgorithm"] = "sha256"
    session["trustedSourceManifestDigest"] = trusted["manifestDigest"]
    _write_json(session_dir / "session.json", session)
    command = build_runner_command(
        args, profile, identifier, scenarios, runner_output, require_stable
    )

    print(f"Profile: {profile.name} (~{profile.expected_duration_minutes} minutes)")
    print(
        f"Device: {device.get('marketingName') or device.get('name')} ({device.get('osVersion')})"
    )
    if inapplicable:
        print("Not applicable on this device: " + ", ".join(inapplicable))
    print(f"Session: {session_dir}")
    try:
        runner_status = subprocess.run(command).returncode
    except KeyboardInterrupt:
        reason = "qualification runner was interrupted before a report was validated"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="interrupted",
            termination="operator-interrupted",
            reason=reason,
            runner_exit_code=130,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 130
    except OSError as error:
        reason = f"qualification runner could not start: {error}"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="runner-start-failure",
            reason=reason,
            runner_exit_code=1,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 1

    try:
        _validate_trusted_postprocessor(trusted, source_authority)
        _assert_source_authority_unchanged(source_authority, args.version)
    except (ConfigurationError, OSError) as error:
        reason = str(error)
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="source-authority-drift-after-runner",
            reason=reason,
            runner_exit_code=runner_status,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return runner_status or 1

    reports = sorted(runner_output.glob("*/report.json"))
    if len(reports) != 1:
        reason = f"expected exactly one device report, found {len(reports)}"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="runner-exited-without-one-report",
            reason=reason,
            runner_exit_code=runner_status,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return runner_status or 1

    report = reports[0]
    checklist_command = build_checklist_command(
        args, report, require_complete=profile.name == "release"
    )
    try:
        _validate_trusted_postprocessor(trusted, source_authority)
        checklist_status = subprocess.run(checklist_command).returncode
    except KeyboardInterrupt:
        reason = "report validation was interrupted before a checklist was accepted"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="interrupted",
            termination="operator-interrupted-during-report-validation",
            reason=reason,
            runner_exit_code=runner_status,
            checklist_exit_code=130,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 130
    except (OSError, ConfigurationError) as error:
        reason = f"report validator could not start: {error}"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="report-validator-start-failure",
            reason=reason,
            runner_exit_code=runner_status,
            checklist_exit_code=1,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 1
    try:
        _validate_trusted_postprocessor(trusted, source_authority)
        _assert_source_authority_unchanged(source_authority, args.version)
    except (ConfigurationError, OSError) as error:
        reason = str(error)
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="source-authority-drift-during-checklist",
            reason=reason,
            runner_exit_code=runner_status,
            checklist_exit_code=checklist_status,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 1
    try:
        checklist = validate_checklist_handoff(
            args,
            profile,
            report,
            checklist_status,
            expected_device=device,
            expected_scenarios=scenarios,
            expected_session_binding=orchestrator_session_binding,
            expected_orchestrator_started_at=orchestrator_started_at_utc,
            expected_source_authority=source_authority,
        )
    except (ConfigurationError, OSError) as error:
        reason = f"device report/checklist handoff was not accepted: {error}"
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="report-validation-or-rendering-failure",
            reason=reason,
            runner_exit_code=runner_status,
            checklist_exit_code=checklist_status,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return checklist_status if checklist_status not in {0, 1} else 1
    try:
        _validate_trusted_postprocessor(trusted, source_authority)
        _assert_source_authority_unchanged(source_authority, args.version)
    except (ConfigurationError, OSError) as error:
        reason = str(error)
        _finish_incomplete_execution(
            session_dir,
            runner_output,
            session,
            session_status="failed",
            termination="source-authority-drift-during-handoff",
            reason=reason,
            runner_exit_code=runner_status,
            checklist_exit_code=checklist_status,
        )
        print(f"Error: {reason}", file=sys.stderr)
        return 1
    summary = checklist["summary"]
    scope = checklist["scope"]
    execution_completed = runner_status == 0 and checklist_status == 0
    required_features_satisfied = summary["requiredFeaturesSatisfied"] is True
    release_credit_eligible = scope.get("releaseCreditEligible") is True
    release_qualification_complete = (
        execution_completed
        and release_credit_eligible
        and required_features_satisfied
    )
    session.update(
        {
            "runnerExitCode": runner_status,
            "checklistExitCode": checklist_status,
            "report": str(report),
            "checklistDirectory": str(report.parent),
            "validatedReportAvailable": True,
            "reportValidationStatus": "validated",
            "releaseCreditEligible": release_credit_eligible,
            "requiredFeaturesSatisfied": required_features_satisfied,
            "releaseQualificationComplete": release_qualification_complete,
            "checklistCompletionStatus": (
                "complete" if required_features_satisfied else "incomplete"
            ),
            "evidenceClass": scope.get("evidenceClass"),
            "executionCompleted": execution_completed,
            "status": (
                "passed"
                if release_qualification_complete
                else "completed" if execution_completed else "failed"
            ),
        }
    )
    _write_json(session_dir / "session.json", session)

    print(f"Machine report: {report}")
    print(f"Feature checklist: {report.parent / 'feature-checklist.md'}")
    print(f"Browser report: {report.parent / 'feature-checklist.html'}")
    print("No release was published.")
    if runner_status != 0:
        return runner_status
    return checklist_status


if __name__ == "__main__":
    raise SystemExit(main())
