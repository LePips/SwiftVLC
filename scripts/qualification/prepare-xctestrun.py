#!/usr/bin/env python3
"""Inject UI-test environment and optionally use preinstalled device artifacts."""

from __future__ import annotations

import argparse
import plistlib
import re
from pathlib import Path

REMOVED_PATH_KEYS = {
    "DependentProductPaths",
    "TestBundlePath",
    "TestHostPath",
    "UITargetAppPath",
}
BUNDLE_IDENTIFIER_PATTERN = re.compile(
    r"^[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+$"
)


def validate_bundle_identifier(value: str) -> str:
    if BUNDLE_IDENTIFIER_PATTERN.fullmatch(value) is None:
        raise ValueError(f"invalid bundle identifier: {value!r}")
    return value


def transform(
    value: dict,
    environment: dict[str, str],
    *,
    use_destination_artifacts: bool = True,
    test_host_bundle_identifier: str,
    ui_target_app_bundle_identifier: str,
) -> dict:
    test_host_bundle_identifier = validate_bundle_identifier(
        test_host_bundle_identifier
    )
    ui_target_app_bundle_identifier = validate_bundle_identifier(
        ui_target_app_bundle_identifier
    )
    configurations = value.get("TestConfigurations", [])
    targets = [
        target for config in configurations for target in config.get("TestTargets", [])
    ]
    if not targets:
        raise ValueError("xctestrun contains no test targets")

    for target in targets:
        if not target.get("IsUITestBundle"):
            continue
        if use_destination_artifacts:
            for key in REMOVED_PATH_KEYS:
                target.pop(key, None)
            target.update(
                {
                    "UseDestinationArtifacts": True,
                    "TestHostBundleIdentifier": test_host_bundle_identifier,
                    "TestBundleDestinationRelativePath": "__TESTHOST__/PlugIns/iOSUITests.xctest",
                    "UITargetAppBundleIdentifier": ui_target_app_bundle_identifier,
                }
            )
        testing_environment = target.setdefault("TestingEnvironmentVariables", {})
        testing_environment.update(environment)
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument(
        "--environment", action="append", default=[], metavar="KEY=VALUE"
    )
    parser.add_argument(
        "--preserve-product-paths",
        action="store_true",
        help=(
            "inject environment without converting to preinstalled device artifacts; "
            "write the result beside the input so __TESTROOT__ still resolves"
        ),
    )
    parser.add_argument(
        "--test-host-bundle-identifier",
        required=True,
    )
    parser.add_argument(
        "--ui-target-app-bundle-identifier",
        required=True,
    )
    args = parser.parse_args()

    if (
        args.preserve_product_paths
        and args.input.resolve().parent != args.output.resolve().parent
    ):
        parser.error(
            "--preserve-product-paths output must be beside the input xctestrun"
        )

    environment: dict[str, str] = {}
    for item in args.environment:
        key, separator, value = item.partition("=")
        if not separator or not key:
            parser.error(f"invalid environment entry: {item!r}")
        environment[key] = value

    with args.input.open("rb") as source:
        value = plistlib.load(source)
    try:
        transformed = transform(
            value,
            environment,
            use_destination_artifacts=not args.preserve_product_paths,
            test_host_bundle_identifier=args.test_host_bundle_identifier,
            ui_target_app_bundle_identifier=args.ui_target_app_bundle_identifier,
        )
    except ValueError as error:
        parser.error(str(error))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as output:
        plistlib.dump(transformed, output, fmt=plistlib.FMT_BINARY, sort_keys=False)


if __name__ == "__main__":
    main()
