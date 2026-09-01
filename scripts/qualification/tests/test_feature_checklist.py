from __future__ import annotations

from datetime import date, timedelta
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

QUALIFICATION = Path(__file__).resolve().parents[1]


def load_script():
    path = QUALIFICATION / "feature-checklist.py"
    spec = importlib.util.spec_from_file_location("feature_checklist", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


feature_checklist = load_script()


class FeatureChecklistTests(unittest.TestCase):
    def setUp(self):
        self.matrix = {
            "description": "fixture matrix",
            "hardware": [
                {
                    "id": "iphone",
                    "deviceFamily": "iPhone",
                    "osMajor": 26,
                    "summary": "Fixture iPhone",
                },
                {
                    "id": "ipad",
                    "deviceFamily": "iPad",
                    "osMajor": 26,
                    "summary": "Fixture iPad",
                },
            ],
            "scenarios": [
                {
                    "id": "seek",
                    "summary": "Seeking",
                },
                {
                    "id": "vod",
                    "summary": "Playback",
                    "hardware": ["iphone"],
                },
            ],
        }
        self.manifest = {
            "formatVersion": 1,
            "id": "fixture-features",
            "manifestVersion": "1.0.0",
            "releaseVersionPrefix": "1.1.0",
            "title": "Fixture checklist",
            "categories": [
                {"id": "playback", "title": "Playback & output"},
                {"id": "future", "title": "Future"},
            ],
            "features": [
                {
                    "id": "seek-landing",
                    "category": "playback",
                    "title": "Seek <lands>",
                    "description": "Decoded content proves landing.",
                    "releaseRequirement": "required",
                    "execution": "automated",
                    "evidenceLevel": "engine-output",
                    "scenarioIds": ["seek"],
                    "runnerScenarioIds": ["seek-runner"],
                },
                {
                    "id": "vod-output",
                    "category": "playback",
                    "title": "VOD output",
                    "description": "Moving output proves playback.",
                    "releaseRequirement": "required",
                    "execution": "automated",
                    "evidenceLevel": "system-output",
                    "scenarioIds": ["vod"],
                    "runnerScenarioIds": ["vod"],
                },
                {
                    "id": "receiver-output",
                    "category": "future",
                    "title": "Receiver output",
                    "description": "A receiver-side oracle proves casting.",
                    "releaseRequirement": "advisory",
                    "execution": "external-lab",
                    "evidenceLevel": "receiver-output",
                    "blocker": "No receiver configured.",
                },
            ],
        }
        self.matrix_checksum = self.digest(self.matrix)
        self.manifest_checksum = self.digest(self.manifest)

    @staticmethod
    def digest(value: dict) -> str:
        return hashlib.sha256(
            json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()

    def identity(self) -> dict:
        return {
            "version": "1.1.0-beta.1",
            "sourceCommit": "b" * 40,
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": "c" * 64,
            "artifactDigestAlgorithm": "swiftvlc-tree-v1",
            "artifactDigest": "a" * 64,
            "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
            "candidateAppDigest": "d" * 64,
            "qualificationMatrixChecksum": self.matrix_checksum,
        }

    @staticmethod
    def row(scenario: str, hardware: str, result: str = "pass") -> dict:
        return {
            "scenario": scenario,
            "hardware": hardware,
            "result": result,
            "evidence": f"evidence/{scenario}-{hardware}.json",
            "durationSeconds": 12,
        }

    def build(self, source: dict) -> dict:
        return feature_checklist.build_checklist(
            source,
            self.manifest,
            self.matrix,
            manifest_checksum=self.manifest_checksum,
            matrix_checksum=self.matrix_checksum,
        )

    def passing_release_runner_scenarios(self) -> list[dict]:
        rows = [
            {
                "scenario": scenario,
                "hardware": hardware,
                "result": "pass",
                "xcodebuildExitCode": 0,
                "libraryErrorCount": 0,
            }
            for scenario, hardware in sorted(
                feature_checklist.policy.required_release_runner_runs(self.matrix)
            )
        ]
        existing = {(row["scenario"], row["hardware"]) for row in rows}
        for runner in ("seek-runner", "vod"):
            for hardware in ("iphone", "ipad"):
                if (runner, hardware) not in existing:
                    rows.append(
                        {
                            "scenario": runner,
                            "hardware": hardware,
                            "result": "pass",
                            "xcodebuildExitCode": 0,
                            "libraryErrorCount": 0,
                        }
                    )
        return rows

    def add_upstream_risk_review(self) -> None:
        self.manifest["requiresFreshUpstreamRiskReview"] = True
        self.manifest["staticControls"] = [
            {
                "id": "fixture-artifact-contract",
                "title": "Fixture artifact contract",
                "description": "Checks the fixture artifact.",
                "command": "./scripts/check-fixture.sh",
            }
        ]
        self.manifest["upstreamRiskReview"] = {
            "reviewedOn": date.today().isoformat(),
            "maximumAgeDays": 45,
            "policy": "Known regressions require candidate-bound proof.",
            "risks": [
                {
                    "id": "vlckit-749-fixture-risk",
                    "sourceProject": "VLCKit",
                    "sourceIssue": 749,
                    "sourceStateAtReview": "open",
                    "sourceURL": "https://code.videolan.org/videolan/VLCKit/-/work_items/749",
                    "title": "Fixture HLS crash",
                    "failureMode": "The fixture clock can fail before playback.",
                    "featureIds": ["seek-landing"],
                    "controlIds": ["fixture-artifact-contract"],
                }
            ],
        }

    def test_repository_manifest_classifies_every_matrix_scenario(self):
        manifest = feature_checklist.load_json(
            QUALIFICATION / "feature-manifest-v1.json", "feature manifest"
        )
        matrix = feature_checklist.load_json(
            QUALIFICATION / "matrix.json", "qualification matrix"
        )
        feature_checklist.validate_manifest(manifest, matrix)
        covered = {
            scenario
            for feature in manifest["features"]
            for scenario in feature.get("scenarioIds", [])
        }
        self.assertEqual(covered, {scenario["id"] for scenario in matrix["scenarios"]})
        risks = manifest["upstreamRiskReview"]["risks"]
        self.assertEqual(len(risks), 16)
        self.assertEqual(len({risk["id"] for risk in risks}), len(risks))
        self.assertTrue(
            all(
                manifest_feature in {feature["id"] for feature in manifest["features"]}
                for risk in risks
                for manifest_feature in risk["featureIds"]
            )
        )
        controls = {
            control["id"]: control for control in manifest.get("staticControls", [])
        }
        self.assertEqual(
            controls["chromecast-native-state-contract"]["command"],
            "./scripts/validate-chromecast-load-transition.sh "
            "/path/to/patched-vlc-source /external/work-root",
        )
        self.assertEqual(
            controls["chromecast-metadata-schema-contract"]["command"],
            "./scripts/validate-chromecast-load-transition.sh "
            "/path/to/patched-vlc-source /external/work-root",
        )
        self.assertEqual(
            controls["apple-assembly-metadata-contract"],
            {
                "id": "apple-assembly-metadata-contract",
                "title": "Apple assembly tool and Mach-O metadata contract",
                "description": (
                    "Patch 0038 pins and selects the exact bundled NASM, carries "
                    "its four fail-closed metadata inputs through scrubbed Meson "
                    "setup and inherited compile boundaries, stamps every "
                    "supported Apple NASM-produced Mach-O object with explicit "
                    "build-version metadata, bounds libgcrypt text alignment, "
                    "and rejects stale tools, hidden options, malformed platform "
                    "inputs, and adversarial source mutations before a native "
                    "build begins."
                ),
                "command": (
                    "./scripts/validate-apple-assembly-metadata-patch.sh "
                    "/path/to/patched-vlc-source /external/work-root"
                ),
            },
        )
        self.assertEqual(
            controls["libvlc-macho-metadata-contract"],
            {
                "id": "libvlc-macho-metadata-contract",
                "title": "Final libVLC Mach-O object contract",
                "description": (
                    "The candidate XCFramework is parsed archive member by archive "
                    "member; every Mach-O object must identify the exact Apple "
                    "platform and deployment target, match its containing CPU slice, "
                    "use exactly one modern build-version command, avoid legacy "
                    "platform commands, and stay within architecture-specific "
                    "section-alignment caps."
                ),
                "command": (
                    "python3 ./scripts/validate-libvlc-macho-metadata.py "
                    "--xcframework /path/to/libvlc.xcframework "
                    "--deployment-target ios=18.0 --deployment-target tvos=18.0 "
                    "--deployment-target xros=2.0 --deployment-target macos=15.0 "
                    "--deployment-target catalyst=18.0 "
                    "--json-output /path/to/libvlc-macho-metadata.json"
                ),
            },
        )

    def test_manifest_rejects_unknown_and_unclassified_scenarios(self):
        unknown = json.loads(json.dumps(self.manifest))
        unknown["features"][0]["scenarioIds"] = ["not-a-scenario"]
        with self.assertRaises(feature_checklist.ChecklistError):
            feature_checklist.validate_manifest(unknown, self.matrix)

        uncovered = json.loads(json.dumps(self.manifest))
        uncovered["features"][1]["scenarioIds"] = ["seek"]
        with self.assertRaises(feature_checklist.ChecklistError):
            feature_checklist.validate_manifest(uncovered, self.matrix)

    def test_duplicate_json_keys_are_rejected_instead_of_last_wins(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "duplicate.json"
            path.write_text('{"formatVersion":1,"formatVersion":2}')
            with self.assertRaises(feature_checklist.ChecklistError):
                feature_checklist.load_json(path, "fixture")

    def test_upstream_risks_require_exact_sources_and_release_gates(self):
        mutations = {
            "unknown feature": lambda manifest: manifest["upstreamRiskReview"]["risks"][
                0
            ].update(featureIds=["missing-feature"]),
            "advisory feature": lambda manifest: manifest["upstreamRiskReview"][
                "risks"
            ][0].update(featureIds=["receiver-output"]),
            "untrusted URL": lambda manifest: manifest["upstreamRiskReview"]["risks"][
                0
            ].update(sourceURL="https://example.com/videolan/VLCKit/issues/749"),
            "unknown static control": lambda manifest: manifest["upstreamRiskReview"][
                "risks"
            ][0].update(controlIds=["missing-control"]),
            "noncanonical date": lambda manifest: manifest["upstreamRiskReview"].update(
                reviewedOn="2026-8-31"
            ),
            "stale review": lambda manifest: manifest["upstreamRiskReview"].update(
                reviewedOn=(date.today() - timedelta(days=46)).isoformat()
            ),
            "future review": lambda manifest: manifest["upstreamRiskReview"].update(
                reviewedOn=(date.today() + timedelta(days=1)).isoformat()
            ),
            "missing age policy": lambda manifest: manifest["upstreamRiskReview"].pop(
                "maximumAgeDays"
            ),
            "boolean age policy": lambda manifest: manifest[
                "upstreamRiskReview"
            ].update(maximumAgeDays=True),
            "missing required review": lambda manifest: manifest.pop(
                "upstreamRiskReview"
            ),
        }
        for description, mutate in mutations.items():
            with self.subTest(description):
                self.add_upstream_risk_review()
                manifest = json.loads(json.dumps(self.manifest))
                mutate(manifest)
                with self.assertRaises(feature_checklist.ChecklistError):
                    feature_checklist.validate_manifest(manifest, self.matrix)

    def test_upstream_risk_is_rendered_on_the_affected_feature(self):
        self.add_upstream_risk_review()
        source = {
            **self.identity(),
            "rows": [
                self.row("seek", "iphone"),
                self.row("seek", "ipad"),
                self.row("vod", "iphone"),
            ],
        }

        checklist = self.build(source)
        seek = next(
            feature
            for feature in checklist["features"]
            if feature["id"] == "seek-landing"
        )

        self.assertEqual(checklist["summary"]["upstreamRiskCount"], 1)
        self.assertEqual(seek["upstreamRisks"][0]["sourceIssue"], 749)
        markdown = feature_checklist.render_markdown(checklist, self.manifest)
        html = feature_checklist.render_html(checklist, self.manifest)
        self.assertIn(
            "[VLCKit #749](https://code.videolan.org/videolan/VLCKit/-/work_items/749)",
            markdown,
        )
        self.assertIn(
            'href="https://code.videolan.org/videolan/VLCKit/-/work_items/749"',
            html,
        )
        self.assertIn("## Static release controls", markdown)
        self.assertIn("Fixture artifact contract", markdown)
        self.assertIn("`./scripts/check-fixture.sh`", markdown)
        self.assertIn("<h2>Static release controls</h2>", html)
        self.assertIn("Fixture artifact contract", html)
        self.assertIn("<code>./scripts/check-fixture.sh</code>", html)

    def test_static_controls_render_without_an_upstream_risk_review(self):
        self.manifest["staticControls"] = [
            {
                "id": "fixture-artifact-contract",
                "title": "Fixture <artifact> contract",
                "description": "Checks candidate bytes & metadata.",
                "command": "python3 ./scripts/check-fixture.py --target /tmp/a&b",
            }
        ]
        source = {
            **self.identity(),
            "rows": [
                self.row("seek", "iphone"),
                self.row("seek", "ipad"),
                self.row("vod", "iphone"),
            ],
            "runnerScenarios": self.passing_release_runner_scenarios(),
        }

        checklist = self.build(source)
        self.assertEqual(checklist["staticControls"], self.manifest["staticControls"])

        markdown = feature_checklist.render_markdown(checklist, self.manifest)
        html = feature_checklist.render_html(checklist, self.manifest)
        self.assertIn("## Static release controls", markdown)
        self.assertIn("Fixture <artifact> contract", markdown)
        self.assertIn(
            "`python3 ./scripts/check-fixture.py --target /tmp/a&b`", markdown
        )
        self.assertIn("Fixture &lt;artifact&gt; contract", html)
        self.assertIn("Checks candidate bytes &amp; metadata.", html)
        self.assertIn(
            "<code>python3 ./scripts/check-fixture.py --target /tmp/a&amp;b</code>",
            html,
        )

    def test_device_report_distinguishes_pass_runner_failure_and_blocked(self):
        source = {
            **self.identity(),
            "device": {
                "name": "Fixture Phone",
                "productType": "iPhone99,1",
                "osVersion": "26.0",
                "osBuild": "23A1",
                "osReleaseType": "stable",
                "matchingHardwareRows": ["iphone"],
            },
            "qualificationRows": [self.row("seek", "iphone")],
            "scenarios": [
                {
                    "scenario": "seek-runner",
                    "result": "pass",
                    "xcodebuildExitCode": 0,
                    "libraryErrorCount": 0,
                },
                {
                    "scenario": "vod",
                    "result": "fail",
                    "xcodebuildExitCode": 65,
                    "libraryErrorCount": 1,
                },
            ],
        }
        checklist = self.build(source)
        results = {feature["id"]: feature for feature in checklist["features"]}
        self.assertEqual(results["seek-landing"]["status"], "pass")
        self.assertEqual(results["vod-output"]["status"], "fail")
        self.assertEqual(results["receiver-output"]["status"], "blocked")
        self.assertEqual(checklist["sourceKind"], "deviceReport")
        self.assertFalse(checklist["summary"]["requiredFeaturesSatisfied"])
        self.assertFalse(checklist["summary"]["releaseReady"])
        self.assertEqual(checklist["runnerFailures"][0]["scenario"], "vod")

    def exploratory_future_device_report(self) -> dict:
        return {
            **self.identity(),
            "mode": "exploratory",
            "qualificationEligibleEnvironment": False,
            "device": {
                "name": "Future Fixture Phone",
                "deviceFamily": "iPhone",
                "productType": "iPhone100,1",
                "osVersion": "27.0",
                "osMajor": 27,
                "osBuild": "24A1a",
                "osReleaseType": "beta",
                "matchingHardwareRows": [],
            },
            "qualificationRows": [],
            "scenarios": [
                {
                    "scenario": "seek-runner",
                    "result": "pass",
                    "xcodebuildExitCode": 0,
                    "libraryErrorCount": 0,
                },
                {
                    "scenario": "vod",
                    "result": "pass",
                    "xcodebuildExitCode": 0,
                    "libraryErrorCount": 0,
                },
            ],
        }

    def test_future_exploratory_device_projects_for_visibility_without_false_passes(
        self,
    ):
        checklist = self.build(self.exploratory_future_device_report())
        results = {feature["id"]: feature for feature in checklist["features"]}
        self.assertEqual(results["seek-landing"]["status"], "notRun")
        self.assertEqual(results["vod-output"]["status"], "notRun")
        self.assertEqual(results["receiver-output"]["status"], "blocked")
        self.assertEqual(checklist["summary"]["counts"]["pass"], 0)
        self.assertTrue(checklist["runnerFailures"])
        self.assertTrue(
            all(row["result"] == "notRun" for row in checklist["runnerFailures"])
        )
        self.assertIn(
            "analyzer", {row["scenario"] for row in checklist["runnerFailures"]}
        )
        self.assertEqual(checklist["scope"]["hardware"], ["iphone"])
        self.assertEqual(
            checklist["scope"]["exploratoryProjection"],
            {
                "reason": "futureDeviceChecklistProjection",
                "deviceFamily": "iPhone",
                "deviceOSMajor": 27,
                "matrixHardware": "iphone",
                "matrixOSMajor": 26,
                "qualificationRowsAccepted": False,
            },
        )

    def test_exploratory_projection_is_fail_closed(self):
        mutations = {
            "qualification mode": lambda source: source.update(mode="qualification"),
            "qualification eligible": lambda source: source.update(
                qualificationEligibleEnvironment=True
            ),
            "not a future OS": lambda source: source["device"].update(osMajor=26),
            "unmapped family": lambda source: source["device"].update(
                deviceFamily="AppleTV"
            ),
            "fabricated qualification row": lambda source: source[
                "qualificationRows"
            ].append(self.row("seek", "iphone")),
        }
        for description, mutate in mutations.items():
            with self.subTest(description):
                source = self.exploratory_future_device_report()
                mutate(source)
                with self.assertRaises(feature_checklist.ChecklistError):
                    self.build(source)

    def test_release_record_is_ready_only_when_every_required_row_passes(self):
        self.manifest["features"] = self.manifest["features"][:2]
        source = {
            **self.identity(),
            "rows": [
                self.row("seek", "iphone"),
                self.row("seek", "ipad"),
                self.row("vod", "iphone"),
            ],
            "runnerScenarios": self.passing_release_runner_scenarios(),
        }
        checklist = self.build(source)
        self.assertTrue(checklist["summary"]["requiredFeaturesSatisfied"])
        self.assertTrue(checklist["summary"]["releaseReady"])

        source["rows"].pop()
        incomplete = self.build(source)
        vod = next(
            feature
            for feature in incomplete["features"]
            if feature["id"] == "vod-output"
        )
        self.assertEqual(vod["status"], "notRun")
        self.assertFalse(incomplete["summary"]["releaseReady"])

    def test_partial_is_distinct_from_a_complete_feature(self):
        self.manifest["features"] = self.manifest["features"][:2]
        source = {
            **self.identity(),
            "rows": [self.row("seek", "iphone")],
            "runnerScenarios": self.passing_release_runner_scenarios(),
        }
        checklist = self.build(source)
        self.assertEqual(checklist["features"][0]["status"], "partial")
        self.assertEqual(
            checklist["features"][0]["detail"], "1 of 2 required rows passed."
        )

    def test_matrix_checksum_mismatch_is_fail_closed(self):
        source = {
            **self.identity(),
            "qualificationMatrixChecksum": "d" * 64,
            "rows": [],
        }
        with self.assertRaises(feature_checklist.ChecklistError):
            self.build(source)

    def test_check_only_enforces_completeness_without_writing_reports(self):
        self.manifest["features"] = self.manifest["features"][:2]
        self.manifest["features"][0]["runnerScenarioIds"] = ["hls-seek"]
        self.manifest["features"][1]["runnerScenarioIds"] = ["vod-controls"]
        self.matrix["hardware"] = self.matrix["hardware"][:1]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            matrix_path = root / "matrix.json"
            manifest_path = root / "features.json"
            record_path = root / "record.json"
            policy = feature_checklist.policy
            catalog = ["iOSUITests/FixtureTests/test_featurePolicy"]
            catalog_record = policy.catalog_record(catalog)
            output_contracts = {
                "hls-seek": [
                    {
                        "scenario": "seek",
                        "attachmentName": "qualification-seek.json",
                        "testIdentifiers": catalog,
                    }
                ],
                "vod-controls": [
                    {
                        "scenario": "vod",
                        "attachmentName": "qualification-vod.json",
                        "testIdentifiers": catalog,
                    }
                ],
            }
            self.matrix["runnerContracts"] = [
                {
                    "id": runner,
                    "selection": {
                        "kind": "exact",
                        "testIdentifiers": catalog,
                    },
                    "outputs": output_contracts.get(runner, []),
                }
                for runner in sorted(policy.REQUIRED_RELEASE_RUNNER_SCENARIOS)
            ]
            matrix_path.write_text(json.dumps(self.matrix, sort_keys=True))
            manifest_path.write_text(json.dumps(self.manifest, sort_keys=True))
            execution = {
                "expected": catalog_record,
                "executed": catalog_record,
                "identityAndCountMatch": True,
                "allPassed": True,
            }
            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake_xcrun = fake_bin / "xcrun"
            command_environment = {
                **os.environ,
                "PATH": f"{fake_bin}:{os.environ.get('PATH', '')}",
            }

            def write_strict_record() -> None:
                identity = {
                    **self.identity(),
                    "formatVersion": 2,
                    "qualificationMatrixChecksum": hashlib.sha256(
                        matrix_path.read_bytes()
                    ).hexdigest(),
                    "featureManifestChecksum": hashlib.sha256(
                        manifest_path.read_bytes()
                    ).hexdigest(),
                    "qualificationProfilesChecksum": "e" * 64,
                    "fixtureManifestChecksum": "f" * 64,
                    "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
                    "testRunnerDigest": "1" * 64,
                    "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
                    "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
                    "testBundleDigest": "2" * 64,
                    "baseXCTestRunDigestAlgorithm": "sha256",
                    "baseXCTestRunDigest": "3" * 64,
                    "baseXCTestRunName": "fixture.xctestrun",
                    "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
                    "testCatalogDigest": catalog_record["digest"],
                    "testCatalogCount": catalog_record["testCount"],
                    "testCatalog": catalog,
                    "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
                    "qualificationPolicyDigest": policy.policy_digest(),
                }
                source_directory = (
                    root / f"source-{identity['featureManifestChecksum'][:12]}"
                )
                source_directory.mkdir()
                source_evidence_directory = source_directory / "evidence"
                source_evidence_directory.mkdir()
                runners = sorted(
                    policy.REQUIRED_RELEASE_RUNNER_SCENARIOS
                    - policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
                )
                runner_rows = []
                runner_data = {}
                attachment_exports = {}
                for runner in runners:
                    attempt_root = source_directory / f"{runner}-attempt-artifacts"
                    attempt_root.mkdir()
                    attempt_log = attempt_root / "attempt-1.log"
                    attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
                    attempt_bundle = attempt_root / "attempt-1.xcresult"
                    attempt_bundle.mkdir()
                    (attempt_bundle / "Info.plist").write_text("fixture")
                    attempts = policy.bind_attempt_artifacts(
                        [
                            {
                                "attempt": 1,
                                "classification": "passed",
                                "retryable": False,
                                "intendedTestBegan": True,
                                "xcodebuildExitCode": 0,
                                "logArtifact": attempt_log.relative_to(
                                    source_directory
                                ).as_posix(),
                                "xcresultArtifact": attempt_bundle.relative_to(
                                    source_directory
                                ).as_posix(),
                                "testExecution": execution,
                            }
                        ],
                        source_directory,
                    )
                    inventory = None
                    app_log = "notCaptured"
                    outputs = output_contracts.get(runner, [])
                    if runner != "analyzer":
                        raw_directory = source_directory / "raw-logs" / runner
                        raw_directory.mkdir(parents=True)
                        declared_children = policy.DECLARED_TEST_CHILD_LOGS.get(runner)
                        children = [None, *sorted(declared_children or ())]
                        for child in children:
                            raw_name = policy.test_log_filename(
                                "run",
                                catalog[0],
                                "00000000-0000-4000-8000-000000000001",
                                child=child,
                            )
                            (raw_directory / raw_name).write_text(
                                json.dumps(
                                    {
                                        "ts": "2026-08-31T12:00:00Z",
                                        "level": "debug",
                                        "module": policy.LOG_MIRROR_HEALTH_MODULE,
                                        "message": policy.LOG_MIRROR_HEALTH_MESSAGE,
                                    }
                                )
                                + "\n"
                            )
                        inventory = policy.build_error_inventory(
                            raw_directory,
                            "run",
                            runner,
                            retained_root=f"raw-logs/{runner}",
                            expected_test_catalog=catalog_record,
                        )
                        app_log = "captured"
                    if outputs:
                        attachment_root = source_directory / f"{runner}-attachments"
                        attachment_root.mkdir()
                        manifest_attachments = []
                        payloads = {}
                        for output in outputs:
                            payload_path = (
                                attachment_root / f"{output['scenario']}.json"
                            )
                            payload = {
                                "scenario": output["scenario"],
                                "durationSeconds": 12,
                            }
                            payload_path.write_text(json.dumps(payload, sort_keys=True))
                            payloads[output["scenario"]] = payload_path
                            manifest_attachments.append(
                                {
                                    "suggestedHumanReadableName": output[
                                        "attachmentName"
                                    ],
                                    "exportedFileName": payload_path.name,
                                }
                            )
                        attachment_manifest_path = attachment_root / "manifest.json"
                        attachment_manifest_path.write_text(
                            json.dumps(
                                [
                                    {
                                        "testIdentifier": catalog[0],
                                        "attachments": manifest_attachments,
                                    }
                                ],
                                sort_keys=True,
                            )
                        )
                        attachment_exports[runner] = attachment_root
                    else:
                        payloads = {}
                        attachment_manifest_path = None
                    runner_rows.append(
                        {
                            "scenario": runner,
                            "result": "pass",
                            "xcodebuildExitCode": 0,
                            "libraryErrorCount": 0,
                            "appLog": app_log,
                            "expectedTestCatalog": catalog_record,
                            "testExecution": execution,
                            "hostErrorInventory": inventory,
                            "attempts": attempts,
                            "attemptArtifactRoot": attempt_root.name,
                            "durationSeconds": 12,
                            "qualificationEvidence": (
                                "captured" if outputs else "notCaptured"
                            ),
                        }
                    )
                    runner_data[runner] = {
                        "attempts": attempts,
                        "inventory": inventory,
                        "payloads": payloads,
                        "manifest": attachment_manifest_path,
                    }
                rows = []
                for scenario, hardware in (
                    ("seek", "iphone"),
                    ("vod", "iphone"),
                ):
                    runner = "hls-seek" if scenario == "seek" else "vod-controls"
                    data = runner_data[runner]
                    attempts = data["attempts"]
                    producer_manifest_path = data["manifest"]
                    payload_path = data["payloads"][scenario]
                    assert producer_manifest_path is not None
                    evidence_relative = f"evidence/{scenario}-{hardware}.json"
                    evidence_value = {
                        **{
                            field: identity[field]
                            for field in policy.CORE_IDENTITY_FIELDS
                        },
                        "scenario": scenario,
                        "hardware": hardware,
                        "deviceIdentifier": "fixture-device",
                        "durationSeconds": 12,
                        "testExecution": execution,
                        "hostErrorInventory": data["inventory"],
                        "qualificationProducer": {
                            "runnerScenario": runner,
                            "sourceAttempt": 1,
                            "sourceXcresultArtifact": attempts[-1]["xcresultArtifact"],
                            "sourceXcresultDigestAlgorithm": attempts[-1][
                                "xcresultDigestAlgorithm"
                            ],
                            "sourceXcresultDigest": attempts[-1]["xcresultDigest"],
                            "sourceXcresultSizeBytes": attempts[-1][
                                "xcresultSizeBytes"
                            ],
                            "attachmentName": f"qualification-{scenario}.json",
                            "attachmentTestIdentifier": catalog[0],
                            "retainedAttachmentRoot": f"{runner}-attachments",
                            "manifestRelativePath": producer_manifest_path.relative_to(
                                source_directory
                            ).as_posix(),
                            "manifestDigestAlgorithm": "sha256",
                            "manifestDigest": policy.sha256_file(
                                producer_manifest_path
                            ),
                            "manifestSizeBytes": producer_manifest_path.stat().st_size,
                            "attachmentRelativePath": payload_path.relative_to(
                                source_directory
                            ).as_posix(),
                            "attachmentDigestAlgorithm": "sha256",
                            "attachmentDigest": policy.sha256_file(payload_path),
                            "attachmentSizeBytes": payload_path.stat().st_size,
                        },
                    }
                    evidence_path = root / evidence_relative
                    evidence_path.parent.mkdir(parents=True, exist_ok=True)
                    evidence_path.write_text(json.dumps(evidence_value, sort_keys=True))
                    (source_directory / evidence_relative).write_text(
                        json.dumps(evidence_value, sort_keys=True)
                    )
                    rows.append(
                        {
                            "scenario": scenario,
                            "runnerScenario": runner,
                            "hardware": hardware,
                            "device": f"Fixture {hardware}",
                            "deviceFamily": (
                                "iPhone" if hardware == "iphone" else "iPad"
                            ),
                            "productType": "Fixture1,1",
                            "osVersion": "26.0",
                            "osBuild": "23A1",
                            "osReleaseType": "stable",
                            "fixture": "qualification-fixtures:" + "f" * 64,
                            "duration": "12s",
                            "durationSeconds": 12,
                            "evidence": evidence_relative,
                            "result": "pass",
                        }
                    )
                source_report = source_directory / "report.json"
                source_report.write_text(
                    json.dumps(
                        {
                            **identity,
                            "device": {"udid": "fixture-device"},
                            "qualificationEligibleEnvironment": True,
                            "mode": "qualification",
                            "result": "pass",
                            "scenarios": runner_rows,
                            "qualificationRows": rows,
                        },
                        sort_keys=True,
                    )
                )
                source_digest = policy.tree_digest(source_directory)
                source_binding = {
                    "path": source_directory.relative_to(root).as_posix(),
                    "reportRelativePath": source_report.name,
                    "reportDigestAlgorithm": "sha256",
                    "reportDigest": policy.sha256_file(source_report),
                    "reportSizeBytes": source_report.stat().st_size,
                    "treeDigestAlgorithm": "swiftvlc-tree-v1",
                    "treeDigest": source_digest,
                    "treeSizeBytes": policy.tree_size_bytes(source_directory),
                }
                source_report_relative = (
                    Path(source_binding["path"]) / source_binding["reportRelativePath"]
                ).as_posix()
                runner_summaries = [
                    policy.runner_record_summary(
                        runner_row, "iphone", source_report_relative
                    )
                    for runner_row in runner_rows
                ]
                record_path.write_text(
                    json.dumps(
                        {
                            **identity,
                            "sourceReports": [source_binding],
                            "runnerScenarios": runner_summaries,
                            "rows": rows,
                        },
                        sort_keys=True,
                    )
                )
                export_mapping = {
                    f"/{runner}-attempt-artifacts/": str(path)
                    for runner, path in attachment_exports.items()
                }
                fake_xcrun.write_text(
                    "#!/usr/bin/env python3\n"
                    "import json, pathlib, shutil, sys\n"
                    f"catalog = {catalog!r}\n"
                    f"exports = {export_mapping!r}\n"
                    "args = sys.argv[1:]\n"
                    "if 'export' in args and 'attachments' in args:\n"
                    "    source_xcresult = args[args.index('--path') + 1]\n"
                    "    output = pathlib.Path(args[args.index('--output-path') + 1])\n"
                    "    for marker, source in exports.items():\n"
                    "        if marker in source_xcresult:\n"
                    "            shutil.copytree(source, output)\n"
                    "            raise SystemExit(0)\n"
                    "    raise SystemExit(2)\n"
                    "print(json.dumps({'testNodes': ["
                    "{'nodeType': 'Test Case', 'nodeIdentifier': identifier, "
                    "'result': 'Passed'} for identifier in catalog]}))\n"
                )
                fake_xcrun.chmod(0o755)

            write_strict_record()
            command = [
                sys.executable,
                str(QUALIFICATION / "feature-checklist.py"),
                "--manifest",
                str(manifest_path),
                "--matrix",
                str(matrix_path),
                "--input",
                str(record_path),
                "--check-only",
                "--require-complete",
            ]
            complete = subprocess.run(
                command,
                text=True,
                capture_output=True,
                env=command_environment,
            )
            self.assertEqual(
                complete.returncode,
                0,
                f"stdout={complete.stdout}\nstderr={complete.stderr}",
            )
            self.assertIn("2 passed", complete.stdout)
            self.assertFalse((root / "feature-checklist.json").exists())

            blocked = {
                "id": "receiver-output-required",
                "category": "future",
                "title": "Required receiver output",
                "description": "Receiver-side evidence is required.",
                "releaseRequirement": "required",
                "execution": "external-lab",
                "evidenceLevel": "receiver-output",
                "blocker": "No receiver evidence exists.",
            }
            self.manifest["features"].append(blocked)
            manifest_path.write_text(json.dumps(self.manifest, sort_keys=True))
            write_strict_record()
            incomplete = subprocess.run(
                command,
                text=True,
                capture_output=True,
                env=command_environment,
            )
            self.assertEqual(incomplete.returncode, 1, incomplete.stderr)
            self.assertIn("1 blocked", incomplete.stdout)
            self.assertFalse((root / "feature-checklist.json").exists())

    def test_outputs_are_deterministic_and_html_escaped(self):
        source = {
            **self.identity(),
            "device": {
                "name": "Fixture & Phone",
                "productType": "iPhone99,1",
                "osVersion": "26.0",
                "osBuild": "23A1",
                "osReleaseType": "stable",
                "matchingHardwareRows": ["iphone"],
            },
            "qualificationRows": [
                self.row("seek", "iphone"),
                self.row("vod", "iphone"),
            ],
            "scenarios": [],
        }
        checklist = self.build(source)
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            feature_checklist.write_outputs(Path(first), checklist, self.manifest)
            feature_checklist.write_outputs(Path(second), checklist, self.manifest)
            for filename in (
                "feature-checklist.json",
                "feature-checklist.md",
                "feature-checklist.html",
            ):
                self.assertEqual(
                    (Path(first) / filename).read_bytes(),
                    (Path(second) / filename).read_bytes(),
                )
            html = (Path(first) / "feature-checklist.html").read_text()
            self.assertIn("Fixture &amp; Phone", html)
            self.assertIn("Seek &lt;lands&gt;", html)
            markdown = (Path(first) / "feature-checklist.md").read_text()
            self.assertIn("[seek on iphone](evidence/seek-iphone.json)", markdown)
            self.assertNotIn(
                "generatedAt", (Path(first) / "feature-checklist.json").read_text()
            )


if __name__ == "__main__":
    unittest.main()
