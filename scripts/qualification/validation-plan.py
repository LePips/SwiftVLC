#!/usr/bin/env python3
"""Create the retained physical-device scenario-driver plan."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy  # noqa: E402
from report_validation import atomic_write_json  # noqa: E402


SESSION_BINDING = re.compile(r"[0-9a-f]{64}")


def read_nonempty_lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines() if line.strip()]


def _device_scope_context(
    device_info: dict,
    matrix: dict,
    projected_hardware_row: str | None,
    *,
    full_scope: bool,
) -> tuple[dict, list[str], bool]:
    """Validate the selected-device fields that determine runner applicability."""

    mode = device_info.get("mode")
    device = device_info.get("selected")
    if mode not in {"qualification", "exploratory"} or not isinstance(device, dict):
        raise ValueError("device information has no selected validation device")
    eligible = device.get("qualificationEligible")
    if not isinstance(eligible, bool):
        raise ValueError("selected device qualification eligibility is not boolean")
    if (mode == "qualification") is not eligible:
        raise ValueError("selected device mode and qualification eligibility disagree")

    matching = device.get("matchingHardwareRows")
    if (
        not isinstance(matching, list)
        or any(not isinstance(row, str) or not row for row in matching)
        or len(set(matching)) != len(matching)
    ):
        raise ValueError("selected device matching hardware rows are invalid")
    family = device.get("deviceFamily")
    os_major = device.get("osMajor")
    release_type = device.get("osReleaseType")
    if (
        family not in {"iPhone", "iPad"}
        or type(os_major) is not int
        or os_major <= 0
        or release_type not in {"stable", "beta", "unknown"}
    ):
        raise ValueError("selected device family, OS, or release identity is invalid")

    hardware_rows = matrix.get("hardware")
    if not isinstance(hardware_rows, list):
        raise ValueError("qualification matrix has no hardware rows")
    expected_matching = [
        row.get("id")
        for row in hardware_rows
        if isinstance(row, dict)
        and row.get("deviceFamily") == family
        and row.get("osMajor") == os_major
    ]
    if (
        any(not isinstance(row, str) or not row for row in expected_matching)
        or matching != expected_matching
    ):
        raise ValueError(
            "selected device matching hardware rows do not reconcile with its identity"
        )
    expected_eligible = release_type == "stable" and bool(matching)
    if eligible is not expected_eligible:
        raise ValueError(
            "selected device qualification eligibility does not reconcile with its identity"
        )

    can_run_current = "iphone-current" in matching
    if projected_hardware_row is not None:
        projected_rows = [
            row
            for row in hardware_rows
            if isinstance(row, dict) and row.get("id") == projected_hardware_row
        ]
        if (
            not isinstance(projected_hardware_row, str)
            or not projected_hardware_row
            or len(projected_rows) != 1
            or matching
            or mode != "exploratory"
            or eligible
            or family != "iPhone"
            or projected_rows[0].get("deviceFamily") != family
            or type(projected_rows[0].get("osMajor")) is not int
            or os_major <= projected_rows[0]["osMajor"]
            or (full_scope and projected_hardware_row != "iphone-current")
        ):
            raise ValueError(
                "projected hardware row does not reconcile with the selected device"
            )
        can_run_current = True
    return device, matching, can_run_current


def _validate_full_scope(
    requested: list[str], selected: list[str], *, can_run_current: bool
) -> None:
    canonical = policy.REQUIRED_RELEASE_RUNNER_SCENARIO_ORDER
    if tuple(requested) != canonical:
        raise ValueError(
            "full validation requested drivers differ from immutable release "
            "coverage or order"
        )
    applicable = canonical
    if not can_run_current:
        applicable = tuple(
            driver
            for driver in canonical
            if driver not in policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
        )
    if tuple(selected) != applicable:
        raise ValueError(
            "full validation selected drivers differ from immutable device-applicable "
            "release coverage or order"
        )


def build_plan(
    device_info: dict,
    matrix: dict,
    requested: list[str],
    selected: list[str],
    *,
    started_at_utc: str,
    orchestrator_session_binding: str,
    orchestrator_started_at_utc: str,
    projected_hardware_row: str | None = None,
    report_only: bool = False,
    selection_scope: str = "partial",
) -> dict:
    if selection_scope not in {"full", "partial"}:
        raise ValueError(f"invalid validation selection scope: {selection_scope}")
    if report_only and selection_scope == "full":
        raise ValueError("a report-only validation plan cannot claim full scope")
    if SESSION_BINDING.fullmatch(orchestrator_session_binding) is None:
        raise ValueError(
            "orchestrator session binding must be exactly 64 lowercase hex characters"
        )
    for description, drivers in (("requested", requested), ("selected", selected)):
        if (
            not drivers
            or any(not isinstance(driver, str) or not driver for driver in drivers)
            or len(set(drivers)) != len(drivers)
        ):
            raise ValueError(
                f"{description} scenario drivers must be a non-empty unique list"
            )
    requested_set = set(requested)
    if any(driver not in requested_set for driver in selected):
        raise ValueError("selected scenario drivers must be requested")
    if selection_scope == "full":
        try:
            policy.validate_release_matrix_contract(matrix)
        except policy.QualificationPolicyError as error:
            raise ValueError(str(error)) from error
    device, matching_hardware, can_run_current = _device_scope_context(
        device_info,
        matrix,
        projected_hardware_row,
        full_scope=selection_scope == "full",
    )
    if selection_scope == "full":
        _validate_full_scope(
            requested,
            selected,
            can_run_current=can_run_current,
        )
    selected_set = set(selected)
    effective_hardware = set(matching_hardware)
    if projected_hardware_row:
        effective_hardware.add(projected_hardware_row)

    scenario_hardware = {
        scenario["id"]: set(scenario.get("hardware", []))
        for scenario in matrix.get("scenarios", [])
    }
    runner_contracts = {
        contract["id"]: contract for contract in matrix.get("runnerContracts", [])
    }
    planned_rows: list[str] = []
    if not report_only:
        for driver in selected:
            contract = runner_contracts.get(driver, {})
            for output in contract.get("outputs", []):
                row = output.get("scenario")
                required_hardware = scenario_hardware.get(row, set())
                if (
                    isinstance(row, str)
                    and row not in planned_rows
                    and (
                        not required_hardware
                        or bool(required_hardware.intersection(effective_hardware))
                    )
                ):
                    planned_rows.append(row)

    return {
        "formatVersion": 2,
        "startedAtUTC": started_at_utc,
        "mode": device_info["mode"],
        "reportOnly": report_only,
        "selectionScope": selection_scope,
        "orchestratorSessionBinding": orchestrator_session_binding,
        "orchestratorStartedAtUTC": orchestrator_started_at_utc,
        "qualificationEligibleEnvironment": device["qualificationEligible"],
        "matrixHardwareRows": list(matching_hardware),
        "projectedHardwareRow": projected_hardware_row,
        # These are potential outputs of the selected drivers, not evidence.
        # Only validated qualificationRows in report.json represent completed
        # release-matrix rows.
        "matrixScenarioOutputsPlanned": planned_rows,
        "requestedScenarioDrivers": requested,
        "selectedScenarioDrivers": selected,
        "skippedScenarioDrivers": [
            {
                "scenario": scenario,
                "reason": "not applicable to the selected hardware row",
            }
            for scenario in requested
            if scenario not in selected_set
        ],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-info", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--requested", type=Path, required=True)
    parser.add_argument("--selected", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--started-at-utc", required=True)
    parser.add_argument("--orchestrator-session-binding", required=True)
    parser.add_argument("--orchestrator-started-at-utc", required=True)
    parser.add_argument("--projected-hardware-row")
    parser.add_argument("--report-only", action="store_true")
    parser.add_argument(
        "--selection-scope", choices=("full", "partial"), required=True
    )
    args = parser.parse_args()

    value = build_plan(
        json.loads(args.device_info.read_text()),
        json.loads(args.matrix.read_text()),
        read_nonempty_lines(args.requested),
        read_nonempty_lines(args.selected),
        started_at_utc=args.started_at_utc,
        orchestrator_session_binding=args.orchestrator_session_binding,
        orchestrator_started_at_utc=args.orchestrator_started_at_utc,
        projected_hardware_row=args.projected_hardware_row,
        report_only=args.report_only,
        selection_scope=args.selection_scope,
    )
    atomic_write_json(args.output, value)


if __name__ == "__main__":
    main()
