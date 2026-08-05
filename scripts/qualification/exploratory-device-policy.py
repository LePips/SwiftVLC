#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

EXPLORATORY_HARDWARE_ID = "exploratory-future-ios"


def evidence_hardware_id(device_info: dict, matrix: dict) -> str | None:
    selected = device_info.get("selected")
    if device_info.get("mode") != "exploratory" or not isinstance(selected, dict):
        return None
    if selected.get("deviceFamily") != "iPhone":
        return None

    current_rows = [
        row
        for row in matrix.get("hardware", [])
        if row.get("id") == "iphone-current"
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

    device_info = json.loads(arguments.device_info.read_text())
    matrix = json.loads(arguments.matrix.read_text())
    hardware_id = evidence_hardware_id(device_info, matrix)
    if hardware_id is None:
        return 1
    print(hardware_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
