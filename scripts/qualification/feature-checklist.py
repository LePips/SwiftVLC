#!/usr/bin/env python3
"""Render a feature-oriented checklist from device qualification evidence.

The device runner records implementation scenarios because those identifiers are
useful to automation.  A release reviewer needs a different view: which public
behaviours were proven, which were not run, and which still have no trustworthy
device qualification at all.  This module joins a versioned feature manifest to
the qualification matrix without weakening either artifact's existing checks.

The generated files intentionally contain no wall-clock timestamp.  Identical
inputs produce byte-for-byte identical JSON, Markdown, and HTML reports.
"""

from __future__ import annotations

import argparse
from datetime import date
import hashlib
import html
import json
import os
import re
import sys
import tempfile
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy


class ChecklistError(ValueError):
    pass


ID = re.compile(r"[a-z0-9][a-z0-9-]*")
SHA1 = re.compile(r"[0-9a-f]{40}")
SHA256 = re.compile(r"[0-9a-f]{64}")
EXECUTION_KINDS = {"automated", "operator-assisted", "external-lab", "planned"}
EVIDENCE_BACKED_EXECUTION_KINDS = {"automated", "operator-assisted"}
REQUIREMENT_KINDS = {"required", "advisory"}
EVIDENCE_LEVELS = {
    "engine-output",
    "system-output",
    "receiver-output",
    "operator-observed",
}
RESULT_ORDER = ("pass", "fail", "partial", "notRun", "blocked", "notApplicable")
UPSTREAM_PROJECT_URLS = {
    "VLC": "https://code.videolan.org/videolan/vlc/-/work_items/",
    "VLCKit": "https://code.videolan.org/videolan/VLCKit/-/work_items/",
}
UPSTREAM_STATES = {"open", "closed"}


def _reject_duplicate_keys(pairs: list[tuple[str, object]]) -> dict:
    value: dict[str, object] = {}
    for key, item in pairs:
        if key in value:
            raise ChecklistError(f"duplicate JSON key {key!r}")
        value[key] = item
    return value


def load_json(path: Path, description: str) -> dict:
    try:
        return policy.load_json(path, description)
    except policy.QualificationPolicyError as error:
        raise ChecklistError(str(error)) from error


def file_checksum(path: Path) -> str:
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise ChecklistError(f"cannot checksum {path}: {error}") from error


