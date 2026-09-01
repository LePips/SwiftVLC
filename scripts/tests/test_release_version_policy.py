from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]


def load_policy():
    path = SCRIPTS / "release-version-policy.py"
    spec = importlib.util.spec_from_file_location("release_version_policy", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


release_version_policy = load_policy()


class ReleaseVersionPolicyTests(unittest.TestCase):
    def test_stable_versions_require_qualification(self):
        for version in ("0.0.0", "1.1.0", "10.24.300"):
            with self.subTest(version):
                policy = release_version_policy.classify(version)
                self.assertEqual(policy["kind"], "stable")
                self.assertFalse(policy["isPrerelease"])
                self.assertTrue(policy["requiresQualification"])
                self.assertEqual(policy["tag"], f"v{version}")

    def test_prerelease_versions_never_look_stable(self):
        for version in (
            "1.1.0-alpha",
            "1.1.0-beta.1",
            "1.1.0-rc.0",
            "1.1.0-preview-arm64",
        ):
            with self.subTest(version):
                policy = release_version_policy.classify(version)
                self.assertEqual(policy["kind"], "prerelease")
                self.assertTrue(policy["isPrerelease"])
                self.assertFalse(policy["requiresQualification"])

    def test_malformed_or_ambiguous_versions_are_rejected(self):
        for version in (
            "",
            "1",
            "1.1",
            "v1.1.0",
            "01.1.0",
            "1.01.0",
            "1.1.00",
            "1.1.0-",
            "1.1.0-beta..1",
            "1.1.0-beta.01",
            "1.1.0+unqualified",
            "1.1.0/beta",
        ):
            with self.subTest(version):
                with self.assertRaises(release_version_policy.VersionPolicyError):
                    release_version_policy.classify(version)


if __name__ == "__main__":
    unittest.main()
