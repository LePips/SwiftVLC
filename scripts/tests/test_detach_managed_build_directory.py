import errno
import importlib.util
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from typing import Optional
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "detach-managed-build-directory.py"
MODULE_NAME = "swiftvlc_detach_managed_build_directory"
SPEC = importlib.util.spec_from_file_location(MODULE_NAME, SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
HELPER = importlib.util.module_from_spec(SPEC)
sys.modules[MODULE_NAME] = HELPER
SPEC.loader.exec_module(HELPER)


class ManagedBuildDirectoryTests(unittest.TestCase):
    child_name = "swiftvlc-libvlc-build"
    quarantine_name = ".swiftvlc-libvlc-build.removing-test"
    marker_name = ".swiftvlc-managed-libvlc-build-v1"
    marker_content = "SwiftVLC managed libVLC build directory v1"
    binding_name = ".swiftvlc-source-binding"
    binding_content = "invocation=test"
    lock_token_name = ".swiftvlc-lock-generation-v1"
    lock_token_content = "SwiftVLC lock generation test"

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.child = self.root / self.child_name
        self.marker = self.child / self.marker_name

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def initialize(self, *, require_new: bool = False) -> None:
        HELPER.initialize(
            str(self.root),
            self.child_name,
            self.marker_name,
            self.marker_content,
            require_new,
        )

    def clean(self) -> None:
        HELPER.clean(
            str(self.root),
            self.child_name,
            self.quarantine_name,
            self.marker_name,
            self.marker_content,
        )

    def test_empty_lock_is_scoped_to_inherited_root_descriptor(self) -> None:
        anchor = self.root / "lock-anchor"
        moved = self.root / "lock-anchor-original"
        anchor.mkdir()
        root_fd = os.open(anchor, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            HELPER.acquire_generation_lock(
                root_fd,
                "native.lock",
                self.lock_token_name,
                self.lock_token_content,
            )
            anchor.rename(moved)
            anchor.mkdir()
            (anchor / "native.lock").mkdir()

            HELPER.release_generation_lock(
                root_fd,
                "native.lock",
                self.lock_token_name,
                self.lock_token_content,
            )
        finally:
            os.close(root_fd)

        self.assertFalse((moved / "native.lock").exists())
        self.assertTrue((anchor / "native.lock").is_dir())

    def test_empty_lock_acquire_preserves_contended_directory(self) -> None:
        lock = self.root / "native.lock"
        lock.mkdir()
        (lock / "owner-data").write_text("preserve\n")
        root_fd = os.open(self.root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            with self.assertRaisesRegex(HELPER.SafetyError, "lock already exists"):
                HELPER.acquire_generation_lock(
                    root_fd,
                    "native.lock",
                    self.lock_token_name,
                    self.lock_token_content,
                )
        finally:
            os.close(root_fd)

        self.assertEqual((lock / "owner-data").read_text(), "preserve\n")

    def test_empty_lock_release_refuses_populated_lock(self) -> None:
        root_fd = os.open(self.root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            HELPER.acquire_generation_lock(
                root_fd,
                "native.lock",
                self.lock_token_name,
                self.lock_token_content,
            )
            (self.root / "native.lock" / "foreign-data").write_text("preserve\n")
            with self.assertRaisesRegex(HELPER.SafetyError, "unexpectedly populated"):
                HELPER.release_generation_lock(
                    root_fd,
                    "native.lock",
                    self.lock_token_name,
                    self.lock_token_content,
                )
        finally:
            os.close(root_fd)

        self.assertEqual(
            (self.root / "native.lock" / "foreign-data").read_text(),
            "preserve\n",
        )

    def test_generation_lock_release_never_removes_a_successor_lock(self) -> None:
        root_fd = os.open(self.root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            HELPER.acquire_generation_lock(
                root_fd,
                "native.lock",
                self.lock_token_name,
                self.lock_token_content,
            )
            (self.root / "native.lock").rename(self.root / "first-generation")
            successor_content = "SwiftVLC lock generation next"
            HELPER.acquire_generation_lock(
                root_fd,
                "native.lock",
                self.lock_token_name,
                successor_content,
            )

            with self.assertRaisesRegex(
                HELPER.SafetyError, "belongs to a different invocation"
            ):
                HELPER.release_generation_lock(
                    root_fd,
                    "native.lock",
                    self.lock_token_name,
                    self.lock_token_content,
                )
        finally:
            os.close(root_fd)

        self.assertEqual(
            (self.root / "native.lock" / self.lock_token_name).read_text(),
            "SwiftVLC lock generation next\n",
        )
        self.assertTrue((self.root / "first-generation").is_dir())

    def test_generation_lock_release_rmdir_window_preserves_successor(self) -> None:
        root_fd = os.open(self.root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        original_rmdir = HELPER.os.rmdir
        race_triggered = False
        successor_content = "SwiftVLC lock generation next"

        def replace_immediately_before_rmdir(path, *args, **kwargs):
            nonlocal race_triggered
            if (
                not race_triggered
                and path == "native.lock"
                and kwargs.get("dir_fd") is not None
                and HELPER.same_identity(
                    os.fstat(kwargs["dir_fd"]), os.fstat(root_fd)
                )
            ):
                race_triggered = True
                (self.root / "native.lock").rename(
                    self.root / "first-generation"
                )
                HELPER.acquire_generation_lock(
                    root_fd,
                    "native.lock",
                    self.lock_token_name,
                    successor_content,
                )
            return original_rmdir(path, *args, **kwargs)

        try:
            HELPER.acquire_generation_lock(
                root_fd,
                "native.lock",
                self.lock_token_name,
                self.lock_token_content,
            )
            with mock.patch.object(
                HELPER.os, "rmdir", side_effect=replace_immediately_before_rmdir
            ):
                with self.assertRaisesRegex(
                    HELPER.SafetyError, "cannot retire generation lock"
                ):
                    HELPER.release_generation_lock(
                        root_fd,
                        "native.lock",
                        self.lock_token_name,
                        self.lock_token_content,
                    )
        finally:
            os.close(root_fd)

        self.assertTrue(race_triggered)
        self.assertEqual(
            (self.root / "native.lock" / self.lock_token_name).read_text(),
            successor_content + "\n",
        )
        self.assertEqual(
            (self.root / "first-generation" / self.lock_token_name).read_text(),
            self.lock_token_content + "\n",
        )

    @staticmethod
    def create_file_at(parent_fd: int, name: str, payload: bytes) -> None:
        descriptor = os.open(
            name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=parent_fd,
        )
        try:
            os.write(descriptor, payload)
        finally:
            os.close(descriptor)

    def test_initialize_publishes_exact_marker_and_require_new_rejects_reuse(
        self,
    ) -> None:
        self.initialize()

        self.assertEqual(
            self.marker.read_bytes(), (self.marker_content + "\n").encode()
        )
        self.initialize()
        with self.assertRaisesRegex(HELPER.SafetyError, "new directory was required"):
            self.initialize(require_new=True)

        self.assertEqual(
            sorted(path.name for path in self.root.iterdir()), [self.child_name]
        )

    def test_initialize_never_blesses_unowned_publish_winner(self) -> None:
        original_rename = HELPER.rename_noreplace
        raced = False

        def publish_race(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            nonlocal raced
            self.assertFalse(raced)
            raced = True
            os.mkdir(destination_name, 0o700, dir_fd=destination_parent_fd)
            self.create_file_at(
                destination_parent_fd,
                f"{destination_name}/do-not-delete",
                b"unrelated data\n",
            )
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(HELPER, "rename_noreplace", side_effect=publish_race):
            with self.assertRaises(HELPER.SafetyError):
                self.initialize()

        self.assertTrue(raced)
        self.assertEqual((self.child / "do-not-delete").read_text(), "unrelated data\n")
        self.assertFalse(self.marker.exists())
        self.assertFalse(self.marker.is_symlink())
        self.assertFalse(
            any(
                path.name.startswith(HELPER.STAGING_PREFIX)
                for path in self.root.iterdir()
            )
        )

    def test_bind_exclusively_binds_existing_directory_without_initializing(
        self,
    ) -> None:
        self.child.mkdir()
        preserved = self.child / "preserved.txt"
        preserved.write_text("source\n")

        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
            create=True,
        )

        binding = self.child / self.binding_name
        self.assertEqual(binding.read_bytes(), b"invocation=test\n")
        self.assertEqual(preserved.read_text(), "source\n")
        self.assertFalse(self.marker.exists())
        with self.assertRaisesRegex(HELPER.SafetyError, "exclusively create"):
            HELPER.bind(
                str(self.root),
                self.child_name,
                self.binding_name,
                self.binding_content,
            )
        self.assertEqual(binding.read_bytes(), b"invocation=test\n")

    def test_bind_create_atomically_publishes_binding_only_directory(self) -> None:
        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
            create=True,
        )

        self.assertEqual(
            sorted(path.name for path in self.child.iterdir()), [self.binding_name]
        )
        self.assertEqual(
            (self.child / self.binding_name).read_bytes(), b"invocation=test\n"
        )
        self.assertEqual(stat.S_IMODE(self.child.stat().st_mode), 0o700)
        self.assertFalse(
            any(
                path.name.startswith(HELPER.STAGING_PREFIX)
                for path in self.root.iterdir()
            )
        )

    def test_bind_create_preserves_racing_publish_winner(self) -> None:
        original_rename = HELPER.rename_noreplace
        raced = False

        def publish_race(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            nonlocal raced
            self.assertFalse(raced)
            raced = True
            os.mkdir(destination_name, 0o700, dir_fd=destination_parent_fd)
            self.create_file_at(
                destination_parent_fd,
                f"{destination_name}/do-not-delete",
                b"unrelated\n",
            )
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(HELPER, "rename_noreplace", side_effect=publish_race):
            with self.assertRaisesRegex(
                HELPER.SafetyError, "cannot atomically publish binding child"
            ):
                HELPER.bind(
                    str(self.root),
                    self.child_name,
                    self.binding_name,
                    self.binding_content,
                    create=True,
                )

        self.assertTrue(raced)
        self.assertEqual((self.child / "do-not-delete").read_text(), "unrelated\n")
        self.assertFalse((self.child / self.binding_name).exists())
        self.assertFalse(
            any(
                path.name.startswith(HELPER.STAGING_PREFIX)
                for path in self.root.iterdir()
            )
        )

    def test_bind_rejects_absent_file_and_symlink_children(self) -> None:
        with self.assertRaises(HELPER.SafetyError):
            HELPER.bind(
                str(self.root),
                "absent",
                self.binding_name,
                self.binding_content,
            )

        file_child = self.root / "file-child"
        file_child.write_text("preserve\n")
        with self.assertRaisesRegex(HELPER.SafetyError, "is not a directory"):
            HELPER.bind(
                str(self.root),
                file_child.name,
                self.binding_name,
                self.binding_content,
                create=True,
            )
        self.assertEqual(file_child.read_text(), "preserve\n")

        outside = self.root / "outside"
        outside.mkdir()
        symlink_child = self.root / "symlink-child"
        symlink_child.symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(HELPER.SafetyError, "is not a directory"):
            HELPER.bind(
                str(self.root),
                symlink_child.name,
                self.binding_name,
                self.binding_content,
                create=True,
            )
        self.assertFalse((outside / self.binding_name).exists())

    def test_bind_rejects_filesystem_boundary_before_creating_binding(self) -> None:
        self.child.mkdir()

        def filesystem_identifier(_: int, description: str) -> int:
            return 202 if description.startswith("binding child") else 101

        with mock.patch.object(
            HELPER,
            "filesystem_identifier",
            side_effect=filesystem_identifier,
        ):
            with self.assertRaisesRegex(
                HELPER.SafetyError, "device/filesystem identity boundary"
            ):
                HELPER.bind(
                    str(self.root),
                    self.child_name,
                    self.binding_name,
                    self.binding_content,
                )
        self.assertFalse((self.child / self.binding_name).exists())

    def test_bind_rejects_public_child_swap_at_final_revalidation(self) -> None:
        self.child.mkdir()
        (self.child / "original.txt").write_text("original\n")
        saved_name = "original-source-child"
        original_revalidate = HELPER.require_named_directory_identity
        raced = False

        def revalidate_with_swap(
            parent_fd: int,
            name: str,
            metadata: os.stat_result,
            description: str,
        ) -> None:
            nonlocal raced
            try:
                os.stat(
                    f"{name}/{self.binding_name}",
                    dir_fd=parent_fd,
                    follow_symlinks=False,
                )
                binding_exists = True
            except FileNotFoundError:
                binding_exists = False
            if description.startswith("binding child") and binding_exists and not raced:
                raced = True
                os.rename(
                    name,
                    saved_name,
                    src_dir_fd=parent_fd,
                    dst_dir_fd=parent_fd,
                )
                os.mkdir(name, 0o700, dir_fd=parent_fd)
                self.create_file_at(
                    parent_fd,
                    f"{name}/do-not-delete",
                    b"replacement\n",
                )
            original_revalidate(parent_fd, name, metadata, description)

        with mock.patch.object(
            HELPER,
            "require_named_directory_identity",
            side_effect=revalidate_with_swap,
        ):
            with self.assertRaisesRegex(HELPER.SafetyError, "identity changed"):
                HELPER.bind(
                    str(self.root),
                    self.child_name,
                    self.binding_name,
                    self.binding_content,
                )

        self.assertTrue(raced)
        moved_child = self.root / saved_name
        self.assertEqual((moved_child / "original.txt").read_text(), "original\n")
        self.assertEqual(
            (moved_child / self.binding_name).read_bytes(), b"invocation=test\n"
        )
        self.assertEqual((self.child / "do-not-delete").read_text(), "replacement\n")
        self.assertFalse((self.child / self.binding_name).exists())

    def test_publish_moves_entries_in_order_and_retires_bound_child(self) -> None:
        self.child.mkdir()
        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
        )
        artifact = self.child / "libvlc.xcframework"
        artifact.mkdir()
        (artifact / "binary").write_bytes(b"artifact")
        (self.child / "macho-report.json").write_text("report\n")
        (self.child / "provenance.json").write_text("provenance\n")
        original_rename = HELPER.rename_noreplace
        publication_order: list[str] = []

        def record_rename(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            publication_order.append(source_name)
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(HELPER, "rename_noreplace", side_effect=record_rename):
            HELPER.publish(
                str(self.root),
                self.child_name,
                self.binding_name,
                self.binding_content,
                [
                    "libvlc.xcframework",
                    "macho-report.json",
                    "provenance.json",
                ],
            )

        self.assertEqual(
            publication_order,
            ["libvlc.xcframework", "macho-report.json", "provenance.json"],
        )
        self.assertFalse(self.child.exists())
        self.assertEqual(
            (self.root / "libvlc.xcframework" / "binary").read_bytes(), b"artifact"
        )
        self.assertEqual((self.root / "macho-report.json").read_text(), "report\n")
        self.assertEqual((self.root / "provenance.json").read_text(), "provenance\n")

    def test_publish_destination_race_never_replaces_winner(self) -> None:
        self.child.mkdir()
        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
        )
        (self.child / "artifact").mkdir()
        original_rename = HELPER.rename_noreplace

        def destination_race(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            os.mkdir(destination_name, 0o700, dir_fd=destination_parent_fd)
            self.create_file_at(
                destination_parent_fd,
                f"{destination_name}/winner",
                b"unrelated\n",
            )
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(
            HELPER, "rename_noreplace", side_effect=destination_race
        ):
            with self.assertRaisesRegex(
                HELPER.SafetyError, "cannot atomically publish entry artifact"
            ):
                HELPER.publish(
                    str(self.root),
                    self.child_name,
                    self.binding_name,
                    self.binding_content,
                    ["artifact"],
                )

        self.assertEqual((self.root / "artifact" / "winner").read_text(), "unrelated\n")
        self.assertTrue((self.child / "artifact").is_dir())
        self.assertEqual(
            (self.child / self.binding_name).read_bytes(), b"invocation=test\n"
        )

    def test_publish_public_child_swap_preserves_opened_child(self) -> None:
        self.child.mkdir()
        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
        )
        (self.child / "artifact").write_text("artifact\n")
        original_rename = HELPER.rename_noreplace
        saved_name = "original-publication-child"

        def child_swap(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            os.rename(
                self.child_name,
                saved_name,
                src_dir_fd=destination_parent_fd,
                dst_dir_fd=destination_parent_fd,
            )
            os.mkdir(self.child_name, 0o700, dir_fd=destination_parent_fd)
            self.create_file_at(
                destination_parent_fd,
                f"{self.child_name}/do-not-delete",
                b"replacement\n",
            )
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(HELPER, "rename_noreplace", side_effect=child_swap):
            with self.assertRaisesRegex(
                HELPER.SafetyError,
                "publication stopped after moving: artifact.*no rollback",
            ):
                HELPER.publish(
                    str(self.root),
                    self.child_name,
                    self.binding_name,
                    self.binding_content,
                    ["artifact"],
                )

        self.assertEqual((self.root / "artifact").read_text(), "artifact\n")
        self.assertEqual(
            (self.root / saved_name / self.binding_name).read_bytes(),
            b"invocation=test\n",
        )
        self.assertEqual((self.child / "do-not-delete").read_text(), "replacement\n")

    def test_publish_rejects_unexpected_entry_before_any_move(self) -> None:
        self.child.mkdir()
        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
        )
        (self.child / "artifact").write_text("artifact\n")
        (self.child / "unexpected").write_text("preserve\n")

        with self.assertRaisesRegex(
            HELPER.SafetyError, "unexpected or missing entries"
        ):
            HELPER.publish(
                str(self.root),
                self.child_name,
                self.binding_name,
                self.binding_content,
                ["artifact"],
            )

        self.assertFalse((self.root / "artifact").exists())
        self.assertEqual((self.child / "artifact").read_text(), "artifact\n")
        self.assertEqual((self.child / "unexpected").read_text(), "preserve\n")
        with self.assertRaisesRegex(HELPER.SafetyError, "duplicate publication entry"):
            HELPER.publish(
                str(self.root),
                self.child_name,
                self.binding_name,
                self.binding_content,
                ["artifact", "artifact"],
            )
        with self.assertRaisesRegex(HELPER.SafetyError, "non-special path component"):
            HELPER.publish(
                str(self.root),
                self.child_name,
                self.binding_name,
                self.binding_content,
                ["."],
            )

    def test_publish_partial_failure_keeps_published_and_remaining_state(self) -> None:
        self.child.mkdir()
        HELPER.bind(
            str(self.root),
            self.child_name,
            self.binding_name,
            self.binding_content,
        )
        (self.child / "artifact").write_text("artifact\n")
        (self.child / "macho-report").write_text("original report\n")
        (self.child / "provenance").write_text("original provenance\n")
        original_rename = HELPER.rename_noreplace

        def fail_second_move(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            if source_name == "macho-report":
                self.create_file_at(
                    destination_parent_fd,
                    destination_name,
                    b"racing report\n",
                )
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(
            HELPER, "rename_noreplace", side_effect=fail_second_move
        ):
            with self.assertRaisesRegex(
                HELPER.SafetyError,
                "publication stopped after moving: artifact.*no rollback",
            ):
                HELPER.publish(
                    str(self.root),
                    self.child_name,
                    self.binding_name,
                    self.binding_content,
                    ["artifact", "macho-report", "provenance"],
                )

        self.assertEqual((self.root / "artifact").read_text(), "artifact\n")
        self.assertEqual((self.root / "macho-report").read_text(), "racing report\n")
        self.assertFalse((self.root / "provenance").exists())
        self.assertEqual((self.child / "macho-report").read_text(), "original report\n")
        self.assertEqual(
            (self.child / "provenance").read_text(), "original provenance\n"
        )
        self.assertEqual(
            (self.child / self.binding_name).read_bytes(), b"invocation=test\n"
        )

    def test_clean_removes_nested_tree_without_following_symlink(self) -> None:
        self.initialize()
        nested = self.child / "unicode-ı" / "deeper"
        nested.mkdir(parents=True)
        (nested / "data.bin").write_bytes(b"managed")
        os.mkfifo(self.child / "named-pipe")
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "preserve.txt").write_text("outside\n")
        (nested / "outside-link").symlink_to(outside, target_is_directory=True)

        self.clean()

        self.assertFalse(self.child.exists())
        self.assertFalse((self.root / self.quarantine_name).exists())
        self.assertEqual((outside / "preserve.txt").read_text(), "outside\n")

    def test_clean_fails_closed_when_marker_is_a_symlink(self) -> None:
        self.child.mkdir()
        outside_marker = self.root / "outside-marker"
        outside_marker.write_text(self.marker_content + "\n")
        self.marker.symlink_to(outside_marker)
        (self.child / "preserve.txt").write_text("managed\n")

        with self.assertRaises(HELPER.SafetyError):
            self.clean()

        self.assertEqual((self.child / "preserve.txt").read_text(), "managed\n")
        self.assertEqual(outside_marker.read_text(), self.marker_content + "\n")

    def test_detach_detects_swap_in_final_public_name_window(self) -> None:
        self.initialize()
        (self.child / "original.txt").write_text("original\n")
        original_rename = HELPER.rename_noreplace
        saved_name = "original-managed-child"
        raced = False

        def detach_race(
            source_parent_fd: int,
            source_name: str,
            destination_parent_fd: int,
            destination_name: str,
        ) -> None:
            nonlocal raced
            self.assertFalse(raced)
            raced = True
            os.rename(
                source_name,
                saved_name,
                src_dir_fd=source_parent_fd,
                dst_dir_fd=source_parent_fd,
            )
            os.mkdir(source_name, 0o700, dir_fd=source_parent_fd)
            self.create_file_at(
                source_parent_fd,
                f"{source_name}/do-not-delete",
                b"replacement\n",
            )
            self.create_file_at(
                source_parent_fd,
                f"{source_name}/{self.marker_name}",
                (self.marker_content + "\n").encode(),
            )
            original_rename(
                source_parent_fd,
                source_name,
                destination_parent_fd,
                destination_name,
            )

        with mock.patch.object(HELPER, "rename_noreplace", side_effect=detach_race):
            with self.assertRaisesRegex(
                HELPER.SafetyError,
                "detached payload is not the verified managed child.*preserved at",
            ):
                self.clean()

        self.assertTrue(raced)
        self.assertEqual(
            (self.root / saved_name / "original.txt").read_text(), "original\n"
        )
        self.assertEqual(
            (
                self.root / self.quarantine_name / "payload" / "do-not-delete"
            ).read_text(),
            "replacement\n",
        )

    def test_quarantine_path_swap_cannot_redirect_recursive_cleanup(self) -> None:
        self.initialize()
        (self.child / "managed.txt").write_text("managed\n")
        context = HELPER.detach_open(
            str(self.root),
            self.child_name,
            self.quarantine_name,
            self.marker_name,
            self.marker_content,
        )
        moved_quarantine = self.root / "moved-quarantine"
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "preserve.txt").write_text("outside\n")
        (self.root / self.quarantine_name).rename(moved_quarantine)
        (self.root / self.quarantine_name).symlink_to(outside, target_is_directory=True)
        try:
            with self.assertRaises(HELPER.SafetyError):
                HELPER.remove_detached_context(context)
        finally:
            context.close()

        self.assertEqual((outside / "preserve.txt").read_text(), "outside\n")
        self.assertEqual(
            (moved_quarantine / "payload" / "managed.txt").read_text(), "managed\n"
        )

    def test_nested_directory_swap_is_rejected_before_descent(self) -> None:
        parent = self.root / "parent"
        target = parent / "target"
        target.mkdir(parents=True)
        (target / "original.txt").write_text("original\n")
        parent_fd = os.open(parent, HELPER.directory_open_flags())
        original_open = HELPER.open_named_directory
        raced = False

        def open_race(
            supplied_parent_fd: int, name: str, description: str
        ) -> tuple[int, os.stat_result]:
            nonlocal raced
            if name == "target" and not raced:
                raced = True
                os.rename(
                    name,
                    "target-original",
                    src_dir_fd=supplied_parent_fd,
                    dst_dir_fd=supplied_parent_fd,
                )
                os.mkdir(name, 0o700, dir_fd=supplied_parent_fd)
                self.create_file_at(
                    supplied_parent_fd,
                    f"{name}/do-not-delete",
                    b"replacement\n",
                )
            return original_open(supplied_parent_fd, name, description)

        try:
            with mock.patch.object(
                HELPER, "open_named_directory", side_effect=open_race
            ):
                with self.assertRaisesRegex(
                    HELPER.SafetyError, "identity changed before recursive descent"
                ):
                    HELPER.remove_entry(
                        parent_fd,
                        "target",
                        os.fstat(parent_fd).st_dev,
                        "target",
                    )
        finally:
            os.close(parent_fd)

        self.assertTrue(raced)
        self.assertEqual(
            (parent / "target-original" / "original.txt").read_text(), "original\n"
        )
        self.assertEqual(
            (parent / "target" / "do-not-delete").read_text(), "replacement\n"
        )

    def test_opened_directory_rejects_distinct_filesystem_id_on_same_device(
        self,
    ) -> None:
        child = self.root / "child"
        child.mkdir()
        parent_fd = os.open(self.root, HELPER.directory_open_flags())
        self.assertEqual(os.fstat(parent_fd).st_dev, child.stat().st_dev)

        def distinct_filesystems(directory_fd: int) -> SimpleNamespace:
            identifier = 101 if directory_fd == parent_fd else 202
            return SimpleNamespace(f_fsid=identifier)

        try:
            with mock.patch.object(
                HELPER.os, "fstatvfs", side_effect=distinct_filesystems
            ):
                with self.assertRaisesRegex(
                    HELPER.SafetyError,
                    "device/filesystem identity boundary.*parent filesystem=101.*"
                    "child filesystem=202",
                ):
                    HELPER.open_named_directory(parent_fd, "child", "mounted child")
        finally:
            os.close(parent_fd)

    def test_non_darwin_without_filesystem_id_falls_back_to_device_identity(
        self,
    ) -> None:
        child = self.root / "child"
        child.mkdir()
        parent_fd = os.open(self.root, HELPER.directory_open_flags())
        child_fd = -1
        try:
            with mock.patch.object(HELPER.sys, "platform", "linux"), mock.patch.object(
                HELPER.os, "fstatvfs", None
            ):
                self.assertIsNone(
                    HELPER.filesystem_identifier(parent_fd, "portable parent")
                )
            with mock.patch.object(HELPER.sys, "platform", "linux"), mock.patch.object(
                HELPER.os,
                "fstatvfs",
                return_value=SimpleNamespace(),
            ):
                child_fd, metadata = HELPER.open_named_directory(
                    parent_fd, "child", "portable child"
                )
            self.assertEqual(os.fstat(parent_fd).st_dev, metadata.st_dev)
        finally:
            if child_fd >= 0:
                os.close(child_fd)
            os.close(parent_fd)

    def test_darwin_requires_exposed_filesystem_id(self) -> None:
        directory_fd = os.open(self.root, HELPER.directory_open_flags())
        try:
            with mock.patch.object(HELPER.sys, "platform", "darwin"), mock.patch.object(
                HELPER.os,
                "fstatvfs",
                return_value=SimpleNamespace(),
            ):
                with self.assertRaisesRegex(
                    HELPER.SafetyError, "f_fsid is unavailable"
                ):
                    HELPER.filesystem_identifier(directory_fd, "test directory")
        finally:
            os.close(directory_fd)

    def test_final_removal_repopulation_restores_marker_and_retries(self) -> None:
        self.initialize()
        (self.child / "managed.txt").write_text("managed\n")
        original_rmdir = HELPER.os.rmdir
        injected = False

        def rmdir_with_late_writer(name: str, *, dir_fd: Optional[int] = None) -> None:
            nonlocal injected
            if name == HELPER.PAYLOAD_NAME and not injected:
                self.assertIsNotNone(dir_fd)
                injected = True
                payload_fd = os.open(name, HELPER.directory_open_flags(), dir_fd=dir_fd)
                try:
                    self.create_file_at(payload_fd, "late-file", b"late\n")
                finally:
                    os.close(payload_fd)
                raise OSError(errno.ENOTEMPTY, "simulated late writer")
            if dir_fd is None:
                original_rmdir(name)
            else:
                original_rmdir(name, dir_fd=dir_fd)

        with mock.patch.object(
            HELPER.os, "rmdir", side_effect=rmdir_with_late_writer
        ), mock.patch.object(HELPER.time, "sleep"):
            self.clean()

        self.assertTrue(injected)
        self.assertFalse(self.child.exists())
        self.assertFalse((self.root / self.quarantine_name).exists())


if __name__ == "__main__":
    unittest.main()
