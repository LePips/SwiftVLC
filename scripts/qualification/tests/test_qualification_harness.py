from __future__ import annotations

import http.client
import hashlib
import importlib.util
import json
import plistlib
import tempfile
import threading
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = ROOT / "qualification" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


device_info = load_script("device-info.py")
fixture_server = load_script("fixture-server.py")
prepare_xctestrun = load_script("prepare-xctestrun.py")
verify_fixtures = load_script("verify-fixtures.py")
candidate_metadata = load_script("candidate-metadata.py")


class DeviceInfoTests(unittest.TestCase):
    def test_release_classification_is_fail_closed(self):
        self.assertEqual(device_info.release_type({"releaseType": "Beta"}), "beta")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "24A5390f"}), "beta")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "20E772520a"}), "stable")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "23G80"}), "stable")
        self.assertEqual(device_info.release_type({"osBuildUpdate": "unexpected"}), "unknown")

    def test_only_connected_stable_matching_device_qualifies(self):
        device = {
            "identifier": "core-id",
            "connectionProperties": {"tunnelState": "connected", "transportType": "wired"},
            "deviceProperties": {
                "name": "Fixture iPhone",
                "ddiServicesAvailable": True,
                "developerModeStatus": "enabled",
                "osVersionNumber": "26.6",
                "osBuildUpdate": "23G80",
            },
            "hardwareProperties": {
                "reality": "physical",
                "platform": "iOS",
                "deviceType": "iPhone",
                "ecid": 42,
                "udid": "fixture-udid",
                "productType": "iPhone99,1",
            },
        }
        normalized = device_info.normalize(
            device, [{"id": "iphone-current", "deviceFamily": "iPhone", "osMajor": 26}]
        )
        self.assertTrue(normalized["connected"])
        self.assertTrue(normalized["qualificationEligible"])
        self.assertEqual(normalized["matchingHardwareRows"], ["iphone-current"])


class XCTestrunTests(unittest.TestCase):
    def test_destination_artifact_transform_removes_local_paths(self):
        original = {
            "TestConfigurations": [
                {
                    "TestTargets": [
                        {
                            "IsUITestBundle": True,
                            "TestBundlePath": "/tmp/test.xctest",
                            "TestHostPath": "/tmp/Runner.app",
                            "UITargetAppPath": "/tmp/iOS.app",
                            "DependentProductPaths": ["/tmp/iOS.app"],
                        }
                    ]
                }
            ]
        }
        transformed = prepare_xctestrun.transform(original, {"ATTACH": "YES"})
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        for key in prepare_xctestrun.REMOVED_PATH_KEYS:
            self.assertNotIn(key, target)
        self.assertTrue(target["UseDestinationArtifacts"])
        self.assertEqual(target["TestingEnvironmentVariables"]["ATTACH"], "YES")


class CandidateMetadataTests(unittest.TestCase):
    def test_metadata_is_bound_to_the_exact_candidate_digest(self):
        app_digest = "a" * 64
        metadata = {
            "formatVersion": 1,
            "version": "1.1.0",
            "sourceCommit": "b" * 40,
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": "c" * 64,
            "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
            "candidateAppDigest": app_digest,
        }
        self.assertEqual(
            candidate_metadata.validate(metadata, "1.1.0", app_digest), metadata
        )
        with self.assertRaises(candidate_metadata.CandidateMetadataError):
            candidate_metadata.validate(metadata, "1.1.0", "d" * 64)

    def test_metadata_reads_source_identity_from_the_signed_app_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "iOS.app"
            app.mkdir()
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump(
                    {
                        "SwiftVLCSourceCommit": "b" * 40,
                        "SwiftVLCReleaseSourceDigest": "c" * 64,
                    },
                    output,
                )
            digest_script = root / "digest.py"
            digest_script.write_text(f'print("{"a" * 64}")\n')

            metadata = candidate_metadata.create(app, "1.1.0", digest_script)
            self.assertEqual(metadata["sourceCommit"], "b" * 40)
            self.assertEqual(metadata["releaseSourceDigest"], "c" * 64)
            self.assertEqual(metadata["candidateAppDigest"], "a" * 64)


class FixtureManifestTests(unittest.TestCase):
    def test_cached_fixture_bytes_must_match_the_manifest_exactly(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            sample = root / "sample.bin"
            sample.write_bytes(b"candidate-bound fixture")
            manifest = {
                "formatVersion": 1,
                "files": {
                    "sample.bin": {
                        "bytes": sample.stat().st_size,
                        "sha256": hashlib.sha256(sample.read_bytes()).hexdigest(),
                    }
                },
            }
            (root / "manifest.json").write_text(json.dumps(manifest))
            self.assertEqual(verify_fixtures.verify(root), manifest)

            sample.write_bytes(b"corrupted")
            with self.assertRaises(verify_fixtures.FixtureVerificationError):
                verify_fixtures.verify(root)


class FixtureServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "sample.bin").write_bytes(bytes(range(256)) * 64)
        self.log = self.root / "requests.jsonl"
        self.server = fixture_server.FixtureHTTPServer(
            ("127.0.0.1", 0), self.root, self.log, 512, 0, False
        )
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, path: str, headers: dict | None = None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        return connection, response

    def test_static_file_supports_byte_ranges(self):
        connection, response = self.request("/files/sample.bin", {"Range": "bytes=10-19"})
        self.assertEqual(response.status, 206)
        self.assertEqual(response.read(), (self.root / "sample.bin").read_bytes()[10:20])
        connection.close()

    def test_out_of_bounds_range_uses_rfc_status(self):
        size = (self.root / "sample.bin").stat().st_size
        connection, response = self.request(
            "/files/sample.bin", {"Range": f"bytes={size}-"}
        )
        self.assertEqual(response.status, 416)
        self.assertEqual(response.getheader("Content-Range"), f"bytes */{size}")
        self.assertEqual(response.read(), b"")
        connection.close()

    def test_stall_endpoint_delays_then_completes(self):
        started = time.monotonic()
        connection, response = self.request("/fault/stall/0.15/sample.bin")
        self.assertEqual(len(response.read()), (self.root / "sample.bin").stat().st_size)
        self.assertGreaterEqual(time.monotonic() - started, 0.14)
        connection.close()

    def test_live_endpoint_repeats_content(self):
        connection, response = self.request("/live/sample.bin")
        sample = (self.root / "sample.bin").read_bytes()
        self.assertEqual(response.read(len(sample) + 32), sample + sample[:32])
        connection.close()


if __name__ == "__main__":
    unittest.main()
