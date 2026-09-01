#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = REPO_ROOT / "scripts" / "validate_libvlc_feature_contract.py"
SPEC = importlib.util.spec_from_file_location("libvlc_feature_contract", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class LibVLCFeatureContractTests(unittest.TestCase):
    def validate(self, slice_name: str, rows: list[tuple[str, str]]) -> list[str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "members.txt"
            path.write_text(
                "".join(f"{arch} {member}\n" for arch, member in rows),
                encoding="utf-8",
            )
            return VALIDATOR.validate_contract(slice_name, path)

    def casting_rows(self, *architectures: str) -> list[tuple[str, str]]:
        return [
            (arch, member)
            for arch in architectures
            for member in (
                *VALIDATOR.RENDERER_CORE_OBJECTS,
                *VALIDATOR.CHROMECAST_OBJECTS,
            )
        ]

    def test_casting_objects_are_required_for_every_architecture(self) -> None:
        rows = self.casting_rows("arm64", "x86_64")
        missing = ("x86_64", VALIDATOR.CHROMECAST_OBJECTS[-1])
        rows.remove(missing)

        errors = self.validate("ios-arm64_x86_64-simulator", rows)

        self.assertEqual(len(errors), 1)
        self.assertIn("ios-arm64_x86_64-simulator/x86_64", errors[0])
        self.assertIn(missing[1], errors[0])

    def test_casting_contract_accepts_complete_slice(self) -> None:
        errors = self.validate(
            "macos-arm64_x86_64", self.casting_rows("arm64", "x86_64")
        )
        self.assertEqual(errors, [])

    def test_required_object_must_not_be_duplicated(self) -> None:
        rows = self.casting_rows("arm64")
        rows.append(("arm64", VALIDATOR.RENDERER_CORE_OBJECTS[0]))

        errors = self.validate("ios-arm64", rows)

        self.assertEqual(len(errors), 1)
        self.assertIn("occurs 2 times", errors[0])

    def test_tvos_keeps_renderer_api_without_chromecast(self) -> None:
        rows = [("arm64", member) for member in VALIDATOR.RENDERER_CORE_OBJECTS]
        self.assertEqual(self.validate("tvos-arm64", rows), [])

    def test_tvos_rejects_every_chromecast_stack_object(self) -> None:
        rows = [("arm64", member) for member in VALIDATOR.RENDERER_CORE_OBJECTS]
        rows.append(("arm64", "libstream_out_chromecast_plugin_la-cast.o"))
        rows.append(("arm64", "future_chromecast_helper.o"))

        errors = self.validate("tvos-arm64", rows)

        self.assertEqual(len(errors), 2)
        self.assertTrue(all("forbidden on tvOS" in error for error in errors))

    def test_unknown_platform_requires_an_explicit_policy(self) -> None:
        rows = [("arm64", member) for member in VALIDATOR.RENDERER_CORE_OBJECTS]
        errors = self.validate("watchos-arm64", rows)
        self.assertEqual(len(errors), 1)
        self.assertIn("unsupported slice", errors[0])

    def test_checked_in_manifests_satisfy_the_contract(self) -> None:
        manifest_directory = REPO_ROOT / "scripts" / "libvlc-manifests"
        manifests = sorted(manifest_directory.glob("*.txt"))
        self.assertGreater(len(manifests), 0)

        failures: list[str] = []
        for manifest in manifests:
            failures.extend(
                VALIDATOR.validate_contract(manifest.stem, manifest)
            )
        self.assertEqual(failures, [])


if __name__ == "__main__":
    unittest.main()
