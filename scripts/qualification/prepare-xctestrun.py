#!/usr/bin/env python3
"""Inject UI-test environment and optionally use preinstalled device artifacts."""

from __future__ import annotations

import argparse
import plistlib
from pathlib import Path


REMOVED_PATH_KEYS = {
    "DependentProductPaths",
    "TestBundlePath",
    "TestHostPath",
    "UITargetAppPath",
}


def transform(
    value: dict,
    environment: dict[str, str],
    *,
    use_destination_artifacts: bool = True,
) -> dict:
    configurations = value.get("TestConfigurations", [])
    targets = [target for config in configurations for target in config.get("TestTargets", [])]
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
                    "TestHostBundleIdentifier": "com.swiftvlc.showcase.ios.uitests.xctrunner",
                    "TestBundleDestinationRelativePath": "__TESTHOST__/PlugIns/iOSUITests.xctest",
                    "UITargetAppBundleIdentifier": "com.swiftvlc.showcase.ios",
                }
            )
        testing_environment = target.setdefault("TestingEnvironmentVariables", {})
        testing_environment.update(environment)
    return value


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--environment", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument(
        "--preserve-product-paths",
        action="store_true",
        help=(
            "inject environment without converting to preinstalled device artifacts; "
            "write the result beside the input so __TESTROOT__ still resolves"
        ),
    )
    args = parser.parse_args()

    if (
        args.preserve_product_paths
        and args.input.resolve().parent != args.output.resolve().parent
    ):
        parser.error("--preserve-product-paths output must be beside the input xctestrun")

    environment: dict[str, str] = {}
    for item in args.environment:
        key, separator, value = item.partition("=")
        if not separator or not key:
            parser.error(f"invalid environment entry: {item!r}")
        environment[key] = value

    with args.input.open("rb") as source:
        value = plistlib.load(source)
    transformed = transform(
        value,
        environment,
        use_destination_artifacts=not args.preserve_product_paths,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as output:
        plistlib.dump(transformed, output, fmt=plistlib.FMT_BINARY, sort_keys=False)


if __name__ == "__main__":
    main()
