#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
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

    def test_audio_session_object_is_coherent_across_architectures(self) -> None:
        rows = self.casting_rows("arm64", "x86_64")
        rows.extend(
            (
                arch,
                VALIDATOR.APPLE_AUDIO_SESSION_OBJECT,
            )
            for arch in ("arm64", "x86_64")
        )

        self.assertEqual(
            self.validate("ios-arm64_x86_64-simulator", rows), []
        )

    def test_partial_audio_session_object_is_rejected(self) -> None:
        rows = self.casting_rows("arm64", "x86_64")
        rows.append(("arm64", VALIDATOR.APPLE_AUDIO_SESSION_OBJECT))

        errors = self.validate("ios-arm64_x86_64-simulator", rows)

        self.assertEqual(len(errors), 1)
        self.assertIn("x86_64", errors[0])
        self.assertIn("expected exactly once", errors[0])

    def test_duplicate_audio_session_object_is_rejected(self) -> None:
        rows = self.casting_rows("arm64")
        rows.extend(
            [("arm64", VALIDATOR.APPLE_AUDIO_SESSION_OBJECT)] * 2
        )

        errors = self.validate("ios-arm64", rows)

        self.assertEqual(len(errors), 1)
        self.assertIn("occurs 2 times", errors[0])

    def test_unknown_platform_requires_an_explicit_policy(self) -> None:
        rows = [("arm64", member) for member in VALIDATOR.RENDERER_CORE_OBJECTS]
        errors = self.validate("watchos-arm64", rows)
        self.assertEqual(len(errors), 1)
        self.assertIn("unsupported slice", errors[0])

    def test_checked_in_manifests_satisfy_the_contract(self) -> None:
        manifest_directory = REPO_ROOT / "scripts" / "libvlc-manifests" / "sets"
        manifests = sorted(manifest_directory.glob("*/*.txt"))
        self.assertGreater(len(manifests), 0)

        failures: list[str] = []
        for manifest in manifests:
            failures.extend(VALIDATOR.validate_contract(manifest.stem, manifest))
        self.assertEqual(failures, [])

    def test_checkout_local_clean_uses_descriptor_safe_helper(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            build_script = scripts / "build-libvlc.sh"
            build_script.write_bytes(
                (REPO_ROOT / "scripts" / "build-libvlc.sh").read_bytes()
            )
            helper = scripts / "detach-managed-build-directory.py"
            helper.write_bytes(
                (
                    REPO_ROOT / "scripts" / "detach-managed-build-directory.py"
                ).read_bytes()
            )
            subprocess.run(
                ["git", "init", "-q"],
                cwd=root,
                check=True,
                capture_output=True,
                text=True,
            )
            build_directory = scripts / ".build-libvlc"
            (build_directory / "vlc").mkdir(parents=True)
            (build_directory / "vlc" / "stale").write_text("stale")
            (build_directory / ".swiftvlc-managed-libvlc-build-v1").write_text(
                "SwiftVLC managed libVLC build directory v1\n"
            )

            fake_bin = root / "bin"
            fake_bin.mkdir()
            state = root / "unsafe-rm-was-called"
            (fake_bin / "rm").write_text("""#!/bin/bash
set -eu
: > "$SWIFTVLC_RM_TEST_STATE"
echo "unsafe pathname rm was called" >&2
exit 99
""")
            (fake_bin / "rm").chmod(0o755)
            environment = dict(
                os.environ,
                MAKEFLAGS="-j1",
                PATH=f"{fake_bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                SWIFTVLC_RM_TEST_STATE=str(state),
                TERM="dumb",
            )

            result = subprocess.run(
                ["bash", str(build_script), "--clean"],
                text=True,
                capture_output=True,
                env=environment,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(state.exists())
            self.assertFalse(build_directory.exists())


if __name__ == "__main__":
    unittest.main()