def _string(value: object, description: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ChecklistError(f"{description} must be a non-empty string")
    return value


def _identifier(value: object, description: str) -> str:
    result = _string(value, description)
    if not ID.fullmatch(result):
        raise ChecklistError(f"{description} has invalid id {result!r}")
    return result


def validate_matrix(matrix: dict) -> tuple[dict[str, dict], dict[str, dict]]:
    scenarios = matrix.get("scenarios")
    hardware = matrix.get("hardware")
    if not isinstance(scenarios, list) or not scenarios:
        raise ChecklistError("qualification matrix needs a non-empty scenarios array")
    if not isinstance(hardware, list) or not hardware:
        raise ChecklistError("qualification matrix needs a non-empty hardware array")

    hardware_by_id: dict[str, dict] = {}
    for index, row in enumerate(hardware):
        if not isinstance(row, dict):
            raise ChecklistError(f"hardware row {index} must be an object")
        row_id = _identifier(row.get("id"), f"hardware row {index}")
        if row_id in hardware_by_id:
            raise ChecklistError(f"duplicate hardware id {row_id!r}")
        _string(row.get("summary"), f"hardware {row_id} summary")
        _string(row.get("deviceFamily"), f"hardware {row_id} deviceFamily")
        if not isinstance(row.get("osMajor"), int) or row["osMajor"] <= 0:
            raise ChecklistError(
                f"hardware {row_id} osMajor must be a positive integer"
            )
        hardware_by_id[row_id] = row

    scenario_by_id: dict[str, dict] = {}
    for index, scenario in enumerate(scenarios):
        if not isinstance(scenario, dict):
            raise ChecklistError(f"scenario {index} must be an object")
        scenario_id = _identifier(scenario.get("id"), f"scenario {index}")
        if scenario_id in scenario_by_id:
            raise ChecklistError(f"duplicate scenario id {scenario_id!r}")
        _string(scenario.get("summary"), f"scenario {scenario_id} summary")
        selected = scenario.get("hardware", list(hardware_by_id))
        if (
            not isinstance(selected, list)
            or not selected
            or any(not isinstance(item, str) for item in selected)
            or len(set(selected)) != len(selected)
        ):
            raise ChecklistError(
                f"scenario {scenario_id} hardware must be a non-empty unique string array"
            )
        unknown = sorted(set(selected) - set(hardware_by_id))
        if unknown:
            raise ChecklistError(
                f"scenario {scenario_id} names unknown hardware: {', '.join(unknown)}"
            )
        scenario_by_id[scenario_id] = scenario
    return scenario_by_id, hardware_by_id


def validate_manifest(
    manifest: dict, matrix: dict, *, enforce_canonical_required_ids: bool = False
) -> dict:
    scenario_by_id, hardware_by_id = validate_matrix(matrix)
    if manifest.get("formatVersion") != 1:
        raise ChecklistError("feature manifest formatVersion must be 1")
    manifest_id = _identifier(manifest.get("id"), "feature manifest")
    manifest_version = _string(manifest.get("manifestVersion"), "manifestVersion")
    release_prefix = _string(
        manifest.get("releaseVersionPrefix"), "releaseVersionPrefix"
    )
    _string(manifest.get("title"), "feature manifest title")

    categories = manifest.get("categories")
    if not isinstance(categories, list) or not categories:
        raise ChecklistError("feature manifest needs a non-empty categories array")
    category_by_id: dict[str, dict] = {}
    for index, category in enumerate(categories):
        if not isinstance(category, dict):
            raise ChecklistError(f"category {index} must be an object")
        category_id = _identifier(category.get("id"), f"category {index}")
        if category_id in category_by_id:
            raise ChecklistError(f"duplicate category id {category_id!r}")
        _string(category.get("title"), f"category {category_id} title")
        category_by_id[category_id] = category

    features = manifest.get("features")
    if not isinstance(features, list) or not features:
        raise ChecklistError("feature manifest needs a non-empty features array")
    feature_ids: set[str] = set()
    feature_by_id: dict[str, dict] = {}
    covered_scenarios: set[str] = set()
    for index, feature in enumerate(features):
        if not isinstance(feature, dict):
            raise ChecklistError(f"feature {index} must be an object")
        feature_id = _identifier(feature.get("id"), f"feature {index}")
        if feature_id in feature_ids:
            raise ChecklistError(f"duplicate feature id {feature_id!r}")
        feature_ids.add(feature_id)
        feature_by_id[feature_id] = feature
        _string(feature.get("title"), f"feature {feature_id} title")
        _string(feature.get("description"), f"feature {feature_id} description")
        category_id = _identifier(
            feature.get("category"), f"feature {feature_id} category"
        )
        if category_id not in category_by_id:
            raise ChecklistError(
                f"feature {feature_id} names unknown category {category_id!r}"
            )
        execution = feature.get("execution")
        if execution not in EXECUTION_KINDS:
            raise ChecklistError(
                f"feature {feature_id} execution must be one of "
                + ", ".join(sorted(EXECUTION_KINDS))
            )
        requirement = feature.get("releaseRequirement")
        if requirement not in REQUIREMENT_KINDS:
            raise ChecklistError(
                f"feature {feature_id} releaseRequirement must be required or advisory"
            )
        evidence_level = feature.get("evidenceLevel")
        if evidence_level not in EVIDENCE_LEVELS:
            raise ChecklistError(
                f"feature {feature_id} has unsupported evidenceLevel {evidence_level!r}"
            )
        scenario_ids = feature.get("scenarioIds", [])
        if (
            not isinstance(scenario_ids, list)
            or any(not isinstance(item, str) for item in scenario_ids)
            or len(set(scenario_ids)) != len(scenario_ids)
        ):
            raise ChecklistError(
                f"feature {feature_id} scenarioIds must be a unique string array"
            )
        unknown = sorted(set(scenario_ids) - set(scenario_by_id))
        if unknown:
            raise ChecklistError(
                f"feature {feature_id} names unknown scenarios: {', '.join(unknown)}"
            )
        runner_ids = feature.get("runnerScenarioIds", [])
        if (
            not isinstance(runner_ids, list)
            or any(not ID.fullmatch(str(item)) for item in runner_ids)
            or len(set(runner_ids)) != len(runner_ids)
        ):
            raise ChecklistError(
                f"feature {feature_id} runnerScenarioIds must be a unique id array"
            )
        if execution in EVIDENCE_BACKED_EXECUTION_KINDS and scenario_ids:
            if not runner_ids:
                raise ChecklistError(
                    f"evidence-backed feature {feature_id} needs a runnerScenarioId"
                )
            if "blocker" in feature:
                raise ChecklistError(
                    f"evidence-backed feature {feature_id} cannot retain a blocker"
                )
            covered_scenarios.update(scenario_ids)
        elif execution == "automated":
            if not scenario_ids:
                raise ChecklistError(
                    f"automated feature {feature_id} needs at least one scenarioId"
                )
        else:
            if scenario_ids or runner_ids:
                raise ChecklistError(
                    f"non-evidence-backed feature {feature_id} cannot claim scenarios"
                )
            _string(feature.get("blocker"), f"feature {feature_id} blocker")

    if enforce_canonical_required_ids:
        actual_required = {
            feature_id
            for feature_id, feature in feature_by_id.items()
            if feature.get("releaseRequirement") == "required"
        }
        if actual_required != policy.REQUIRED_FEATURE_IDS:
            missing = sorted(policy.REQUIRED_FEATURE_IDS - actual_required)
            extra = sorted(actual_required - policy.REQUIRED_FEATURE_IDS)
            raise ChecklistError(
                "canonical required feature-ID obligations changed; "
                f"missing={missing}, extra={extra}"
            )

    static_controls = manifest.get("staticControls", [])
    if not isinstance(static_controls, list):
        raise ChecklistError("staticControls must be an array")
    control_by_id: dict[str, dict] = {}
    for index, control in enumerate(static_controls):
        if not isinstance(control, dict):
            raise ChecklistError(f"static control {index} must be an object")
        control_id = _identifier(control.get("id"), f"static control {index}")
        if control_id in control_by_id:
            raise ChecklistError(f"duplicate static control id {control_id!r}")
        _string(control.get("title"), f"static control {control_id} title")
        _string(control.get("description"), f"static control {control_id} description")
        command = _string(
            control.get("command"), f"static control {control_id} command"
        )
        if "\n" in command or "\r" in command:
            raise ChecklistError(
                f"static control {control_id} command must be a single line"
            )
        control_by_id[control_id] = control

    risk_review = manifest.get("upstreamRiskReview")
    requires_fresh_risk_review = manifest.get("requiresFreshUpstreamRiskReview", False)
    if not isinstance(requires_fresh_risk_review, bool):
        raise ChecklistError("requiresFreshUpstreamRiskReview must be a boolean")
    if requires_fresh_risk_review and risk_review is None:
        raise ChecklistError("the feature policy requires a fresh upstreamRiskReview")
    risks: list[dict] = []
    risks_by_feature: dict[str, list[dict]] = {
        feature_id: [] for feature_id in feature_ids
    }
    if risk_review is not None:
        if not isinstance(risk_review, dict):
            raise ChecklistError("upstreamRiskReview must be an object")
        reviewed_on = _string(
            risk_review.get("reviewedOn"), "upstream risk review date"
        )
        try:
            parsed_review_date = date.fromisoformat(reviewed_on)
        except ValueError as error:
            raise ChecklistError(
                "upstream risk review date must be an ISO calendar date"
            ) from error
        if parsed_review_date.isoformat() != reviewed_on:
            raise ChecklistError(
                "upstream risk review date must use canonical YYYY-MM-DD form"
            )
        maximum_age_days = risk_review.get("maximumAgeDays")
        if (
            isinstance(maximum_age_days, bool)
            or not isinstance(maximum_age_days, int)
            or not 1 <= maximum_age_days <= 365
        ):
            raise ChecklistError(
                "upstream risk review maximumAgeDays must be an integer from 1 to 365"
            )
        if requires_fresh_risk_review:
            review_age_days = (date.today() - parsed_review_date).days
            if review_age_days < 0:
                raise ChecklistError(
                    "upstream risk review date cannot be in the future"
                )
            if review_age_days > maximum_age_days:
                raise ChecklistError(
                    "upstream risk review is stale: "
                    f"{review_age_days} days old, maximum {maximum_age_days}"
                )
        _string(risk_review.get("policy"), "upstream risk review policy")
        risk_rows = risk_review.get("risks")
        if not isinstance(risk_rows, list) or not risk_rows:
            raise ChecklistError("upstreamRiskReview needs a non-empty risks array")

        risk_ids: set[str] = set()
        for index, risk in enumerate(risk_rows):
            if not isinstance(risk, dict):
                raise ChecklistError(f"upstream risk {index} must be an object")
            risk_id = _identifier(risk.get("id"), f"upstream risk {index}")
            if risk_id in risk_ids:
                raise ChecklistError(f"duplicate upstream risk id {risk_id!r}")
            risk_ids.add(risk_id)
            project = risk.get("sourceProject")
            if project not in UPSTREAM_PROJECT_URLS:
                raise ChecklistError(
                    f"upstream risk {risk_id} sourceProject must be VLC or VLCKit"
                )
            issue = risk.get("sourceIssue")
            if isinstance(issue, bool) or not isinstance(issue, int) or issue <= 0:
                raise ChecklistError(
                    f"upstream risk {risk_id} sourceIssue must be a positive integer"
                )
            state = risk.get("sourceStateAtReview")
            if state not in UPSTREAM_STATES:
                raise ChecklistError(
                    f"upstream risk {risk_id} sourceStateAtReview must be open or closed"
                )
            expected_url = f"{UPSTREAM_PROJECT_URLS[project]}{issue}"
            if risk.get("sourceURL") != expected_url:
                raise ChecklistError(
                    f"upstream risk {risk_id} sourceURL must be {expected_url!r}"
                )
            _string(risk.get("title"), f"upstream risk {risk_id} title")
            _string(risk.get("failureMode"), f"upstream risk {risk_id} failureMode")

            mapped_features = risk.get("featureIds")
            if (
                not isinstance(mapped_features, list)
                or not mapped_features
                or any(not isinstance(item, str) for item in mapped_features)
                or len(set(mapped_features)) != len(mapped_features)
            ):
                raise ChecklistError(
                    f"upstream risk {risk_id} featureIds must be a non-empty unique string array"
                )
            unknown_features = sorted(set(mapped_features) - feature_ids)
            if unknown_features:
                raise ChecklistError(
                    f"upstream risk {risk_id} names unknown features: "
                    + ", ".join(unknown_features)
                )
            advisory_features = sorted(
                feature_id
                for feature_id in mapped_features
                if feature_by_id[feature_id]["releaseRequirement"] != "required"
            )
            if advisory_features:
                raise ChecklistError(
                    f"upstream risk {risk_id} is not release-gated by required features: "
                    + ", ".join(advisory_features)
                )

            mapped_controls = risk.get("controlIds", [])
            if (
                not isinstance(mapped_controls, list)
                or any(not isinstance(item, str) for item in mapped_controls)
                or len(set(mapped_controls)) != len(mapped_controls)
            ):
                raise ChecklistError(
                    f"upstream risk {risk_id} controlIds must be a unique string array"
                )
            unknown_controls = sorted(set(mapped_controls) - set(control_by_id))
            if unknown_controls:
                raise ChecklistError(
                    f"upstream risk {risk_id} names unknown static controls: "
                    + ", ".join(unknown_controls)
                )

            risks.append(risk)
            for feature_id in mapped_features:
                risks_by_feature[feature_id].append(risk)

    uncovered = sorted(set(scenario_by_id) - covered_scenarios)
    if uncovered:
        raise ChecklistError(
            "feature manifest leaves matrix scenarios unclassified: "
            + ", ".join(uncovered)
        )

    return {
        "manifestId": manifest_id,
        "manifestVersion": manifest_version,
        "releaseVersionPrefix": release_prefix,
        "scenarioById": scenario_by_id,
        "hardwareById": hardware_by_id,
        "categoryById": category_by_id,
        "staticControlById": control_by_id,
        "upstreamRiskReview": risk_review,
        "upstreamRisks": risks,
        "upstreamRisksByFeature": risks_by_feature,
    }


def _source_kind(source: dict) -> str:
    if isinstance(source.get("qualificationRows"), list):
        return "deviceReport"
    if isinstance(source.get("rows"), list):
        return "releaseRecord"
    raise ChecklistError(
        "input is neither a device report nor an assembled release record"
    )


def _source_rows(source: dict, source_kind: str) -> list[dict]:
    value = (
        source["qualificationRows"] if source_kind == "deviceReport" else source["rows"]
    )
    if not isinstance(value, list):
        raise ChecklistError("qualification rows must be an array")
    return value


def _validate_source_identity(
    source: dict, release_prefix: str, matrix_checksum: str
) -> None:
    version = source.get("version")
    if not isinstance(version, str) or not (
        version == release_prefix or version.startswith(f"{release_prefix}-")
    ):
        raise ChecklistError(
            f"input version {version!r} is not in release series {release_prefix!r}"
        )
    recorded_matrix = source.get("qualificationMatrixChecksum")
    if recorded_matrix != matrix_checksum:
        raise ChecklistError(
            "input qualificationMatrixChecksum does not match the selected matrix"
        )
    if not isinstance(source.get("sourceCommit"), str) or not SHA1.fullmatch(
        source["sourceCommit"]
    ):
        raise ChecklistError("input has no valid sourceCommit")
    for field, algorithm_field, algorithm in (
        ("artifactDigest", "artifactDigestAlgorithm", "swiftvlc-tree-v1"),
        (
            "releaseSourceDigest",
            "releaseSourceDigestAlgorithm",
            "swiftvlc-git-tree-v1",
        ),
    ):
        value = source.get(field)
        if not isinstance(value, str) or not SHA256.fullmatch(value):
            raise ChecklistError(f"input has no valid {field}")
        if source.get(algorithm_field) != algorithm:
            raise ChecklistError(f"input {algorithm_field} must be {algorithm!r}")
    if isinstance(source.get("qualificationRows"), list):
        app_digest = source.get("candidateAppDigest")
        if not isinstance(app_digest, str) or not SHA256.fullmatch(app_digest):
            raise ChecklistError("device report has no valid candidateAppDigest")
        if source.get("candidateAppDigestAlgorithm") != "swiftvlc-tree-v1":
            raise ChecklistError(
                "device report candidateAppDigestAlgorithm must be 'swiftvlc-tree-v1'"
            )


def _index_rows(
    rows: list[dict], scenario_by_id: dict[str, dict], hardware_by_id: dict[str, dict]
) -> dict[tuple[str, str], dict]:
    indexed: dict[tuple[str, str], dict] = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ChecklistError(f"qualification row {index} must be an object")
        scenario = row.get("scenario")
        hardware = row.get("hardware")
        if scenario not in scenario_by_id:
            raise ChecklistError(
                f"qualification row {index} has unknown scenario {scenario!r}"
            )
        if hardware not in hardware_by_id:
            raise ChecklistError(
                f"qualification row {index} has unknown hardware {hardware!r}"
            )
        key = (scenario, hardware)
        if key in indexed:
            raise ChecklistError(
                f"duplicate qualification row {scenario} on {hardware}"
            )
        if not isinstance(row.get("result"), str) or not row["result"]:
            raise ChecklistError(
                f"qualification row {scenario} on {hardware} has no result"
            )
        indexed[key] = row
    return indexed


def _runner_results(source: dict) -> dict[str, dict]:
    rows = source.get("scenarios")
    if not isinstance(rows, list):
        rows = source.get("runnerScenarios")
    if not isinstance(rows, list):
        return {}
    result: dict[str, dict] = {}
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ChecklistError(f"runner scenario {index} must be an object")
        scenario = row.get("scenario")
        if not isinstance(scenario, str) or not ID.fullmatch(scenario):
            raise ChecklistError(f"runner scenario {index} has an invalid id")
        if not isinstance(row.get("result"), str) or not row["result"]:
            raise ChecklistError(f"runner scenario {scenario!r} has no result")
        previous = result.get(scenario)
        if previous is None or (
            previous.get("result") == "pass" and row.get("result") != "pass"
        ):
            result[scenario] = row
    return result


def _scope_hardware(
    source: dict,
    source_kind: str,
    indexed_rows: dict[tuple[str, str], dict],
    hardware_by_id: dict[str, dict],
) -> tuple[list[str], dict | None]:
    if source_kind == "releaseRecord":
        return list(hardware_by_id), None
    device = source.get("device")
    if not isinstance(device, dict):
        raise ChecklistError("device report has no device object")
    matching = device.get("matchingHardwareRows")
    if not isinstance(matching, list):
        raise ChecklistError("device report has no matchingHardwareRows array")
    if matching:
        if len(set(matching)) != len(matching):
            raise ChecklistError("device report has duplicate matching hardware rows")
        if any(item not in hardware_by_id for item in matching):
            raise ChecklistError("device report names an unknown matching hardware row")
        return [item for item in hardware_by_id if item in matching], None

    # A future OS has no exact stable-matrix row.  The runner's explicit
    # exploratory-current-only mode can still exercise those scenarios, but it
    # intentionally materializes no qualification rows.  Project that report
    # onto the latest same-family row solely to render an honest NOT RUN list.
    # Requiring every condition below prevents a malformed, current, or
    # qualifying report from borrowing a different hardware scope.
    if indexed_rows:
        raise ChecklistError(
            "a device with no matching hardware row cannot contain qualification rows"
        )
    if source.get("mode") != "exploratory":
        raise ChecklistError(
            "a device with no matching hardware row must be explicitly exploratory"
        )
    if source.get("qualificationEligibleEnvironment") is not False:
        raise ChecklistError(
            "an exploratory hardware projection cannot be qualification-eligible"
        )
    family = device.get("deviceFamily")
    os_major = device.get("osMajor")
    if not isinstance(family, str) or not family:
        raise ChecklistError("exploratory device has no deviceFamily")
    if isinstance(os_major, bool) or not isinstance(os_major, int) or os_major <= 0:
        raise ChecklistError("exploratory device has no valid osMajor")
    family_rows = [
        (hardware_id, hardware)
        for hardware_id, hardware in hardware_by_id.items()
        if hardware.get("deviceFamily") == family
    ]
    if not family_rows:
        raise ChecklistError(
            f"exploratory device family {family!r} has no qualification matrix row"
        )
    latest_major = max(hardware["osMajor"] for _, hardware in family_rows)
    if os_major <= latest_major:
        raise ChecklistError(
            "exploratory hardware projection is allowed only for a future OS major"
        )
    latest_rows = [
        hardware_id
        for hardware_id, hardware in family_rows
        if hardware["osMajor"] == latest_major
    ]
    if len(latest_rows) != 1:
        raise ChecklistError(
            f"latest {family} matrix scope is ambiguous: {', '.join(latest_rows)}"
        )
    projected = latest_rows[0]
    return [projected], {
        "reason": "futureDeviceChecklistProjection",
        "deviceFamily": family,
        "deviceOSMajor": os_major,
        "matrixHardware": projected,
        "matrixOSMajor": latest_major,
        "qualificationRowsAccepted": False,
    }


def _expected_rows(
    scenario_ids: list[str],
    scope_hardware: list[str],
    scenario_by_id: dict[str, dict],
    hardware_by_id: dict[str, dict],
) -> list[tuple[str, str]]:
    result: list[tuple[str, str]] = []
    for scenario_id in scenario_ids:
        scenario = scenario_by_id[scenario_id]
        selected = scenario.get("hardware", list(hardware_by_id))
        for hardware_id in scope_hardware:
            if hardware_id in selected:
                result.append((scenario_id, hardware_id))
    return result


def _evidence_records(
    expected: list[tuple[str, str]], indexed_rows: dict[tuple[str, str], dict]
) -> list[dict]:
    records = []
    for scenario, hardware in expected:
        row = indexed_rows.get((scenario, hardware))
        records.append(
            {
                "scenario": scenario,
                "hardware": hardware,
                "result": row.get("result") if row else "notRun",
                "evidence": row.get("evidence") if row else None,
                "durationSeconds": row.get("durationSeconds") if row else None,
            }
        )
    return records


def build_checklist(
    source: dict,
    manifest: dict,
    matrix: dict,
    *,
    manifest_checksum: str,
    matrix_checksum: str,
) -> dict:
    validated = validate_manifest(manifest, matrix)
    if (
        source.get("featureManifestChecksum") is not None
        and source.get("featureManifestChecksum") != manifest_checksum
    ):
        raise ChecklistError(
            "input featureManifestChecksum does not match the selected feature policy"
        )
    _validate_source_identity(
        source, validated["releaseVersionPrefix"], matrix_checksum
    )
    source_kind = _source_kind(source)
    indexed_rows = _index_rows(
        _source_rows(source, source_kind),
        validated["scenarioById"],
        validated["hardwareById"],
    )
    runner_results = _runner_results(source)
    scope_hardware, exploratory_projection = _scope_hardware(
        source,
        source_kind,
        indexed_rows,
        validated["hardwareById"],
    )

    feature_results = []
    for feature in manifest["features"]:
        execution = feature["execution"]
        scenario_ids = feature.get("scenarioIds", [])
        expected = _expected_rows(
            scenario_ids,
            scope_hardware,
            validated["scenarioById"],
            validated["hardwareById"],
        )
        evidence = _evidence_records(expected, indexed_rows)
        runner_failures = [
            scenario
            for scenario in feature.get("runnerScenarioIds", [])
            if scenario in runner_results
            and runner_results[scenario].get("result") != "pass"
        ]
        missing_runners = [
            scenario
            for scenario in feature.get("runnerScenarioIds", [])
            if scenario not in runner_results
        ]

        if execution not in EVIDENCE_BACKED_EXECUTION_KINDS or not scenario_ids:
            status = "blocked"
            detail = feature["blocker"]
        elif not expected:
            status = "notApplicable"
            detail = "This feature is not applicable to the selected hardware scope."
        elif runner_failures:
            status = "fail"
            detail = "Runner failure: " + ", ".join(runner_failures)
        elif missing_runners:
            status = "notRun"
            detail = "Runner not run: " + ", ".join(missing_runners)
        else:
            observed = [indexed_rows[key] for key in expected if key in indexed_rows]
            failed = [row for row in observed if row.get("result") != "pass"]
            if failed:
                status = "fail"
                detail = "At least one required qualification row failed."
            elif len(observed) == len(expected):
                status = "pass"
                detail = "Every required qualification row passed."
            elif observed:
                status = "partial"
                detail = f"{len(observed)} of {len(expected)} required rows passed."
            else:
                status = "notRun"
                detail = "No qualifying evidence was recorded."

        feature_results.append(
            {
                "id": feature["id"],
                "category": feature["category"],
                "title": feature["title"],
                "description": feature["description"],
                "releaseRequirement": feature["releaseRequirement"],
                "execution": execution,
                "evidenceLevel": feature["evidenceLevel"],
                "status": status,
                "detail": detail,
                "evidence": evidence,
                "upstreamRisks": [
                    {
                        "id": risk["id"],
                        "title": risk["title"],
                        "sourceProject": risk["sourceProject"],
                        "sourceIssue": risk["sourceIssue"],
                        "sourceStateAtReview": risk["sourceStateAtReview"],
                        "sourceURL": risk["sourceURL"],
                    }
                    for risk in validated["upstreamRisksByFeature"][feature["id"]]
                ],
            }
        )

    counts = Counter(feature["status"] for feature in feature_results)
    required = [
        feature
        for feature in feature_results
        if feature["releaseRequirement"] == "required"
        and feature["status"] != "notApplicable"
    ]
    if source_kind == "releaseRecord":
        actual_runner_runs = {
            (row.get("scenario"), row.get("hardware"))
            for row in source.get("runnerScenarios", [])
            if isinstance(row, dict)
        }
        missing_required_runner_runs = sorted(
            policy.required_release_runner_runs(matrix) - actual_runner_runs
        )
    else:
        required_runner_ids = {
            runner
            for runner in policy.REQUIRED_RELEASE_RUNNER_SCENARIOS
            if runner not in policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
            or "iphone-current" in scope_hardware
        }
        missing_required_runner_runs = [
            (runner, scope_hardware[0] if len(scope_hardware) == 1 else "device")
            for runner in sorted(required_runner_ids - set(runner_results))
        ]
    required_satisfied = (
        bool(required)
        and not missing_required_runner_runs
        and all(row.get("result") == "pass" for row in runner_results.values())
        and all(feature["status"] == "pass" for feature in required)
    )
    runner_failures = [
        {
            "scenario": scenario,
            "result": row.get("result"),
            "xcodebuildExitCode": row.get("xcodebuildExitCode"),
            "libraryErrorCount": row.get("libraryErrorCount"),
        }
        for scenario, row in runner_results.items()
        if row.get("result") != "pass"
    ]
    runner_failures.extend(
        {
            "scenario": scenario,
            "hardware": hardware,
            "result": "notRun",
            "xcodebuildExitCode": None,
            "libraryErrorCount": None,
        }
        for scenario, hardware in missing_required_runner_runs
    )

    scope = {
        "kind": "device" if source_kind == "deviceReport" else "release",
        "hardware": scope_hardware,
    }
    if source_kind == "deviceReport":
        device = source["device"]
        scope["qualificationEligibleEnvironment"] = source.get(
            "qualificationEligibleEnvironment"
        )
        scope["device"] = {
            key: device.get(key)
            for key in (
                "name",
                "marketingName",
                "productType",
                "osVersion",
                "osBuild",
                "osReleaseType",
            )
        }
        if exploratory_projection is not None:
            scope["exploratoryProjection"] = exploratory_projection

    categories = [
        {
            "id": category["id"],
            "title": category["title"],
            "counts": {
                result: sum(
                    feature["category"] == category["id"]
                    and feature["status"] == result
                    for feature in feature_results
                )
                for result in RESULT_ORDER
            },
        }
        for category in manifest["categories"]
    ]

    return {
        "formatVersion": 1,
        "manifestId": validated["manifestId"],
        "manifestVersion": validated["manifestVersion"],
        "featureManifestChecksum": manifest_checksum,
        "qualificationMatrixChecksum": matrix_checksum,
        "sourceKind": source_kind,
        "version": source["version"],
        "sourceCommit": source.get("sourceCommit"),
        "releaseSourceDigest": source["releaseSourceDigest"],
        "artifactDigest": source["artifactDigest"],
        "candidateAppDigest": source.get("candidateAppDigest"),
        "scope": scope,
        "summary": {
            "featureCount": len(feature_results),
            "requiredFeatureCount": len(required),
            "upstreamRiskCount": len(validated["upstreamRisks"]),
            "counts": {result: counts[result] for result in RESULT_ORDER},
            "requiredFeaturesSatisfied": required_satisfied,
            "releaseReady": source_kind == "releaseRecord" and required_satisfied,
        },
        "categories": categories,
        "features": feature_results,
        "runnerFailures": runner_failures,
        "staticControls": list(validated["staticControlById"].values()),
        **(
            {
                "upstreamRiskReview": {
                    "reviewedOn": validated["upstreamRiskReview"]["reviewedOn"],
                    "maximumAgeDays": validated["upstreamRiskReview"]["maximumAgeDays"],
                    "policy": validated["upstreamRiskReview"]["policy"],
                    "riskCount": len(validated["upstreamRisks"]),
                },
            }
            if validated["upstreamRiskReview"] is not None
            else {}
        ),
    }


def _markdown_escape(value: object) -> str:
    return str(value or "").replace("|", "\\|").replace("\n", " ")


def _short_digest(value: object) -> str:
    text = str(value or "unknown")
    return text if len(text) <= 12 else f"{text[:12]}…"


def _status_label(status: str) -> str:
    return {
        "pass": "PASS",
        "fail": "FAIL",
        "partial": "PARTIAL",
        "notRun": "NOT RUN",
        "blocked": "BLOCKED",
        "notApplicable": "N/A",
    }[status]


def _evidence_markdown(records: list[dict]) -> str:
    links = []
    for record in records:
        label = f"{record['scenario']} on {record['hardware']}"
        path = record.get("evidence")
        if path:
            links.append(f"[{_markdown_escape(label)}]({_markdown_escape(path)})")
        else:
            links.append(_markdown_escape(label))
    return ", ".join(links) if links else "—"


def _upstream_risks_markdown(records: list[dict]) -> str:
    links = [
        f"[{_markdown_escape(record['sourceProject'])} #{record['sourceIssue']}]"
        f"({_markdown_escape(record['sourceURL'])}) "
        f"({_markdown_escape(record['sourceStateAtReview'])} at review)"
        for record in records
    ]
    return ", ".join(links) if links else "—"


def render_markdown(checklist: dict, manifest: dict) -> str:
    summary = checklist["summary"]
    scope = checklist["scope"]
    lines = [
        f"# {manifest['title']}",
        "",
        f"**Scope result:** {'PASS' if summary['requiredFeaturesSatisfied'] else 'INCOMPLETE'}",
        "",
        "## Candidate",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| Version | `{_markdown_escape(checklist['version'])}` |",
        f"| Source commit | `{_markdown_escape(checklist.get('sourceCommit'))}` |",
        f"| Artifact digest | `{_markdown_escape(checklist['artifactDigest'])}` |",
        *(
            [
                f"| Candidate app digest | `{_markdown_escape(checklist['candidateAppDigest'])}` |"
            ]
            if checklist.get("candidateAppDigest")
            else []
        ),
        f"| Source digest | `{_markdown_escape(checklist['releaseSourceDigest'])}` |",
        f"| Manifest | `{_markdown_escape(checklist['manifestVersion'])}` (`{_short_digest(checklist['featureManifestChecksum'])}`) |",
        f"| Matrix | `{_short_digest(checklist['qualificationMatrixChecksum'])}` |",
        f"| Scope | {_markdown_escape(scope['kind'])}: {_markdown_escape(', '.join(scope['hardware']))} |",
    ]
    device = scope.get("device")
    if isinstance(device, dict):
        lines.extend(
            [
                f"| Device | {_markdown_escape(device.get('name') or device.get('marketingName'))} ({_markdown_escape(device.get('productType'))}) |",
                f"| OS | {_markdown_escape(device.get('osVersion'))} ({_markdown_escape(device.get('osBuild'))}, {_markdown_escape(device.get('osReleaseType'))}) |",
            ]
        )
    projection = scope.get("exploratoryProjection")
    if isinstance(projection, dict):
        lines.append(
            f"| Exploratory projection | {_markdown_escape(projection['deviceFamily'])} "
            f"OS {projection['deviceOSMajor']} shown against `{_markdown_escape(projection['matrixHardware'])}` "
            "for checklist visibility only; no qualification rows are accepted. |"
        )
    risk_review = checklist.get("upstreamRiskReview")
    if isinstance(risk_review, dict):
        lines.append(
            f"| Upstream risk review | {_markdown_escape(risk_review['reviewedOn'])}; "
            f"{risk_review['riskCount']} mapped risks |"
        )

    lines.extend(
        [
            "",
            "## Summary",
            "",
            "| Category | Pass | Fail | Partial | Not run | Blocked | N/A |",
            "|---|---:|---:|---:|---:|---:|---:|",
        ]
    )
    for category in checklist["categories"]:
        counts = category["counts"]
        lines.append(
            f"| {_markdown_escape(category['title'])} | {counts['pass']} | {counts['fail']} | "
            f"{counts['partial']} | {counts['notRun']} | {counts['blocked']} | "
            f"{counts['notApplicable']} |"
        )

    static_controls = checklist.get("staticControls", [])
    if static_controls:
        lines.extend(
            [
                "",
                "## Static release controls",
                "",
                "These candidate-specific commands enforce binary and source invariants that physical-device scenarios cannot prove. A listed command is an obligation, not evidence that it passed; the build and release gates must execute it successfully for the candidate.",
                "",
                "| Control | Contract | Candidate command |",
                "|---|---|---|",
            ]
        )
        for control in static_controls:
            lines.append(
                f"| {_markdown_escape(control['title'])} | "
                f"{_markdown_escape(control['description'])} | "
                f"`{_markdown_escape(control['command'])}` |"
            )

    features_by_category = {
        category["id"]: [
            feature
            for feature in checklist["features"]
            if feature["category"] == category["id"]
        ]
        for category in manifest["categories"]
    }
    for category in manifest["categories"]:
        lines.extend(
            [
                "",
                f"## {category['title']}",
                "",
                "| Status | Requirement | Feature | Upstream risks | Evidence | Detail |",
                "|---|---|---|---|---|---|",
            ]
        )
        for feature in features_by_category[category["id"]]:
            lines.append(
                f"| {_status_label(feature['status'])} | "
                f"{_markdown_escape(feature['releaseRequirement'])} | "
                f"{_markdown_escape(feature['title'])} | "
                f"{_upstream_risks_markdown(feature['upstreamRisks'])} | "
                f"{_evidence_markdown(feature['evidence'])} | "
                f"{_markdown_escape(feature['detail'])} |"
            )

    if checklist["runnerFailures"]:
        lines.extend(
            [
                "",
                "## Runner failures",
                "",
                "These failures occurred before or outside a materialized qualification row.",
                "",
                "| Scenario | Result | Exit code | Library errors |",
                "|---|---|---:|---:|",
            ]
        )
        for failure in checklist["runnerFailures"]:
            lines.append(
                f"| {_markdown_escape(failure['scenario'])} | "
                f"{_markdown_escape(failure['result'])} | "
                f"{_markdown_escape(failure['xcodebuildExitCode'])} | "
                f"{_markdown_escape(failure['libraryErrorCount'])} |"
            )
    lines.append("")
    return "\n".join(lines)


def render_html(checklist: dict, manifest: dict) -> str:
    def escaped(value: object) -> str:
        return html.escape(str(value or ""), quote=True)

    def evidence(records: list[dict]) -> str:
        values = []
        for record in records:
            label = escaped(f"{record['scenario']} on {record['hardware']}")
            path = record.get("evidence")
            if path:
                values.append(f'<a href="{escaped(path)}">{label}</a>')
            else:
                values.append(label)
        return ", ".join(values) if values else "&mdash;"

    def upstream_risks(records: list[dict]) -> str:
        values = [
            f'<a href="{escaped(record["sourceURL"])}">'
            f'{escaped(record["sourceProject"])} #{record["sourceIssue"]}</a> '
            f'({escaped(record["sourceStateAtReview"])} at review)'
            for record in records
        ]
        return ", ".join(values) if values else "&mdash;"

    summary = checklist["summary"]
    outcome_class = "pass" if summary["requiredFeaturesSatisfied"] else "incomplete"
    body = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        f"<title>{escaped(manifest['title'])}</title>",
        "<style>",
        "body{font:15px -apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;margin:2rem;max-width:1200px;color:#202124}",
        "table{border-collapse:collapse;width:100%;margin:1rem 0 2rem}th,td{border:1px solid #d8dce1;padding:.5rem;text-align:left;vertical-align:top}th{background:#f5f6f7}",
        ".status{font-weight:700}.status-pass{color:#157f3b}.status-fail,.status-blocked{color:#b42318}.status-partial,.status-notRun{color:#9a6700}.status-notApplicable{color:#667085}",
        ".outcome{padding:.75rem 1rem;border-radius:.4rem;font-weight:700}.outcome.pass{background:#e8f7ee;color:#157f3b}.outcome.incomplete{background:#fff1f0;color:#b42318}",
        "code{overflow-wrap:anywhere}small{color:#667085}",
        "</style></head><body>",
        f"<h1>{escaped(manifest['title'])}</h1>",
        f'<p class="outcome {outcome_class}">Scope result: '
        f"{'PASS' if summary['requiredFeaturesSatisfied'] else 'INCOMPLETE'}</p>",
        "<h2>Candidate</h2><table><tbody>",
    ]
    identity = (
        ("Version", checklist["version"]),
        ("Source commit", checklist.get("sourceCommit")),
        ("Artifact digest", checklist["artifactDigest"]),
        *(
            (("Candidate app digest", checklist["candidateAppDigest"]),)
            if checklist.get("candidateAppDigest")
            else ()
        ),
        ("Source digest", checklist["releaseSourceDigest"]),
        (
            "Feature manifest",
            f"{checklist['manifestVersion']} ({checklist['featureManifestChecksum']})",
        ),
        ("Qualification matrix", checklist["qualificationMatrixChecksum"]),
        (
            "Scope",
            f"{checklist['scope']['kind']}: {', '.join(checklist['scope']['hardware'])}",
        ),
    )
    for label, value in identity:
        body.append(
            f"<tr><th>{escaped(label)}</th><td><code>{escaped(value)}</code></td></tr>"
        )
    device = checklist["scope"].get("device")
    if isinstance(device, dict):
        body.append(
            f"<tr><th>Device</th><td>{escaped(device.get('name') or device.get('marketingName'))} "
            f"({escaped(device.get('productType'))})</td></tr>"
        )
        body.append(
            f"<tr><th>OS</th><td>{escaped(device.get('osVersion'))} "
            f"({escaped(device.get('osBuild'))}, {escaped(device.get('osReleaseType'))})</td></tr>"
        )
    projection = checklist["scope"].get("exploratoryProjection")
    if isinstance(projection, dict):
        body.append(
            f"<tr><th>Exploratory projection</th><td>{escaped(projection['deviceFamily'])} "
            f"OS {escaped(projection['deviceOSMajor'])} shown against "
            f"<code>{escaped(projection['matrixHardware'])}</code> for checklist visibility "
            "only; no qualification rows are accepted.</td></tr>"
        )
    risk_review = checklist.get("upstreamRiskReview")
    if isinstance(risk_review, dict):
        body.append(
            f"<tr><th>Upstream risk review</th><td>{escaped(risk_review['reviewedOn'])}; "
            f"{risk_review['riskCount']} mapped risks</td></tr>"
        )
    body.append("</tbody></table>")

    static_controls = checklist.get("staticControls", [])
    if static_controls:
        body.extend(
            [
                "<h2>Static release controls</h2>",
                "<p>These candidate-specific commands enforce binary and source invariants that physical-device scenarios cannot prove. A listed command is an obligation, not evidence that it passed; the build and release gates must execute it successfully for the candidate.</p>",
                "<table><thead><tr><th>Control</th><th>Contract</th><th>Candidate command</th></tr></thead><tbody>",
            ]
        )
        for control in static_controls:
            body.append(
                f"<tr><td><strong>{escaped(control['title'])}</strong></td>"
                f"<td>{escaped(control['description'])}</td>"
                f"<td><code>{escaped(control['command'])}</code></td></tr>"
            )
        body.append("</tbody></table>")

    by_category = {
        category["id"]: [
            feature
            for feature in checklist["features"]
            if feature["category"] == category["id"]
        ]
        for category in manifest["categories"]
    }
    for category in manifest["categories"]:
        body.extend(
            [
                f"<h2>{escaped(category['title'])}</h2>",
                "<table><thead><tr><th>Status</th><th>Requirement</th><th>Feature</th><th>Upstream risks</th><th>Evidence</th><th>Detail</th></tr></thead><tbody>",
            ]
        )
        for feature in by_category[category["id"]]:
            status = feature["status"]
            body.append(
                f'<tr><td class="status status-{escaped(status)}">{escaped(_status_label(status))}</td>'
                f"<td>{escaped(feature['releaseRequirement'])}</td>"
                f"<td><strong>{escaped(feature['title'])}</strong><br><small>{escaped(feature['description'])}</small></td>"
                f"<td>{upstream_risks(feature['upstreamRisks'])}</td>"
                f"<td>{evidence(feature['evidence'])}</td><td>{escaped(feature['detail'])}</td></tr>"
            )
        body.append("</tbody></table>")
    body.append("</body></html>\n")
    return "\n".join(body)


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as output:
        temporary = Path(output.name)
        output.write(content)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def write_outputs(output_dir: Path, checklist: dict, manifest: dict) -> None:
    json_content = json.dumps(checklist, indent=2, sort_keys=True) + "\n"
    _atomic_write(output_dir / "feature-checklist.json", json_content)
    _atomic_write(
        output_dir / "feature-checklist.md", render_markdown(checklist, manifest)
    )
    _atomic_write(
        output_dir / "feature-checklist.html", render_html(checklist, manifest)
    )


