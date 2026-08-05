#!/usr/bin/env python3
"""Resolve the Mac endpoint on the connected CoreDevice IPv6 tunnel."""

from __future__ import annotations

import argparse
import ipaddress
import re
import subprocess


def matching_host_address(device_address: str, ifconfig_output: str) -> str:
    try:
        device = ipaddress.IPv6Address(device_address)
    except ipaddress.AddressValueError as error:
        raise ValueError(f"invalid device tunnel IPv6 address: {device_address}") from error
    network = ipaddress.IPv6Network((device, 64), strict=False)
    candidates = []
    for raw in re.findall(r"\binet6\s+([0-9A-Fa-f:]+)(?:%\S+)?", ifconfig_output):
        try:
            candidate = ipaddress.IPv6Address(raw)
        except ipaddress.AddressValueError:
            continue
        if candidate != device and candidate in network and not candidate.is_link_local:
            candidates.append(candidate)
    unique = sorted(set(candidates), key=int)
    if len(unique) != 1:
        raise ValueError(
            f"expected one Mac address in CoreDevice tunnel {network}, found {len(unique)}"
        )
    return str(unique[0])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device-address", required=True)
    parser.add_argument("--ifconfig-output")
    args = parser.parse_args()
    if args.ifconfig_output is None:
        output = subprocess.run(
            ["ifconfig"], check=True, capture_output=True, text=True
        ).stdout
    else:
        output = args.ifconfig_output
    try:
        print(matching_host_address(args.device_address, output))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
