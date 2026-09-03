#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

EXPLORATORY_HARDWARE_ID = policy.EXPLORATORY_FUTURE_IOS_HARDWARE_ID


def evidence_hardware_id(device_info: dict, matrix: dict) -> str | None:
    selected = device_info.get("selected")
    if device_info.get("mode") != "exploratory" or not isinstance(selected, dict):
        return None
    if selected.get("deviceFamily") != "iPhone":
        return None

    current_rows = [
        row for row in matrix.get("hardware", []) if row.get("id") == "iphone-current"
    ]
    if len(current_rows) != 1:
        return None

    selected_major = selected.get("osMajor")
    current_major = current_rows[0].get("osMajor")
    permitted = (
        isinstance(selected_major, int)
        and isinstance(current_major, int)
        and selected_major > current_major
    )
    return EXPLORATORY_HARDWARE_ID if permitted else None


def permits_current_only(device_info: dict, matrix: dict) -> bool:
    return evidence_hardware_id(device_info, matrix) is not None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device-info", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    arguments = parser.parse_args()

    try:
        device_info = policy.load_json(arguments.device_info, "device information")
        matrix = policy.load_json(arguments.matrix, "qualification matrix")
    except policy.QualificationPolicyError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    hardware_id = evidence_hardware_id(device_info, matrix)
    if hardware_id is None:
        return 1
    print(hardware_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