def main() -> int:
    script_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Validate and render the versioned physical-device feature checklist."
    )
    parser.add_argument(
        "--manifest", type=Path, default=script_directory / "feature-manifest-v1.json"
    )
    parser.add_argument("--matrix", type=Path, default=script_directory / "matrix.json")
    parser.add_argument(
        "--input", type=Path, help="Device report.json or assembled release record"
    )
    parser.add_argument(
        "--output-dir", type=Path, help="Destination for JSON, Markdown, and HTML"
    )
    parser.add_argument(
        "--require-complete",
        action="store_true",
        help="Exit 1 after evaluation unless every applicable required feature passed",
    )
    parser.add_argument(
        "--check-only",
        action="store_true",
        help="Evaluate an input without writing reports (for the stable release gate)",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate the manifest against the matrix without rendering a report",
    )
    parser.add_argument(
        "--enforce-canonical-policy",
        action="store_true",
        help="Require the immutable SwiftVLC release feature-ID obligations",
    )
    args = parser.parse_args()

    try:
        manifest = load_json(args.manifest, "feature manifest")
        matrix = load_json(args.matrix, "qualification matrix")
        validate_manifest(
            manifest,
            matrix,
            enforce_canonical_required_ids=(
                args.enforce_canonical_policy
                or manifest.get("id") == "swiftvlc-release-features"
            ),
        )
        if args.validate_only:
            if (
                args.input
                or args.output_dir
                or args.check_only
                or args.require_complete
            ):
                raise ChecklistError(
                    "--validate-only cannot be combined with report paths or completeness checks"
                )
            print(
                f"Validated {len(manifest['features'])} features against "
                f"{len(matrix['scenarios'])} qualification scenarios."
            )
            return 0
        if args.input is None:
            raise ChecklistError("--input is required when evaluating a checklist")
        if args.check_only and args.output_dir is not None:
            raise ChecklistError("--check-only cannot be combined with --output-dir")
        if not args.check_only and args.output_dir is None:
            raise ChecklistError("--output-dir is required when rendering")
        source = load_json(args.input, "qualification input")
        try:
            if isinstance(source.get("qualificationRows"), list):
                policy.validate_report(
                    args.input,
                    matrix,
                    strict_provenance=True,
                )
            elif isinstance(source.get("rows"), list):
                policy.validate_record(
                    args.input,
                    matrix,
                    strict_provenance=True,
                    require_complete=False,
                )
            else:
                raise policy.QualificationPolicyError(
                    "qualification input has neither qualificationRows nor rows"
                )
        except policy.QualificationPolicyError as error:
            raise ChecklistError(str(error)) from error
        checklist = build_checklist(
            source,
            manifest,
            matrix,
            manifest_checksum=file_checksum(args.manifest),
            matrix_checksum=file_checksum(args.matrix),
        )
        if not args.check_only:
            write_outputs(args.output_dir, checklist, manifest)
    except ChecklistError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    summary = checklist["summary"]
    print(
        f"Feature checklist: {summary['counts']['pass']} passed, "
        f"{summary['counts']['fail']} failed, {summary['counts']['notRun']} not run, "
        f"{summary['counts']['blocked']} blocked."
    )
    if args.require_complete and not summary["requiredFeaturesSatisfied"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
