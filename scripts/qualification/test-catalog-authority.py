#!/usr/bin/env python3
"""Create or enforce the reviewed exact iOS XCTest leaf-catalog authority."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

AUTHORITY = "swiftvlc-reviewed-ios-test-catalog-v1"
EXPECTED_KEYS = {
    "formatVersion",
    "authority",
    "testCatalogDigestAlgorithm",
    "testCatalogDigest",
    "testCatalogCount",
    "testIdentifiers",
}


class TestCatalogAuthorityError(ValueError):
    pass


def authority_record(catalog: dict) -> dict:
    try:
        canonical = policy.catalog_record(catalog.get("testIdentifiers", []))
    except policy.QualificationPolicyError as error:
        raise TestCatalogAuthorityError(str(error)) from error
    if catalog != canonical:
        raise TestCatalogAuthorityError("enumerated XCTest catalog is not canonical")
    return {
        "formatVersion": 1,
        "authority": AUTHORITY,
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": canonical["digest"],
        "testCatalogCount": canonical["testCount"],
        "testIdentifiers": canonical["testIdentifiers"],
    }


def validate_authority(value: dict) -> dict:
    if set(value) != EXPECTED_KEYS:
        raise TestCatalogAuthorityError("reviewed XCTest catalog schema mismatch")
    identifiers = value.get("testIdentifiers")
    try:
        canonical = policy.catalog_record(identifiers)
    except policy.QualificationPolicyError as error:
        raise TestCatalogAuthorityError(str(error)) from error
    expected = {
        "formatVersion": 1,
        "authority": AUTHORITY,
        "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
        "testCatalogDigest": canonical["digest"],
        "testCatalogCount": canonical["testCount"],
        "testIdentifiers": canonical["testIdentifiers"],
    }
    if value != expected:
        raise TestCatalogAuthorityError(
            "reviewed XCTest catalog is not canonical or its digest/count drifted"
        )
    return value


def verify_catalog(catalog: dict, authority: dict) -> dict:
    authority = validate_authority(authority)
    expected = authority_record(catalog)
    if authority != expected:
        missing = sorted(
            set(authority["testIdentifiers"]) - set(expected["testIdentifiers"])
        )
        extra = sorted(
            set(expected["testIdentifiers"]) - set(authority["testIdentifiers"])
        )
        raise TestCatalogAuthorityError(
            "enumerated XCTest catalog differs from reviewed authority; "
            f"missing={missing!r}, extra={extra!r}"
        )
    return authority


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    create = subparsers.add_parser("create")
    create.add_argument("--catalog", type=Path, required=True)
    create.add_argument("--output", type=Path, required=True)
    verify = subparsers.add_parser("verify")
    verify.add_argument("--catalog", type=Path, required=True)
    verify.add_argument("--authority", type=Path, required=True)
    args = parser.parse_args()
    try:
        catalog = policy.load_json(args.catalog, "enumerated XCTest catalog")
        if args.command == "create":
            result = authority_record(catalog)
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        else:
            result = verify_catalog(
                catalog,
                policy.load_json(args.authority, "reviewed XCTest catalog authority"),
            )
    except (
        OSError,
        policy.QualificationPolicyError,
        TestCatalogAuthorityError,
    ) as error:
        parser.error(str(error))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
