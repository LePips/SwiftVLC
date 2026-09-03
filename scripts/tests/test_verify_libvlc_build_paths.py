import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "verify-libvlc-build-paths.py"
CHUNK_SIZE = 1024 * 1024


class BuildPathVerifierTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name).resolve()
        self.artifact = self.root / "libvlc.xcframework"
        self.library = self.artifact / "ios-arm64" / "libvlc.a"
        self.library.parent.mkdir(parents=True)
        self.forbidden = self.root / "checkout-with-a-long-name"
        self.forbidden.mkdir()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def run_verifier(self, *extra_arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(self.artifact),
                "--forbidden-path",
                str(self.forbidden),
                *extra_arguments,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

    def test_accepts_artifact_without_forbidden_path(self) -> None:
        self.library.write_bytes(b"deterministic native archive")

        result = self.run_verifier()

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no forbidden build paths embedded", result.stdout)

    def test_rejects_path_split_across_read_chunks(self) -> None:
        encoded = str(self.forbidden.resolve()).encode()
        prefix_size = CHUNK_SIZE - len(encoded) // 2
        self.library.write_bytes(b"x" * prefix_size + encoded + b"tail")

        result = self.run_verifier()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("release artifact embeds forbidden build path", result.stderr)
        self.assertIn("ios-arm64/libvlc.a", result.stderr)

    def test_reports_each_leaking_file_and_root(self) -> None:
        second_library = self.artifact / "macos-arm64_x86_64" / "libvlc.a"
        second_library.parent.mkdir()
        payload = str(self.forbidden.resolve()).encode()
        self.library.write_bytes(payload)
        second_library.write_bytes(b"prefix" + payload)

        result = self.run_verifier()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(self.forbidden.resolve()), result.stderr)
        self.assertIn("ios-arm64/libvlc.a", result.stderr)
        self.assertIn("macos-arm64_x86_64/libvlc.a", result.stderr)

    def test_rejects_duplicate_canonical_forbidden_path(self) -> None:
        self.library.write_bytes(b"clean")

        result = self.run_verifier(
            "--forbidden-path",
            str(self.forbidden),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate forbidden build path", result.stderr)

    def test_rejects_lexically_noncanonical_forbidden_path(self) -> None:
        self.library.write_bytes(b"clean")
        raw_alias = f"{self.forbidden.parent}/./{self.forbidden.name}"

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(self.artifact),
                "--forbidden-path",
                raw_alias,
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use its canonical physical path", result.stderr)

    def test_rejects_noncanonical_forbidden_path_alias(self) -> None:
        self.library.write_bytes(b"clean")
        alias = self.root / "checkout-alias"
        alias.symlink_to(self.forbidden, target_is_directory=True)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(self.artifact),
                "--forbidden-path",
                str(alias),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use its canonical physical path", result.stderr)

    def test_rejects_wrong_case_alias_on_case_insensitive_filesystem(self) -> None:
        self.library.write_bytes(b"clean")
        wrong_case = self.forbidden.with_name(self.forbidden.name.upper())
        if not wrong_case.exists() or not wrong_case.samefile(self.forbidden):
            self.skipTest("test volume is case-sensitive")

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(self.artifact),
                "--forbidden-path",
                str(wrong_case),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must use its canonical physical path", result.stderr)

    def test_rejects_relative_and_nondirectory_forbidden_paths(self) -> None:
        self.library.write_bytes(b"clean")
        relative = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(self.artifact),
                "--forbidden-path",
                "relative-checkout",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(relative.returncode, 0)
        self.assertIn("must be an absolute path", relative.stderr)

        regular_file = self.root / "not-a-directory"
        regular_file.write_bytes(b"path")
        nondirectory = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(self.artifact),
                "--forbidden-path",
                str(regular_file),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(nondirectory.returncode, 0)
        self.assertIn("is not a directory", nondirectory.stderr)

    def test_scans_multiple_roots_and_binary_payloads(self) -> None:
        second_forbidden = self.root / "second-root-with-different-length"
        second_forbidden.mkdir()
        self.library.write_bytes(
            b"\x00\xffbinary\x00" + str(second_forbidden).encode() + b"\x00tail"
        )

        result = self.run_verifier(
            "--forbidden-path",
            str(second_forbidden),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn(str(second_forbidden), result.stderr)

    def test_rejects_empty_artifact_tree(self) -> None:
        self.library.unlink(missing_ok=True)

        result = self.run_verifier()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("XCFramework contains no files or symlinks", result.stderr)

    def test_rejects_forbidden_path_in_symlink_target(self) -> None:
        artifact = self.forbidden / "Vendor" / "libvlc.xcframework"
        target = artifact / "ios-arm64" / "libvlc.a"
        target.parent.mkdir(parents=True)
        target.write_bytes(b"clean archive")
        link = artifact / "current-library"
        link.symlink_to(target)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--xcframework",
                str(artifact),
                "--forbidden-path",
                str(self.forbidden),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("current-library (symlink target)", result.stderr)

    @unittest.skipIf(os.geteuid() == 0, "root can traverse mode-zero directories")
    def test_fails_closed_when_an_artifact_subtree_is_unreadable(self) -> None:
        self.library.write_bytes(b"clean")
        unreadable = self.artifact / "unreadable"
        unreadable.mkdir()
        (unreadable / "hidden").write_bytes(str(self.forbidden).encode())
        unreadable.chmod(0)
        try:
            result = self.run_verifier()
        finally:
            unreadable.chmod(0o700)

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot enumerate XCFramework", result.stderr)


if __name__ == "__main__":
    unittest.main()
