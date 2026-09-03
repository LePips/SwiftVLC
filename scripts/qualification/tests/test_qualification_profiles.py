from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest import mock

QUALIFICATION = Path(__file__).resolve().parents[1]


def load_script(name: str):
    path = QUALIFICATION / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


qualify = load_script("qualify.py")


class QualificationProfileTests(unittest.TestCase):
    def setUp(self):
        self.profiles = qualify.load_profiles(QUALIFICATION / "profiles-v1.json")
        source_authority = {
            "sourceCommit": subprocess.check_output(
                ["git", "-C", str(QUALIFICATION.parents[1]), "rev-parse", "HEAD"],
                text=True,
            ).strip(),
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": "b" * 64,
        }
        source_authority_patch = mock.patch.object(
            qualify,
            "_source_authority_identity",
            return_value=source_authority,
        )
        source_authority_patch.start()
        self.addCleanup(source_authority_patch.stop)

    @staticmethod
    def fixture_device() -> dict:
        return {
            "id": "00008101-FIXTURE",
            "marketingName": "Fixture iPhone",
            "name": "Fixture iPhone",
            "osVersion": "26.0",
            "matchingHardwareRows": ["iphone-current"],
            "qualificationEligible": True,
        }

    def test_manifest_names_every_scenario_accepted_by_device_runner(self):
        runner = (QUALIFICATION / "run-device-tests.sh").read_text()
        match = re.search(r'case "\$scenario" in\s+([a-z0-9|*-]+)\) ;;', runner)
        self.assertIsNotNone(match)
        accepted = set(match.group(1).split("|"))
        self.assertEqual(accepted, set(self.profiles.runner_scenarios))

    def test_feature_manifest_cannot_name_a_nonexistent_runner_scenario(self):
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        referenced = {
            scenario
            for feature in manifest["features"]
            for scenario in feature.get("runnerScenarioIds", [])
        }
        self.assertTrue(referenced)
        self.assertEqual(referenced - self.profiles.runner_scenarios, set())
        self.assertEqual(
            referenced - set(self.profiles.profiles["release"].scenarios), set()
        )

    def test_release_is_stable_and_retains_every_endurance_lane(self):
        release = self.profiles.profiles["release"]
        self.assertTrue(release.stable_environment_required)
        self.assertIn("adaptive-hls-soak", release.scenarios)
        self.assertIn("timebase-vod-soak", release.scenarios)
        self.assertIn("timebase-live-soak", release.scenarios)
        self.assertIn("pip-render-performance-4k60", release.scenarios)
        self.assertIn("seek-frame-oracles", release.scenarios)
        self.assertIn("seek-frame-oracles", self.profiles.iphone_current_only_scenarios)

    def test_full_release_rehearsal_includes_seek_frame_oracles(self):
        self.assertIn("seek-frame-oracles", self.profiles.profiles["full"].scenarios)

    def test_full_release_rehearsal_is_an_exact_immutable_release_subset(self):
        release = self.profiles.profiles["release"].scenarios
        expected = tuple(
            scenario
            for scenario in release
            if scenario not in qualify.FULL_PROFILE_EXCLUDED_SCENARIOS
        )
        self.assertEqual(self.profiles.profiles["full"].scenarios, expected)

        payload = json.loads((QUALIFICATION / "profiles-v1.json").read_text())
        payload["profiles"]["full"]["scenarios"] = [
            "analyzer",
            "ui-suite",
            "harness-regressions",
            "seek-frame-oracles",
        ]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profiles.json"
            path.write_text(json.dumps(payload))
            with self.assertRaisesRegex(
                qualify.ConfigurationError,
                "full profile differs from immutable release-rehearsal coverage",
            ):
                qualify.load_profiles(path)

    def test_every_physical_profile_includes_core_local_playback_matrices(self):
        scenarios = {"local-file-matrix", "audio-only-playback"}
        for profile_name in ("smoke", "full", "release"):
            with self.subTest(profile=profile_name):
                self.assertTrue(
                    scenarios.issubset(self.profiles.profiles[profile_name].scenarios)
                )
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        features = {row["id"]: row for row in manifest["features"]}
        expectations = {
            "playback-local-file-matrix": "local-file-matrix",
            "playback-audio-only": "audio-only-playback",
        }
        for feature_id, scenario_id in expectations.items():
            with self.subTest(feature=feature_id):
                feature = features[feature_id]
                self.assertEqual(feature["execution"], "automated")
                self.assertEqual(feature["scenarioIds"], [scenario_id])
                self.assertEqual(feature["runnerScenarioIds"], [scenario_id])
                self.assertNotIn("blocker", feature)

    def test_audio_reset_and_ownership_have_dedicated_physical_lanes(
        self,
    ):
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        features = {row["id"]: row for row in manifest["features"]}
        reset = features["audio-media-services-reset"]
        self.assertEqual(reset["execution"], "operator-assisted")
        self.assertEqual(reset["evidenceLevel"], "system-output")
        self.assertEqual(reset["scenarioIds"], ["audio-media-services-reset"])
        self.assertEqual(reset["runnerScenarioIds"], ["audio-media-services-reset"])
        self.assertNotIn("blocker", reset)
        ownership = features["audio-session-ownership"]
        self.assertEqual(ownership["execution"], "automated")
        self.assertEqual(ownership["evidenceLevel"], "system-output")
        self.assertEqual(ownership["scenarioIds"], ["audio-session-ownership"])
        self.assertEqual(ownership["runnerScenarioIds"], ["audio-session-ownership"])
        self.assertNotIn("blocker", ownership)
        for profile_name in ("full", "release"):
            with self.subTest(profile=profile_name):
                profile = self.profiles.profiles[profile_name]
                self.assertIn("audio-media-services-reset", profile.scenarios)
                self.assertIn("audio-session-ownership", profile.scenarios)

    def test_destructive_audio_reset_is_last_in_full_and_release_profiles(self):
        for profile_name in ("full", "release"):
            with self.subTest(profile=profile_name):
                scenarios = self.profiles.profiles[profile_name].scenarios
                self.assertEqual(scenarios[-1], "audio-media-services-reset")

    def test_full_and_release_require_native_renderer_recovery(self):
        scenario = "playback-foreground-displaylayer-recovery"
        self.assertIn(scenario, self.profiles.profiles["full"].scenarios)
        self.assertIn(scenario, self.profiles.profiles["release"].scenarios)
        self.assertIn(scenario, self.profiles.iphone_current_only_scenarios)
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        feature = next(row for row in manifest["features"] if row["id"] == scenario)
        self.assertEqual(feature["execution"], "automated")
        self.assertEqual(feature["scenarioIds"], [scenario])
        self.assertEqual(feature["runnerScenarioIds"], [scenario])
        self.assertNotIn("blocker", feature)

    def test_zero_boundary_seek_is_automated_only_by_the_raw_vod_controls_row(self):
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        feature = next(
            row
            for row in manifest["features"]
            if row["id"] == "seek-relative-zero-boundary"
        )
        self.assertEqual(feature["execution"], "automated")
        self.assertEqual(feature["scenarioIds"], ["vod-controls"])
        self.assertEqual(feature["runnerScenarioIds"], ["vod-controls"])
        self.assertNotIn("blocker", feature)

    def test_only_seek_and_frame_features_exercised_by_the_oracle_lane_are_promoted(
        self,
    ):
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        features = {row["id"]: row for row in manifest["features"]}
        exercised = {
            "seek-local-sparse-gop",
            "seek-overlap-cancellation",
            "frame-step-exact-presentation",
            "frame-step-burst",
            "frame-step-resume-clock",
            "frame-step-eof-transition-safety",
        }
        for feature_id in exercised:
            with self.subTest(feature=feature_id):
                feature = features[feature_id]
                self.assertEqual(feature["execution"], "automated")
                self.assertEqual(feature["scenarioIds"], ["seek-frame-oracles"])
                self.assertEqual(feature["runnerScenarioIds"], ["seek-frame-oracles"])
                self.assertNotIn("blocker", feature)
        progressive = features["seek-progressive-http-range"]
        self.assertEqual(progressive["execution"], "automated")
        self.assertEqual(progressive["scenarioIds"], ["progressive-http-range-seek"])
        self.assertEqual(
            progressive["runnerScenarioIds"], ["progressive-http-range-seek"]
        )
        self.assertNotIn("blocker", progressive)
        for feature_id in {
            "seek-hls-before-playback",
            "seek-streamed-ogg-opus-backward",
            "seek-degraded-network-recovery",
            "seek-network-ts-repeated",
        }:
            with self.subTest(unexercised=feature_id):
                self.assertEqual(features[feature_id]["execution"], "planned")

    def test_every_physical_profile_runs_progressive_http_range_seek(self):
        for name, profile in self.profiles.profiles.items():
            with self.subTest(profile=name):
                self.assertIn("progressive-http-range-seek", profile.scenarios)

    def test_every_profile_retains_its_required_support_lanes(self):
        for name, required in qualify.REQUIRED_SUPPORT_SCENARIOS.items():
            with self.subTest(profile=name):
                self.assertTrue(
                    required.issubset(self.profiles.profiles[name].scenarios)
                )

    def test_release_cannot_drop_an_automated_feature_lane_or_mandatory_soak(self):
        payload = json.loads((QUALIFICATION / "profiles-v1.json").read_text())
        for removed in ("vod-controls", "adaptive-hls-soak", "analyzer"):
            with self.subTest(
                removed=removed
            ), tempfile.TemporaryDirectory() as temporary:
                mutated = json.loads(json.dumps(payload))
                mutated["profiles"]["release"]["scenarios"].remove(removed)
                path = Path(temporary) / "profiles.json"
                path.write_text(json.dumps(mutated))
                with self.assertRaises(qualify.ConfigurationError):
                    qualify.load_profiles(path)

    def test_release_profile_cannot_reorder_the_immutable_runner_sequence(self):
        payload = json.loads((QUALIFICATION / "profiles-v1.json").read_text())
        scenarios = payload["profiles"]["release"]["scenarios"]
        scenarios[0], scenarios[1] = scenarios[1], scenarios[0]
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profiles.json"
            path.write_text(json.dumps(payload))
            with self.assertRaisesRegex(
                qualify.ConfigurationError, "coverage or order"
            ):
                qualify.load_profiles(path)

    def test_full_cannot_drop_seek_frame_oracle_rehearsal(self):
        payload = json.loads((QUALIFICATION / "profiles-v1.json").read_text())
        payload["profiles"]["full"]["scenarios"].remove("seek-frame-oracles")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profiles.json"
            path.write_text(json.dumps(payload))
            with self.assertRaises(qualify.ConfigurationError):
                qualify.load_profiles(path)

    def test_frame_step_exact_presentation_remains_a_required_feature_obligation(self):
        manifest = json.loads((QUALIFICATION / "feature-manifest-v1.json").read_text())
        feature = next(
            row
            for row in manifest["features"]
            if row["id"] == "frame-step-exact-presentation"
        )
        feature["releaseRequirement"] = "advisory"
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "features.json"
            path.write_text(json.dumps(manifest))
            with self.assertRaises(qualify.ConfigurationError):
                qualify.load_profiles(
                    QUALIFICATION / "profiles-v1.json", feature_manifest_path=path
                )

    def test_one_hour_profile_does_not_misrepresent_shortened_soaks(self):
        full = self.profiles.profiles["full"]
        self.assertEqual(full.expected_duration_minutes, 60)
        self.assertFalse(
            set(full.scenarios)
            & {
                "adaptive-hls-soak",
                "timebase-vod-soak",
                "timebase-live-soak",
                "pip-render-performance-1080p60",
                "pip-render-performance-4k60",
                "cadence-matrix",
                "native-subtitle-matrix",
            }
        )

    def test_non_current_device_filters_current_only_lanes(self):
        profile = self.profiles.profiles["full"]
        selected, inapplicable = qualify.applicable_scenarios(
            profile,
            self.profiles,
            {"matchingHardwareRows": ["ipad-minimum"]},
            exploratory_current_only=False,
        )
        self.assertIn("vod-controls", selected)
        self.assertNotIn("capability-convergence", selected)
        self.assertIn("capability-convergence", inapplicable)

    def test_future_iphone_can_run_current_lanes_only_when_explicitly_exploratory(self):
        profile = self.profiles.profiles["full"]
        selected, _ = qualify.applicable_scenarios(
            profile,
            self.profiles,
            {"matchingHardwareRows": []},
            exploratory_current_only=True,
        )
        self.assertIn("capability-convergence", selected)

    def test_unmatched_device_cannot_enter_runner_without_explicit_policy(self):
        with self.assertRaisesRegex(
            qualify.ConfigurationError, "does not match a qualification hardware row"
        ):
            qualify.applicable_scenarios(
                self.profiles.profiles["smoke"],
                self.profiles,
                {"matchingHardwareRows": []},
                exploratory_current_only=False,
            )

    def test_unknown_or_duplicate_scenarios_are_rejected(self):
        payload = json.loads((QUALIFICATION / "profiles-v1.json").read_text())
        payload["profiles"]["smoke"]["scenarios"].append("not-a-runner-scenario")
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "profiles.json"
            path.write_text(json.dumps(payload))
            with self.assertRaises(qualify.ConfigurationError):
                qualify.load_profiles(path)

    def test_dry_run_never_attempts_device_discovery(self):
        external_work = Path("/Volumes/External/SwiftVLC-Work")
        result = subprocess.run(
            [
                sys.executable,
                str(QUALIFICATION / "qualify.py"),
                "smoke",
                "--dry-run",
                "--version",
                "1.1.0-beta.9",
                "--development-team",
                "ABCDE12345",
                "--work-root",
                str(external_work),
            ],
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Dry run only", result.stdout)
        self.assertIn("--only vod-controls", result.stdout)
        self.assertIn(f"--work-root {external_work}", result.stdout)
        self.assertIn("--development-team ABCDE12345", result.stdout)

    def test_profile_run_requires_exact_candidate_version(self):
        environment = dict(os.environ, SWIFTVLC_DEVELOPMENT_TEAM="ABCDE12345")
        result = subprocess.run(
            [
                sys.executable,
                str(QUALIFICATION / "qualify.py"),
                "smoke",
                "--dry-run",
            ],
            text=True,
            capture_output=True,
            env=environment,
        )

        self.assertEqual(result.returncode, 2)
        self.assertIn("--version is required", result.stderr)

    def test_trusted_policy_and_runner_paths_have_no_cli_override(self):
        for option in ("--runner", "--checklist", "--profiles", "--features"):
            with self.subTest(option=option):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(QUALIFICATION / "qualify.py"),
                        "smoke",
                        "--version",
                        "1.1.0-beta.9",
                        option,
                        "/tmp/untrusted",
                    ],
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("unrecognized arguments", result.stderr)

    def test_trusted_postprocessor_is_materialized_from_commit_and_detects_drift(self):
        source_identity = qualify._source_authority_identity("1.1.0-beta.9")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            trusted = qualify._snapshot_trusted_postprocessor(root, source_identity)
            qualify._validate_trusted_postprocessor(trusted, source_identity)
            relative = "scripts/qualification/feature-checklist.py"
            expected = subprocess.check_output(
                [
                    "git",
                    "-C",
                    str(QUALIFICATION.parents[1]),
                    "show",
                    f"{source_identity['sourceCommit']}:{relative}",
                ]
            )
            snapshotted = trusted["root"] / relative
            self.assertEqual(snapshotted.read_bytes(), expected)

            snapshotted.chmod(0o644)
            snapshotted.write_bytes(expected + b"\n# drift\n")
            with self.assertRaisesRegex(
                qualify.ConfigurationError, "identity changed"
            ):
                qualify._validate_trusted_postprocessor(trusted, source_identity)

    def test_profile_rejects_malformed_or_out_of_series_version_before_discovery(self):
        for version in ("1.1.0-not semver", "1.1.0+local", "2.0.0-beta.1"):
            with self.subTest(version=version):
                with (
                    mock.patch.object(qualify, "resolve_device") as resolve_device,
                    self.assertRaises(SystemExit) as raised,
                ):
                    qualify.main(
                        [
                            "smoke",
                            "--version",
                            version,
                            "--development-team",
                            "ABCDE12345",
                        ]
                    )
                self.assertEqual(raised.exception.code, 2)
                resolve_device.assert_not_called()

    def test_direct_runner_rejects_version_before_creating_a_device_run(self):
        for version in ("1.1.0-not-semver.01", "2.0.0-beta.1"):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary) / "results"
                result = subprocess.run(
                    [
                        str(QUALIFICATION / "run-device-tests.sh"),
                        "--version",
                        version,
                        "--skip-build",
                        "--output",
                        str(output),
                    ],
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn("release series 1.1.0", result.stderr)
                self.assertFalse(output.exists())

    def test_building_requires_a_valid_explicit_development_team(self):
        for extra_arguments, expected in (
            ([], "--development-team"),
            (
                ["--development-team", "invalid-team"],
                "10-character Apple team identifier",
            ),
        ):
            with self.subTest(arguments=extra_arguments):
                result = subprocess.run(
                    [
                        sys.executable,
                        str(QUALIFICATION / "qualify.py"),
                        "smoke",
                        "--dry-run",
                        "--version",
                        "1.1.0-beta.9",
                        *extra_arguments,
                    ],
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)

    def test_development_team_environment_is_validated_and_forwarded(self):
        environment = dict(os.environ, SWIFTVLC_DEVELOPMENT_TEAM="ABCDE12345")
        result = subprocess.run(
            [
                sys.executable,
                str(QUALIFICATION / "qualify.py"),
                "smoke",
                "--dry-run",
                "--version",
                "1.1.0-beta.9",
            ],
            text=True,
            capture_output=True,
            env=environment,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--development-team ABCDE12345", result.stdout)

        environment["SWIFTVLC_DEVELOPMENT_TEAM"] = "bad"
        rejected = subprocess.run(
            [
                sys.executable,
                str(QUALIFICATION / "qualify.py"),
                "smoke",
                "--dry-run",
                "--version",
                "1.1.0-beta.9",
            ],
            text=True,
            capture_output=True,
            env=environment,
        )
        self.assertEqual(rejected.returncode, 2)
        self.assertIn("10-character Apple team identifier", rejected.stderr)

    def test_only_release_checklist_enforces_required_feature_completeness(self):
        arguments = Namespace(
            checklist=QUALIFICATION / "feature-checklist.py",
            features=QUALIFICATION / "feature-manifest-v1.json",
            matrix=QUALIFICATION / "matrix.json",
        )
        report = Path("/tmp/device/report.json")
        full = qualify.build_checklist_command(
            arguments, report, require_complete=False
        )
        release = qualify.build_checklist_command(
            arguments, report, require_complete=True
        )
        self.assertNotIn("--require-complete", full)
        self.assertEqual(release[-1], "--require-complete")

    def test_checklist_handoff_requires_bound_complete_outputs_and_exact_exit(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / "report.json"
            identity = {
                "version": "1.1.0-beta.9",
                "sourceCommit": "a" * 40,
                "releaseSourceDigest": "b" * 64,
                "artifactDigest": "c" * 64,
                "candidateAppDigest": "d" * 64,
                "featureManifestChecksum": qualify.policy.sha256_file(
                    QUALIFICATION / "feature-manifest-v1.json"
                ),
                "qualificationMatrixChecksum": qualify.policy.sha256_file(
                    QUALIFICATION / "matrix.json"
                ),
            }
            report.write_text(json.dumps(identity))
            arguments = Namespace(
                features=QUALIFICATION / "feature-manifest-v1.json",
                checklist=QUALIFICATION / "feature-checklist.py",
                version="1.1.0-beta.9",
            )

            with mock.patch.object(
                qualify.report_validation, "is_valid", return_value=True
            ):
                with self.assertRaises(qualify.ConfigurationError):
                    qualify.validate_checklist_handoff(
                        arguments, self.profiles.profiles["full"], report, 0
                    )

            checklist = {
                **identity,
                "formatVersion": 2,
                "sourceKind": "deviceReport",
                "summary": {
                    "requiredFeaturesSatisfied": False,
                    "releaseReady": False,
                },
            }
            json_output = json.dumps(checklist, indent=2, sort_keys=True) + "\n"
            markdown_output = "# checklist\n"
            html_output = "<html></html>\n"
            (root / "feature-checklist.json").write_text(json_output)
            (root / "feature-checklist.md").write_text(markdown_output)
            (root / "feature-checklist.html").write_text(html_output)

            def validate(profile: str, exit_code: int) -> dict:
                with (
                    mock.patch.object(
                        qualify.report_validation, "is_valid", return_value=True
                    ),
                    mock.patch.object(
                        qualify,
                        "_expected_checklist_outputs",
                        return_value=(
                            checklist,
                            json_output,
                            markdown_output,
                            html_output,
                        ),
                    ),
                ):
                    return qualify.validate_checklist_handoff(
                        arguments,
                        self.profiles.profiles[profile],
                        report,
                        exit_code,
                    )

            validate("full", 0)
            with (
                mock.patch.object(
                    qualify.report_validation, "is_valid", return_value=True
                ),
                mock.patch.object(
                    qualify,
                    "_expected_checklist_outputs",
                    return_value=(
                        checklist,
                        json_output,
                        markdown_output,
                        html_output,
                    ),
                ),
                self.assertRaisesRegex(
                    qualify.ConfigurationError, "current orchestrator session"
                ),
            ):
                qualify.validate_checklist_handoff(
                    arguments,
                    self.profiles.profiles["full"],
                    report,
                    0,
                    expected_session_binding="9" * 64,
                )
            with (
                mock.patch.object(
                    qualify.report_validation, "is_valid", return_value=True
                ),
                self.assertRaisesRegex(
                    qualify.ConfigurationError, "session source authority"
                ),
            ):
                qualify.validate_checklist_handoff(
                    arguments,
                    self.profiles.profiles["full"],
                    report,
                    0,
                    expected_source_authority={
                        "sourceCommit": "f" * 40,
                        "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
                        "releaseSourceDigest": "e" * 64,
                    },
                )
            (root / "feature-checklist.md").write_text("# forged checklist\n")
            with self.assertRaisesRegex(
                qualify.ConfigurationError, "independent rendering"
            ):
                validate("full", 0)
            (root / "feature-checklist.md").write_text(markdown_output)
            with self.assertRaises(qualify.ConfigurationError):
                validate("full", 1)
            validate("release", 1)
            with self.assertRaises(qualify.ConfigurationError):
                validate("release", 0)

            arguments.version = "1.1.0-beta.10"
            with self.assertRaisesRegex(
                qualify.ConfigurationError, "requested candidate"
            ):
                validate("full", 0)
            arguments.version = "1.1.0-beta.9"

            with mock.patch.object(
                qualify.report_validation, "is_valid", return_value=False
            ), self.assertRaisesRegex(
                qualify.ConfigurationError, "successful-validation receipt"
            ):
                qualify.validate_checklist_handoff(
                    arguments, self.profiles.profiles["full"], report, 1
                )

            original_report = report.read_text()

            def mutate_report_during_render(*_args):
                report.write_text(json.dumps({**identity, "result": "forged"}))
                return checklist, json_output, markdown_output, html_output

            with (
                mock.patch.object(
                    qualify.report_validation, "is_valid", return_value=True
                ),
                mock.patch.object(
                    qualify,
                    "_expected_checklist_outputs",
                    side_effect=mutate_report_during_render,
                ),
                self.assertRaisesRegex(
                    qualify.ConfigurationError, "changed during checklist handoff"
                ),
            ):
                qualify.validate_checklist_handoff(
                    arguments, self.profiles.profiles["full"], report, 0
                )
            report.write_text(original_report)

            checklist["summary"]["requiredFeaturesSatisfied"] = True
            json_output = json.dumps(checklist, indent=2, sort_keys=True) + "\n"
            (root / "feature-checklist.json").write_text(json_output)
            validate("release", 0)
            with self.assertRaises(qualify.ConfigurationError):
                validate("release", 1)

    def test_checklist_handoff_reconstructs_with_canonical_not_override_renderer(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_marker = root / "fake-renderer-imported"
            fake_renderer = root / "fake-checklist.py"
            fake_renderer.write_text(
                "from pathlib import Path\n"
                f"Path({str(fake_marker)!r}).write_text('executed')\n"
                "def build_checklist(*args, **kwargs): return {'forged': True}\n"
                "def render_markdown(*args, **kwargs): return '# forged\\n'\n"
                "def render_html(*args, **kwargs): return '<p>forged</p>\\n'\n"
            )
            report = root / "report.json"
            source = {
                "formatVersion": 2,
                "version": "1.1.0-beta.9",
                "sourceCommit": "a" * 40,
                "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
                "releaseSourceDigest": "b" * 64,
                "artifactDigestAlgorithm": "swiftvlc-tree-v1",
                "artifactDigest": "c" * 64,
                "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
                "candidateAppDigest": "d" * 64,
                "qualificationMatrixChecksum": qualify.policy.sha256_file(
                    QUALIFICATION / "matrix.json"
                ),
                "featureManifestChecksum": qualify.policy.sha256_file(
                    QUALIFICATION / "feature-manifest-v1.json"
                ),
                "mode": "exploratory",
                "qualificationEligibleEnvironment": False,
                "device": {
                    "matchingHardwareRows": ["iphone-current"],
                    "deviceFamily": "iPhone",
                    "osMajor": 26,
                    "name": "Fixture iPhone",
                },
                "scenarios": [],
                "qualificationRows": [],
            }
            report.write_text(json.dumps(source))
            arguments = Namespace(
                checklist=fake_renderer,
                features=QUALIFICATION / "feature-manifest-v1.json",
                version=source["version"],
            )
            expected = qualify._expected_checklist_outputs(arguments, source, report)
            self.assertNotEqual(expected[0], {"forged": True})
            self.assertFalse(fake_marker.exists())

    def test_only_release_runner_can_claim_canonical_full_suite_selection(self):
        arguments = Namespace(
            runner=QUALIFICATION / "run-device-tests.sh",
            version="1.1.0",
            development_team="ABCDE12345",
            candidate_app=None,
            candidate_metadata=None,
            xctestrun=None,
            derived_data=None,
            work_root=None,
            fixtures=None,
            exploratory_current_only=False,
            skip_build=False,
        )
        selected_device = "00008101-FIXTURE"
        for profile_name in ("full", "release"):
            with self.subTest(profile=profile_name):
                profile = self.profiles.profiles[profile_name]
                command = qualify.build_runner_command(
                    arguments,
                    profile,
                    selected_device,
                    profile.scenarios,
                    Path("/tmp/qualification-output"),
                    profile.stable_environment_required,
                )
                if profile_name == "release":
                    self.assertIn("--full-suite-selection", command)
                else:
                    self.assertNotIn("--full-suite-selection", command)
        self.assertNotIn(
            "--full-suite-selection",
            qualify._device_command(selected_device, require_stable=True),
        )

    def test_runner_command_binds_the_fresh_orchestrator_session(self):
        arguments = Namespace(
            runner=QUALIFICATION / "run-device-tests.sh",
            version="1.1.0-beta.9",
            orchestrator_session_binding="9" * 64,
            orchestrator_started_at_utc="2026-09-02T00:00:00Z",
            development_team="ABCDE12345",
            candidate_app=None,
            candidate_metadata=None,
            xctestrun=None,
            derived_data=None,
            work_root=None,
            fixtures=None,
            exploratory_current_only=False,
            skip_build=False,
        )
        command = qualify.build_runner_command(
            arguments,
            self.profiles.profiles["smoke"],
            "00008101-FIXTURE",
            ["analyzer"],
            Path("/tmp/qualification-output"),
            False,
        )
        binding_index = command.index("--orchestrator-session-binding")
        started_index = command.index("--orchestrator-started-at-utc")
        self.assertEqual(command[binding_index + 1], "9" * 64)
        self.assertEqual(command[started_index + 1], "2026-09-02T00:00:00Z")

    def test_successful_beta_full_run_is_completed_but_not_release_passed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            beta_device = {
                **self.fixture_device(),
                "osVersion": "26.1",
                "osBuild": "23B5010a",
                "osReleaseType": "beta",
                "qualificationEligible": False,
            }
            calls = 0

            def run_process(command: list[str], **_: object) -> subprocess.CompletedProcess:
                nonlocal calls
                calls += 1
                if calls == 1:
                    runner_output = Path(command[command.index("--output") + 1])
                    retained = runner_output / "retained-run"
                    retained.mkdir(parents=True)
                    (retained / "report.json").write_text("{}\n")
                return subprocess.CompletedProcess(command, 0)

            checklist = {
                "summary": {
                    "requiredFeaturesSatisfied": False,
                    "releaseReady": False,
                },
                "scope": {
                    "releaseCreditEligible": False,
                    "evidenceClass": "exploratoryObservation",
                },
            }
            with (
                mock.patch.object(
                    qualify, "resolve_device", return_value=beta_device
                ),
                mock.patch.object(
                    qualify, "_session_directory", return_value=session_dir
                ),
                mock.patch.object(qualify.subprocess, "run", side_effect=run_process),
                mock.patch.object(
                    qualify,
                    "validate_checklist_handoff",
                    return_value=checklist,
                ),
            ):
                status = qualify.main(
                    [
                        "full",
                        "--version",
                        "1.1.0-beta.9",
                        "--development-team",
                        "ABCDE12345",
                        "--output",
                        str(root / "results"),
                    ]
                )

            self.assertEqual(status, 0)
            session = json.loads((session_dir / "session.json").read_text())
            self.assertEqual(session["status"], "completed")
            self.assertTrue(session["executionCompleted"])
            self.assertTrue(session["validatedReportAvailable"])
            self.assertEqual(session["reportValidationStatus"], "validated")
            self.assertFalse(session["releaseCreditEligible"])
            self.assertFalse(session["requiredFeaturesSatisfied"])
            self.assertFalse(session["releaseQualificationComplete"])
            self.assertEqual(session["checklistCompletionStatus"], "incomplete")
            self.assertEqual(session["evidenceClass"], "exploratoryObservation")

    def test_runner_setup_failure_emits_non_credit_incomplete_handoff(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            runner = root / "failing-runner.py"
            runner.write_text("#!/usr/bin/env python3\nraise SystemExit(23)\n")
            runner.chmod(0o755)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    qualify, "resolve_device", return_value=self.fixture_device()
                ),
                mock.patch.object(
                    qualify, "_session_directory", return_value=session_dir
                ),
                mock.patch.object(qualify, "DEFAULT_RUNNER", runner),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                status = qualify.main(
                    [
                        "smoke",
                        "--version",
                        "1.1.0-beta.9",
                        "--development-team",
                        "ABCDE12345",
                        "--output",
                        str(root / "results"),
                    ]
                )

            self.assertEqual(status, 23)
            summary_path = session_dir / "incomplete-execution-summary.json"
            markdown_path = session_dir / "incomplete-execution-summary.md"
            summary = json.loads(summary_path.read_text())
            session = json.loads((session_dir / "session.json").read_text())
            self.assertEqual(summary["status"], "incomplete")
            self.assertEqual(summary["termination"], "runner-exited-without-one-report")
            self.assertEqual(summary["runnerExitCode"], 23)
            self.assertFalse(summary["releaseCreditEligible"])
            self.assertEqual(summary["reportValidationStatus"], "no-validated-report")
            self.assertIsNone(summary["validatedReport"])
            self.assertEqual(summary["validatedFeatureResults"], [])
            self.assertEqual(summary["validatedScenarioResults"], [])
            self.assertEqual(summary["completedLaneDiagnostics"], [])
            self.assertEqual(
                summary["notCompletedSelectedLanes"],
                list(self.profiles.profiles["smoke"].scenarios),
            )
            self.assertEqual(
                summary["retainedEvidenceDirectory"],
                str(session_dir / "device-run"),
            )
            self.assertTrue((session_dir / "device-run").is_dir())
            self.assertEqual(
                session["incompleteExecutionSummaryJSON"], str(summary_path)
            )
            self.assertEqual(
                session["incompleteExecutionSummaryMarkdown"], str(markdown_path)
            )
            self.assertFalse(session["releaseCreditEligible"])
            self.assertFalse(session["validatedReportAvailable"])
            markdown = markdown_path.read_text()
            self.assertIn("NO RELEASE CREDIT", markdown)
            self.assertIn("No validated device report was accepted", markdown)
            self.assertIn(
                "No validation plan or scenario ledger was retained", markdown
            )
            self.assertNotIn("scenario PASS", markdown)
            self.assertIn(str(summary_path), stdout.getvalue())
            self.assertIn(str(markdown_path), stdout.getvalue())
            self.assertIn("expected exactly one device report", stderr.getvalue())

    def test_rejected_report_emits_non_credit_incomplete_handoff(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            calls = 0

            def run_process(
                command: list[str], **_: object
            ) -> subprocess.CompletedProcess:
                nonlocal calls
                calls += 1
                if calls == 1:
                    runner_output = Path(command[command.index("--output") + 1])
                    retained = runner_output / "retained-run"
                    retained.mkdir(parents=True)
                    (retained / "report.json").write_text("{}\n")
                    return subprocess.CompletedProcess(command, 0)
                return subprocess.CompletedProcess(command, 2)

            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    qualify, "resolve_device", return_value=self.fixture_device()
                ),
                mock.patch.object(
                    qualify, "_session_directory", return_value=session_dir
                ),
                mock.patch.object(qualify.subprocess, "run", side_effect=run_process),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                status = qualify.main(
                    [
                        "smoke",
                        "--version",
                        "1.1.0-beta.9",
                        "--development-team",
                        "ABCDE12345",
                        "--output",
                        str(root / "results"),
                    ]
                )

            self.assertEqual(status, 2)
            summary_path = session_dir / "incomplete-execution-summary.json"
            markdown_path = session_dir / "incomplete-execution-summary.md"
            summary = json.loads(summary_path.read_text())
            session = json.loads((session_dir / "session.json").read_text())
            self.assertEqual(
                summary["termination"], "report-validation-or-rendering-failure"
            )
            self.assertEqual(summary["runnerExitCode"], 0)
            self.assertEqual(summary["checklistExitCode"], 2)
            self.assertEqual(summary["reportCandidateCount"], 1)
            self.assertEqual(len(summary["unvalidatedReportCandidates"]), 1)
            self.assertEqual(summary["reportValidationStatus"], "no-validated-report")
            self.assertFalse(summary["releaseCreditEligible"])
            self.assertEqual(session["status"], "failed")
            self.assertEqual(session["checklistExitCode"], 2)
            self.assertFalse(session["validatedReportAvailable"])
            markdown = markdown_path.read_text()
            self.assertIn("NO RELEASE CREDIT", markdown)
            self.assertIn("Checklist/validator exit code: `2`", markdown)
            self.assertIn("Unvalidated report candidates", markdown)
            self.assertIn(str(summary_path), stdout.getvalue())
            self.assertIn("was not accepted", stderr.getvalue())

    def test_interruption_retains_raw_outcomes_only_as_unvalidated_diagnostics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            selected = list(self.profiles.profiles["smoke"].scenarios)

            def interrupt_runner(command: list[str], **_: object) -> None:
                runner_output = Path(command[command.index("--output") + 1])
                retained = runner_output / "retained-run"
                retained.mkdir(parents=True)
                (retained / "validation-plan.json").write_text(
                    json.dumps(
                        {
                            "formatVersion": 2,
                            "selectionScope": "partial",
                            "reportOnly": False,
                            "requestedScenarioDrivers": selected,
                            "selectedScenarioDrivers": selected,
                            "skippedScenarioDrivers": [],
                            "matrixScenarioOutputsPlanned": ["fixture-output"],
                        }
                    )
                )
                (retained / "scenario-results.tsv").write_text(
                    "\t".join(
                        [
                            selected[0],
                            "pass",
                            "0",
                            "0",
                            "captured",
                            "not-applicable",
                            "9",
                            "/tmp/expected.json",
                            "/tmp/execution.json",
                            "/tmp/attempts.json",
                            "/tmp/inventory.json",
                        ]
                    )
                    + "\n"
                )
                raise KeyboardInterrupt

            stdout = io.StringIO()
            stderr = io.StringIO()
            with (
                mock.patch.object(
                    qualify, "resolve_device", return_value=self.fixture_device()
                ),
                mock.patch.object(
                    qualify, "_session_directory", return_value=session_dir
                ),
                mock.patch.object(
                    qualify.subprocess, "run", side_effect=interrupt_runner
                ),
                contextlib.redirect_stdout(stdout),
                contextlib.redirect_stderr(stderr),
            ):
                status = qualify.main(
                    [
                        "smoke",
                        "--version",
                        "1.1.0-beta.9",
                        "--development-team",
                        "ABCDE12345",
                        "--output",
                        str(root / "results"),
                    ]
                )

            self.assertEqual(status, 130)
            summary_path = session_dir / "incomplete-execution-summary.json"
            markdown_path = session_dir / "incomplete-execution-summary.md"
            summary = json.loads(summary_path.read_text())
            session = json.loads((session_dir / "session.json").read_text())
            self.assertEqual(summary["termination"], "operator-interrupted")
            self.assertEqual(summary["runnerExitCode"], 130)
            self.assertFalse(summary["releaseCreditEligible"])
            self.assertEqual(summary["validatedScenarioResults"], [])
            self.assertEqual(len(summary["completedLaneDiagnostics"]), 1)
            diagnostic = summary["completedLaneDiagnostics"][0]
            self.assertEqual(diagnostic["scenario"], selected[0])
            self.assertEqual(diagnostic["runnerOutcome"], "runner-reported-success")
            self.assertEqual(
                diagnostic["diagnosticStatus"], "completed-but-unvalidated"
            )
            self.assertFalse(diagnostic["releaseCreditEligible"])
            self.assertEqual(summary["notCompletedSelectedLanes"], selected[1:])
            self.assertEqual(len(summary["retainedValidationPlans"]), 1)
            self.assertTrue(summary["retainedValidationPlans"][0]["readable"])
            self.assertEqual(len(summary["retainedScenarioLedgers"]), 1)
            self.assertEqual(session["status"], "interrupted")
            self.assertFalse(session["releaseCreditEligible"])
            markdown = markdown_path.read_text()
            self.assertIn("NO RELEASE CREDIT", markdown)
            self.assertIn("runner-reported-success", markdown)
            self.assertIn("not validated and not eligible for release credit", markdown)
            self.assertIn(selected[1], markdown)
            self.assertNotIn("scenario PASS", markdown)
            self.assertIn(str(session_dir / "device-run"), stdout.getvalue())
            self.assertIn("was interrupted", stderr.getvalue())

    def test_incomplete_recovery_contains_malformed_artifacts_and_render_failures(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            session_dir = root / "session"
            runner_output = session_dir / "device-run"
            retained = runner_output / "retained-run"
            retained.mkdir(parents=True)
            (retained / "scenario-results.tsv").write_bytes(b"\xff\xfe")
            session = {
                "formatVersion": 1,
                "profile": "smoke",
                "version": "1.1.0-beta.9",
                "selectedScenarios": ["analyzer"],
                "status": "running",
            }
            qualify._write_json(session_dir / "session.json", session)

            with mock.patch.object(
                qualify,
                "_write_text",
                side_effect=OSError("simulated summary volume failure"),
            ):
                qualify._finish_incomplete_execution(
                    session_dir,
                    runner_output,
                    session,
                    session_status="failed",
                    termination="fixture-failure",
                    reason="runner stopped",
                    runner_exit_code=9,
                )

            retained_session = json.loads((session_dir / "session.json").read_text())
            self.assertEqual(retained_session["status"], "failed")
            self.assertFalse(retained_session["executionCompleted"])
            self.assertFalse(retained_session["releaseCreditEligible"])
            self.assertFalse(retained_session["releaseQualificationComplete"])
            self.assertEqual(
                retained_session["reportValidationStatus"], "unavailable"
            )
            self.assertIn("incompleteExecutionSummaryJSON", retained_session)
            self.assertNotIn("incompleteExecutionSummaryMarkdown", retained_session)
            self.assertIn(
                "simulated summary volume failure",
                "\n".join(retained_session["incompleteExecutionRecoveryErrors"]),
            )
            summary = json.loads(
                (session_dir / "incomplete-execution-summary.json").read_text()
            )
            self.assertIn("unreadable", "\n".join(summary["diagnosticWarnings"]))


if __name__ == "__main__":
    unittest.main()
