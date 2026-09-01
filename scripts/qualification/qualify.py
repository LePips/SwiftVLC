#!/usr/bin/env python3
"""Run a named physical-device qualification profile and render its checklist."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

SCRIPT_DIR = Path(__file__).resolve().parent
ROOT_DIR = SCRIPT_DIR.parents[1]
DEFAULT_PROFILES = SCRIPT_DIR / "profiles-v1.json"
DEFAULT_MATRIX = SCRIPT_DIR / "matrix.json"
DEFAULT_FEATURES = SCRIPT_DIR / "feature-manifest-v1.json"
DEFAULT_RUNNER = SCRIPT_DIR / "run-device-tests.sh"
DEFAULT_CHECKLIST = SCRIPT_DIR / "feature-checklist.py"
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


def _read_json(path: Path) -> Any:
    try:
        return policy.load_json(path, "qualification profiles")
    except (OSError, policy.QualificationPolicyError) as error:
        raise ConfigurationError(f"cannot read JSON from {path}: {error}") from error


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
    actual_release = set(profiles["release"].scenarios)
    if actual_release != policy.REQUIRED_RELEASE_RUNNER_SCENARIOS:
        raise ConfigurationError(
            "release profile differs from immutable runner coverage; "
            f"missing={sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS - actual_release)}, "
            f"extra={sorted(actual_release - policy.REQUIRED_RELEASE_RUNNER_SCENARIOS)}"
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
        str(DEFAULT_MATRIX),
        "--input",
        str(report),
        "--output-dir",
        str(report.parent),
    ]
    if require_complete:
        command.append("--enforce-canonical-policy")
        command.append("--require-complete")
    return command


def _write_json(path: Path, payload: dict[str, Any]) -> None:
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


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
    parser.add_argument("--version", default="1.1.0")
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
    parser.add_argument(
        "--profiles", type=Path, default=DEFAULT_PROFILES, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--runner", type=Path, default=DEFAULT_RUNNER, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--checklist", type=Path, default=DEFAULT_CHECKLIST, help=argparse.SUPPRESS
    )
    parser.add_argument(
        "--features", type=Path, default=DEFAULT_FEATURES, help=argparse.SUPPRESS
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    bootstrap = argparse.ArgumentParser(add_help=False)
    bootstrap.add_argument("--profiles", type=Path, default=DEFAULT_PROFILES)
    bootstrap.add_argument("--features", type=Path, default=DEFAULT_FEATURES)
    bootstrap_args, _ = bootstrap.parse_known_args(argv)
    try:
        profiles = load_profiles(bootstrap_args.profiles, bootstrap_args.features)
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
    command = build_runner_command(
        args, profile, identifier, scenarios, runner_output, require_stable
    )
    session = {
        "formatVersion": 1,
        "profile": profile.name,
        "profileSummary": profile.summary,
        "expectedDurationMinutes": profile.expected_duration_minutes,
        "version": args.version,
        "stableEnvironmentRequired": require_stable,
        "selectedDevice": device,
        "selectedScenarios": list(scenarios),
        "inapplicableScenarios": list(inapplicable),
        "requiredFeatureCompletenessEnforced": profile.name == "release",
        "releasePublished": False,
        "status": "running",
    }
    _write_json(session_dir / "session.json", session)

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
        session["status"] = "interrupted"
        _write_json(session_dir / "session.json", session)
        return 130

    reports = sorted(runner_output.glob("*/report.json"))
    if len(reports) != 1:
        session["status"] = "failed"
        session["runnerExitCode"] = runner_status
        session["failure"] = f"expected exactly one device report, found {len(reports)}"
        _write_json(session_dir / "session.json", session)
        print(f"Error: {session['failure']}", file=sys.stderr)
        return runner_status or 1

    report = reports[0]
    checklist_command = build_checklist_command(
        args, report, require_complete=profile.name == "release"
    )
    checklist_status = subprocess.run(checklist_command).returncode
    session["runnerExitCode"] = runner_status
    session["checklistExitCode"] = checklist_status
    session["report"] = str(report)
    session["checklistDirectory"] = str(report.parent)
    session["status"] = (
        "passed" if runner_status == 0 and checklist_status == 0 else "failed"
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
