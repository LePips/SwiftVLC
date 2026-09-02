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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy
from report_validation import atomic_write_json

NON_STABLE_RELEASE_TYPES = ("beta", "seed", "internal", "development", "preview")


def release_type(properties: dict) -> str:
    declared = str(properties.get("releaseType", "")).strip().lower()
    build = str(properties.get("osBuildUpdate", ""))
    declared_signal = (
        "beta"
        if any(marker in declared for marker in NON_STABLE_RELEASE_TYPES)
        else "stable" if declared in {"release", "stable", "customer"} else "unknown"
    )
    build_signal = "unknown"
    if re.fullmatch(r"\d+[A-Z]\d+", build):
        build_signal = "stable"
    # Public Rapid Security Responses append a lowercase revision to a much
    # longer numeric component (for example 20E772520a). Seed builds use the
    # ordinary four/five-digit component followed by a lowercase suffix.
    if re.fullmatch(r"\d+[A-Z]\d{6,}[a-z]+", build):
        build_signal = "stable"
    elif re.fullmatch(r"\d+[A-Z]\d+[a-z]+", build):
        build_signal = "beta"
    signals = {
        signal for signal in (declared_signal, build_signal) if signal != "unknown"
    }
    if len(signals) > 1:
        return "unknown"
    return next(iter(signals), "unknown")


def load_devices(path: Path | None) -> list[dict]:
    if path is not None:
        payload = policy.load_json(path, "saved devicectl response")
    else:
        with tempfile.NamedTemporaryFile(suffix=".json") as output:
            subprocess.run(
                ["xcrun", "devicectl", "list", "devices", "--json-output", output.name],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            payload = json.load(output)
    return payload.get("result", {}).get("devices", [])


def load_device_details(selector: str, timeout_seconds: int = 8) -> dict | None:
    """Actively connect to a paired CoreDevice and return its live snapshot.

    `devicectl list devices` can report a network-paired iPhone as dormant even
    though the human-readable state is "available (paired)". The details
    command establishes the developer tunnel and is therefore the authority
    for DDI availability immediately before a qualification run.
    """

    with tempfile.NamedTemporaryFile(suffix=".json") as output:
        try:
            completed = subprocess.run(
                [
                    "xcrun",
                    "devicectl",
                    "device",
                    "info",
                    "details",
                    "--device",
                    selector,
                    "--timeout",
                    str(timeout_seconds),
                    "--json-output",
                    output.name,
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=timeout_seconds + 5,
            )
        except subprocess.TimeoutExpired:
            return None
        if completed.returncode != 0:
            return None
        try:
            payload = policy.load_json(Path(output.name), "live devicectl response")
        except (policy.QualificationPolicyError, OSError):
            return None
    details = payload.get("result")
    if not isinstance(details, dict) or not details.get("identifier"):
        return None
    return details


def replace_device_snapshot(devices: list[dict], details: dict) -> list[dict]:
    """Replace a dormant list snapshot with live details by stable identity."""

    identifier = details.get("identifier")
    replaced = False
    refreshed: list[dict] = []
    for device in devices:
        if device.get("identifier") == identifier:
            refreshed.append(details)
            replaced = True
        else:
            refreshed.append(device)
    if not replaced:
        refreshed.append(details)
    return refreshed


def refresh_live_devices(devices: list[dict], selector: str | None) -> list[dict]:
    """Probe explicit selection, or every paired physical iOS candidate."""

    selectors: list[str]
    if selector:
        selectors = [selector]
    else:
        selectors = []
        for device in devices:
            connection = device.get("connectionProperties", {})
            properties = device.get("deviceProperties", {})
            hardware = device.get("hardwareProperties", {})
            already_connected = (
                connection.get("tunnelState") == "connected"
                and properties.get("ddiServicesAvailable") is True
            )
            if (
                device.get("identifier")
                and hardware.get("reality") == "physical"
                and hardware.get("platform") == "iOS"
                and connection.get("pairingState") == "paired"
                and not already_connected
            ):
                selectors.append(str(device["identifier"]))
    for probe_selector in selectors:
        details = load_device_details(probe_selector)
        if details is not None:
            devices = replace_device_snapshot(devices, details)
    return devices


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
        "tunnelIPAddress": connection.get("tunnelIPAddress"),
        "connected": connected,
        "matchingHardwareRows": matching_rows,
        "qualificationEligible": connected
        and os_release_type == "stable"
        and bool(matching_rows),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--matrix", type=Path, required=True)
    parser.add_argument(
        "--input", type=Path, help="Read saved devicectl JSON (for tests)"
    )
    parser.add_argument("--device", help="Select by CoreDevice id, UDID, name, or ECID")
    parser.add_argument("--require-stable", action="store_true")
    parser.add_argument(
        "--output", type=Path, help="Atomically write the normalized JSON here"
    )
    args = parser.parse_args()

    try:
        matrix = policy.load_json(args.matrix, "qualification matrix")
        policy.validate_release_matrix_contract(matrix)
    except policy.QualificationPolicyError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2
    raw_devices = load_devices(args.input)
    if args.input is None:
        raw_devices = refresh_live_devices(raw_devices, args.device)
    devices = [normalize(device, matrix.get("hardware", [])) for device in raw_devices]
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

    selected = next(
        (device for device in connected if device["qualificationEligible"]), None
    )
    if selected is None and connected and not args.require_stable:
        selected = connected[0]

    result = {
        "selected": selected,
        "connected": connected,
        "allPhysicalIOSDevices": devices,
        "mode": (
            "qualification"
            if selected and selected["qualificationEligible"]
            else "exploratory" if selected else "unavailable"
        ),
    }
    if args.output is not None:
        atomic_write_json(args.output, result)
    else:
        json.dump(result, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")

    if selected is None:
        return 2
    if args.require_stable and not selected["qualificationEligible"]:
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
