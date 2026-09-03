#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
sys.path.insert(0, str(SCRIPTS))
TOOL_PATH = SCRIPTS / "libvlc-manifest-set.py"
SPEC = importlib.util.spec_from_file_location("libvlc_manifest_set", TOOL_PATH)
assert SPEC is not None and SPEC.loader is not None
TOOL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TOOL)


class LibVLCManifestSetTests(unittest.TestCase):
    def write_inventory(
        self,
        directory: Path,
        marker: str | None = None,
        include_audio_session: bool = False,
    ) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        for filename, architectures in TOOL.EXPECTED_ARCHITECTURES.items():
            slice_name = filename.removesuffix(".txt")
            if slice_name.startswith(TOOL.feature_contract.CASTING_SLICE_PREFIXES):
                required = (
                    *TOOL.feature_contract.RENDERER_CORE_OBJECTS,
                    *TOOL.feature_contract.CHROMECAST_OBJECTS,
                )
            else:
                required = TOOL.feature_contract.RENDERER_CORE_OBJECTS
            if include_audio_session:
                required = (
                    *required,
                    TOOL.feature_contract.APPLE_AUDIO_SESSION_OBJECT,
                )
            rows = [
                f"{architecture} {member}"
                for architecture in architectures
                for member in required
            ]
            if marker is not None and filename == "ios-arm64.txt":
                rows.append(f"arm64 {marker}")
            directory.joinpath(filename).write_text(
                "".join(f"{row}\n" for row in sorted(rows)), encoding="utf-8"
            )

    def install_set(self, root: Path, source: Path) -> tuple[str, Path]:
        digest = TOOL.inventory_digest(source)
        destination = root / digest
        shutil.copytree(source, destination)
        return digest, destination

    def test_digest_is_deterministic_and_inventory_specific(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            first = root / "first"
            second = root / "second"
            changed = root / "changed"
            self.write_inventory(first)
            self.write_inventory(second)
            self.write_inventory(changed, "future_native_member.o")

            self.assertEqual(
                TOOL.inventory_digest(first), TOOL.inventory_digest(second)
            )
            self.assertNotEqual(
                TOOL.inventory_digest(first), TOOL.inventory_digest(changed)
            )
            self.assertRegex(TOOL.inventory_digest(first), r"^[0-9a-f]{64}$")

    def test_complete_cross_slice_audio_session_inventory_is_accepted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "inventory"
            self.write_inventory(inventory, include_audio_session=True)

            self.assertRegex(TOOL.inventory_digest(inventory), r"^[0-9a-f]{64}$")

    def test_selects_each_coexisting_inventory_without_a_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            root = workspace / "sets"
            root.mkdir()
            first = workspace / "first"
            second = workspace / "second"
            self.write_inventory(first)
            self.write_inventory(second, "future_native_member.o")
            first_digest, first_set = self.install_set(root, first)
            second_digest, second_set = self.install_set(root, second)

            self.assertEqual(TOOL.select_inventory(root, first_digest), first_set)
            self.assertEqual(TOOL.select_inventory(root, second_digest), second_set)
            with self.assertRaisesRegex(TOOL.InventoryError, "unknown libVLC"):
                TOOL.select_inventory(root, "0" * 64)

    def test_missing_and_extra_slices_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "inventory"
            self.write_inventory(inventory)
            (inventory / "ios-arm64.txt").unlink()
            with self.assertRaisesRegex(TOOL.InventoryError, "missing slices"):
                TOOL.inventory_digest(inventory)

            self.write_inventory(inventory)
            (inventory / "watchos-arm64.txt").write_text("arm64 member.o\n")
            with self.assertRaisesRegex(TOOL.InventoryError, "unexpected entries"):
                TOOL.inventory_digest(inventory)

    def test_noncanonical_rows_and_architectures_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "inventory"
            self.write_inventory(inventory)
            manifest = inventory / "ios-arm64.txt"
            manifest.write_text("arm64  member.o\n", encoding="utf-8")
            with self.assertRaisesRegex(TOOL.InventoryError, "canonical"):
                TOOL.inventory_digest(inventory)

            self.write_inventory(inventory)
            manifest.write_text("x86_64 member.o\n", encoding="utf-8")
            with self.assertRaisesRegex(TOOL.InventoryError, "architectures"):
                TOOL.inventory_digest(inventory)

    def test_partial_cross_slice_audio_session_inventory_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "inventory"
            self.write_inventory(inventory)
            manifest = inventory / "ios-arm64.txt"
            rows = manifest.read_text(encoding="utf-8").splitlines()
            rows.append(
                f"arm64 {TOOL.feature_contract.APPLE_AUDIO_SESSION_OBJECT}"
            )
            manifest.write_text(
                "".join(f"{row}\n" for row in sorted(rows)), encoding="utf-8"
            )

            with self.assertRaisesRegex(TOOL.InventoryError, "all 13"):
                TOOL.inventory_digest(inventory)

    def test_root_rejects_corruption_and_unaddressed_entries(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            root = workspace / "sets"
            root.mkdir()
            inventory = workspace / "inventory"
            self.write_inventory(inventory)
            _, installed = self.install_set(root, inventory)
            manifest = installed / "ios-arm64.txt"
            rows = manifest.read_text(encoding="utf-8").splitlines()
            rows.append("arm64 benign_but_unaddressed_member.o")
            manifest.write_text(
                "".join(f"{row}\n" for row in sorted(rows)), encoding="utf-8"
            )
            with self.assertRaisesRegex(TOOL.InventoryError, "digest is"):
                TOOL.validate_root(root)

            shutil.rmtree(installed)
            (root / "latest").mkdir()
            with self.assertRaisesRegex(TOOL.InventoryError, "directory name"):
                TOOL.validate_root(root)

    def test_symlinked_inventory_entry_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            workspace = Path(temporary)
            inventory = workspace / "inventory"
            self.write_inventory(inventory)
            target = inventory / "ios-arm64.txt"
            external = workspace / "external.txt"
            target.rename(external)
            target.symlink_to(external)

            with self.assertRaisesRegex(TOOL.InventoryError, "real file"):
                TOOL.inventory_digest(inventory)

    def test_checked_in_manifest_sets_are_self_addressed(self) -> None:
        root = REPO_ROOT / "scripts" / "libvlc-manifests" / "sets"
        self.assertGreaterEqual(TOOL.validate_root(root), 2)


if __name__ == "__main__":
    unittest.main()
