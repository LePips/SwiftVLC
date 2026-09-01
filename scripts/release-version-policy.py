#!/usr/bin/env python3
"""Classify a release version without relying on GitHub release metadata.

Swift Package Manager decides whether a version is stable from the git tag,
not from GitHub's ``prerelease`` checkbox.  Keep this parser deliberately
small and strict so release.sh cannot route a stable-looking tag around the
physical-device qualification gate.
"""

from __future__ import annotations

import argparse
import json
import re


CORE_NUMBER = r"(?:0|[1-9][0-9]*)"
NUMERIC_IDENTIFIER = r"(?:0|[1-9][0-9]*)"
NON_NUMERIC_IDENTIFIER = r"(?:[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
PRERELEASE_IDENTIFIER = rf"(?:{NUMERIC_IDENTIFIER}|{NON_NUMERIC_IDENTIFIER})"
SEMVER = re.compile(
    rf"^(?P<major>{CORE_NUMBER})\."
    rf"(?P<minor>{CORE_NUMBER})\."
    rf"(?P<patch>{CORE_NUMBER})"
    rf"(?:-(?P<prerelease>{PRERELEASE_IDENTIFIER}"
    rf"(?:\.{PRERELEASE_IDENTIFIER})*))?$"
)


class VersionPolicyError(ValueError):
    pass


def classify(version: str) -> dict[str, object]:
    match = SEMVER.fullmatch(version)
    if match is None:
        raise VersionPolicyError(
            "version must be strict SemVer without build metadata, for example "
            "1.1.0 or 1.1.0-beta.1"
        )
    is_prerelease = match.group("prerelease") is not None
    return {
        "version": version,
        "tag": f"v{version}",
        "kind": "prerelease" if is_prerelease else "stable",
        "isPrerelease": is_prerelease,
        "requiresQualification": not is_prerelease,
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Validate SemVer and classify stable versus prerelease routing."
    )
    parser.add_argument("version")
    parser.add_argument(
        "--field",
        choices=("version", "tag", "kind", "isPrerelease", "requiresQualification"),
    )
    args = parser.parse_args()

    try:
        policy = classify(args.version)
    except VersionPolicyError as error:
        parser.error(str(error))

    if args.field:
        value = policy[args.field]
        if isinstance(value, bool):
            print("true" if value else "false")
        else:
            print(value)
    else:
        print(json.dumps(policy, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
