#!/usr/bin/env python3
"""Capture pure canonical JSON from xcodebuild while retaining stderr separately."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stderr", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("xcodebuild command is empty")
    args.stderr.parent.mkdir(parents=True, exist_ok=True)
    with args.stderr.open("wb") as errors:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=errors)
    if result.returncode != 0:
        return result.returncode
    try:
        value = json.loads(result.stdout)
    except (UnicodeError, json.JSONDecodeError) as error:
        print(f"Error: xcodebuild did not emit pure JSON: {error}", file=sys.stderr)
        return 2
    if not isinstance(value, list) or not value:
        print("Error: xcodebuild build-settings JSON is empty", file=sys.stderr)
        return 2
    json.dump(value, sys.stdout, sort_keys=True, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
