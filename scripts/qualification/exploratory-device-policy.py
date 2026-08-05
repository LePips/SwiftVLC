#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path


def permits_current_only(device_info: dict, matrix: dict) -> bool:
    selected = device_info.get("selected")
    if device_info.get("mode") != "exploratory" or not isinstance(selected, dict):
        return False
    if selected.get("deviceFamily") != "iPhone":
        return False

    current_rows = [
        row
        for row in matrix.get("hardware", [])
        if row.get("id") == "iphone-current"
    ]
    if len(current_rows) != 1:
        return False

    selected_major = selected.get("osMajor")
    current_major = current_rows[0].get("osMajor")
    return (
        isinstance(selected_major, int)
        and isinstance(current_major, int)
        and selected_major > current_major
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device-info", type=Path, required=True)
    parser.add_argument("--matrix", type=Path, required=True)
    arguments = parser.parse_args()

    device_info = json.loads(arguments.device_info.read_text())
    matrix = json.loads(arguments.matrix.read_text())
    return 0 if permits_current_only(device_info, matrix) else 1


if __name__ == "__main__":
    raise SystemExit(main())
