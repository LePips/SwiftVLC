from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path

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


if __name__ == "__main__":
    unittest.main()
