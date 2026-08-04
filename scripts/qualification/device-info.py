#!/usr/bin/env python3
"""Discover physical iOS devices and classify release-matrix eligibility."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path


NON_STABLE_RELEASE_TYPES = ("beta", "seed", "internal", "development", "preview")


def release_type(properties: dict) -> str:
    declared = str(properties.get("releaseType", "")).strip().lower()
    if any(marker in declared for marker in NON_STABLE_RELEASE_TYPES):
        return "beta"
    if declared in {"release", "stable", "customer"}:
        return "stable"

    build = str(properties.get("osBuildUpdate", ""))
    if re.fullmatch(r"\d+[A-Z]\d+", build):
        return "stable"
    # Public Rapid Security Responses append a lowercase revision to a much
    # longer numeric component (for example 20E772520a). Seed builds use the
    # ordinary four/five-digit component followed by a lowercase suffix.
    if re.fullmatch(r"\d+[A-Z]\d{6,}[a-z]+", build):
        return "stable"
    if re.fullmatch(r"\d+[A-Z]\d+[a-z]+", build):
        return "beta"
    return "unknown"


def load_devices(path: Path | None) -> list[dict]:
    if path is not None:
        payload = json.loads(path.read_text())
    else:
        with tempfile.NamedTemporaryFile(suffix=".json") as output:
            subprocess.run(
                ["xcrun", "devicectl", "list", "devices", "--json-output", output.name],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            payload = json.load(output)
    return payload.get("result", {}).get("devices", [])


def normalize(device: dict, hardware_rows: list[dict]) -> dict:
    connection = device.get("connectionProperties", {})
    properties = device.get("deviceProperties", {})
    hardware = device.get("hardwareProperties", {})
    version = str(properties.get("osVersionNumber", ""))
    try:
        major = int(version.split(".", 1)[0])
    except ValueError:
        major = None

    family = hardware.get("deviceType")
    connected = (
        hardware.get("reality") == "physical"
        and hardware.get("platform") == "iOS"
        and connection.get("tunnelState") == "connected"
        and properties.get("ddiServicesAvailable") is True
        and properties.get("developerModeStatus") == "enabled"
    )
    os_release_type = release_type(properties)
    matching_rows = [
        row["id"]
        for row in hardware_rows
        if row.get("deviceFamily") == family and row.get("osMajor") == major
    ]
    ecid = hardware.get("ecid")
    return {
        "id": device.get("identifier"),
        "udid": hardware.get("udid"),
        "ecid": ecid,
        "ecidHex": f"0x{ecid:X}" if isinstance(ecid, int) else None,
        "name": properties.get("name"),
        "marketingName": hardware.get("marketingName"),
        "deviceFamily": family,
        "productType": hardware.get("productType"),
        "osVersion": version,
        "osMajor": major,
        "osBuild": properties.get("osBuildUpdate"),
        "osReleaseType": os_release_type,
        "transport": connection.get("transportType"),
        "connected": connected,
        "matchingHardwareRows": matching_rows,
        "qualificationEligible": connected and os_release_type == "stable" and bool(matching_rows),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument("--input", type=Path, help="Read saved devicectl JSON (for tests)")
    parser.add_argument("--device", help="Select by CoreDevice id, UDID, name, or ECID")
    parser.add_argument("--require-stable", action="store_true")
    args = parser.parse_args()

    matrix = json.loads(args.matrix.read_text())
    devices = [normalize(device, matrix.get("hardware", [])) for device in load_devices(args.input)]
    connected = [device for device in devices if device["connected"]]
    if args.device:
        needle = args.device.lower()
        connected = [
            device
            for device in connected
            if needle
            in {
                str(device.get("id", "")).lower(),
                str(device.get("udid", "")).lower(),
                str(device.get("name", "")).lower(),
                str(device.get("ecid", "")).lower(),
                str(device.get("ecidHex", "")).lower(),
            }
        ]

    selected = next((device for device in connected if device["qualificationEligible"]), None)
    if selected is None and connected and not args.require_stable:
        selected = connected[0]

    result = {
        "selected": selected,
        "connected": connected,
        "allPhysicalIOSDevices": devices,
        "mode": (
            "qualification"
            if selected and selected["qualificationEligible"]
            else "exploratory"
            if selected
            else "unavailable"
        ),
    }
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    sys.stdout.write("\n")

    if selected is None:
        return 2
    if args.require_stable and not selected["qualificationEligible"]:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
