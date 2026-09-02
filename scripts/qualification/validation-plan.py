#!/usr/bin/env python3
"""Create the retained physical-device scenario-driver plan."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from report_validation import atomic_write_json  # noqa: E402


def read_nonempty_lines(path: Path) -> list[str]:
    return [line.strip() for line in path.read_text().splitlines() if line.strip()]


def build_plan(
    device_info: dict,
    matrix: dict,
    requested: list[str],
    selected: list[str],
    *,
    started_at_utc: str,
    projected_hardware_row: str | None = None,
    report_only: bool = False,
    selection_scope: str = "partial",
) -> dict:
    if selection_scope not in {"full", "partial"}:
        raise ValueError(f"invalid validation selection scope: {selection_scope}")
    if report_only and selection_scope == "full":
        raise ValueError("a report-only validation plan cannot claim full scope")
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
    device = device_info["selected"]
    selected_set = set(selected)
    effective_hardware = set(device.get("matchingHardwareRows", []))
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
        "qualificationEligibleEnvironment": device["qualificationEligible"],
        "matrixHardwareRows": list(device.get("matchingHardwareRows", [])),
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
        projected_hardware_row=args.projected_hardware_row,
        report_only=args.report_only,
        selection_scope=args.selection_scope,
    )
    atomic_write_json(args.output, value)


if __name__ == "__main__":
    main()
