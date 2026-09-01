from __future__ import annotations

import contextlib
import errno
import http.client
import hashlib
import importlib.util
import io
import json
import os
import plistlib
import re
import subprocess
import tempfile
import threading
import time
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str):
    path = ROOT / "qualification" / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


qualification_policy = load_script("qualification_policy.py")
device_info = load_script("device-info.py")
exploratory_device_policy = load_script("exploratory-device-policy.py")
fixture_server = load_script("fixture-server.py")
prepare_xctestrun = load_script("prepare-xctestrun.py")
verify_fixtures = load_script("verify-fixtures.py")
candidate_metadata = load_script("candidate-metadata.py")
materialize_evidence = load_script("materialize-evidence.py")
augment_allocation_trace = load_script("augment-allocation-trace.py")
augment_performance_traces = load_script("augment-performance-traces.py")
augment_native_subtitle_traces = load_script("augment-native-subtitle-traces.py")
augment_timebase_evidence = load_script("augment-timebase-evidence.py")
assemble_record = load_script("assemble-record.py")


def timebase_raw_sample(
    elapsed: int,
    rate: float,
    media_time: float,
    *,
    generation: int = 1,
) -> dict:
    return {
        "kind": "sample",
        "clock": {
            "elapsedSeconds": elapsed,
            "mediaTimeSeconds": media_time,
            "driftSeconds": 0.01,
            "playbackGeneration": generation,
            "requestedRate": rate,
        },
        "audio": {
            "elapsedSeconds": elapsed,
            "mediaTimeSeconds": media_time,
            "estimatedPresentationSeconds": media_time - 0.01,
            "outputLatencySeconds": 0.005,
            "ioBufferDurationSeconds": 0.005,
            "playedBuffers": elapsed + 1,
            "lostBuffers": 0,
        },
        "frame": {
            "elapsedSeconds": elapsed,
            "playbackGeneration": generation,
            "deliveredFrames": elapsed + 1,
            "droppedFrames": 0,
            "presentedSeconds": media_time,
            "decodedFrames": elapsed + 1,
            "decodedFrameMediaTimeSeconds": media_time,
        },
    }


def timebase_raw_correction(
    sequence: int,
    reason: str = "steadyStateDrift",
    drift: float = 0.02,
) -> dict:
    return {
        "kind": "correction",
        "correction": {
            "sequence": sequence,
            "capturedAt": 1_700_000_000.0 + sequence,
            "systemUptime": 1_000.0 + sequence,
            "playbackGeneration": 1,
            "reason": reason,
            "mediaTimeSeconds": float(sequence),
            "previousTimebaseSeconds": float(sequence) - drift,
            "correctedTimebaseSeconds": float(sequence),
            "driftSeconds": drift,
        },
    }


class DeviceInfoTests(unittest.TestCase):
    def test_release_classification_is_fail_closed(self):
        self.assertEqual(device_info.release_type({"releaseType": "Beta"}), "beta")
        self.assertEqual(
            device_info.release_type({"osBuildUpdate": "24A5390f"}), "beta"
        )
        self.assertEqual(
            device_info.release_type({"osBuildUpdate": "20E772520a"}), "stable"
        )
        self.assertEqual(device_info.release_type({"osBuildUpdate": "23G80"}), "stable")
        self.assertEqual(
            device_info.release_type({"osBuildUpdate": "unexpected"}), "unknown"
        )
        self.assertEqual(
            device_info.release_type(
                {"releaseType": "stable", "osBuildUpdate": "24A5390f"}
            ),
            "unknown",
        )
        self.assertEqual(
            device_info.release_type({"releaseType": "beta", "osBuildUpdate": "23G80"}),
            "unknown",
        )

    def test_only_connected_stable_matching_device_qualifies(self):
        device = {
            "identifier": "core-id",
            "connectionProperties": {
                "tunnelState": "connected",
                "transportType": "wired",
            },
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

    def test_live_details_replace_a_dormant_list_snapshot(self):
        dormant = {
            "identifier": "core-id",
            "connectionProperties": {"tunnelState": "disconnected"},
            "deviceProperties": {"ddiServicesAvailable": False},
            "hardwareProperties": {"reality": "physical", "platform": "iOS"},
        }
        details = {
            "identifier": "core-id",
            "connectionProperties": {"tunnelState": "connected"},
            "deviceProperties": {"ddiServicesAvailable": True},
            "hardwareProperties": {"reality": "physical", "platform": "iOS"},
        }

        self.assertEqual(
            device_info.replace_device_snapshot([dormant], details),
            [details],
        )

    def test_unlisted_live_details_are_retained(self):
        details = {"identifier": "new-core-id"}
        self.assertEqual(
            device_info.replace_device_snapshot([], details),
            [details],
        )


class ExploratoryDevicePolicyTests(unittest.TestCase):
    matrix = {
        "hardware": [{"id": "iphone-current", "deviceFamily": "iPhone", "osMajor": 26}]
    }

    def record(self, **selected):
        return {
            "mode": "exploratory",
            "selected": {"deviceFamily": "iPhone", "osMajor": 27, **selected},
        }

    def test_future_iphone_os_can_run_current_only_lanes_exploratorily(self):
        self.assertTrue(
            exploratory_device_policy.permits_current_only(
                self.record(osReleaseType="beta"), self.matrix
            )
        )
        self.assertEqual(
            exploratory_device_policy.evidence_hardware_id(
                self.record(osReleaseType="beta"), self.matrix
            ),
            "exploratory-future-ios",
        )

    def test_matching_or_older_os_cannot_bypass_matrix_selection(self):
        self.assertFalse(
            exploratory_device_policy.permits_current_only(
                self.record(osMajor=26), self.matrix
            )
        )

    def test_ipad_cannot_borrow_the_iphone_current_lanes(self):
        self.assertFalse(
            exploratory_device_policy.permits_current_only(
                self.record(deviceFamily="iPad"), self.matrix
            )
        )

    def test_qualification_mode_never_uses_the_exploratory_override(self):
        record = self.record()
        record["mode"] = "qualification"
        self.assertFalse(
            exploratory_device_policy.permits_current_only(record, self.matrix)
        )


class QualificationRunnerStorageTests(unittest.TestCase):
    def test_runner_requires_the_release_oracle_decoder_tools(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            "for command in curl ffmpeg ffprobe git jq python3 shasum tar xcodebuild xcrun",
            script,
        )

    def test_every_xcode_test_invocation_uses_the_configured_derived_data(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        lines = script.splitlines()
        commands = []
        for index, line in enumerate(lines):
            if "xcodebuild test-without-building" not in line:
                continue
            command = [line]
            while command[-1].rstrip().endswith("\\"):
                index += 1
                command.append(lines[index])
            commands.append("\n".join(command))

        self.assertGreater(len(commands), 0)
        for command in commands:
            self.assertIn('-derivedDataPath "$DERIVED_DATA"', command)

    def test_runner_binds_retry_lifecycle_and_raw_error_attempt_evidence(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn('--expected-catalog "$scenario_expected_catalog"', script)
        self.assertIn("build-error-inventory", script)
        self.assertIn("bind-attempt-artifacts \\", script)
        self.assertIn('--artifact-root "$OUTPUT_DIR"', script)
        self.assertIn('--source-prefix "$run_id-$scenario"', script)
        self.assertIn('--retained-root "$scenario-raw-jsonl"', script)
        self.assertIn('--retained-base "$OUTPUT_DIR"', script)
        self.assertIn('--retained-root-base "$OUTPUT_DIR"', script)
        self.assertIn("--require-retained-artifacts", script)
        self.assertIn('--error-inventory "$error_inventory"', script)
        self.assertIn('"attempts": attempts', script)
        self.assertIn('"hostErrorInventory": error_inventory', script)

    def test_runner_wires_seek_frame_oracle_as_one_candidate_bound_lane(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            '"iOSUITests/SeekFrameOracleDeviceUITests/test_seekAndFrameRequestsMatchDecodedContent"',
            script,
        )
        self.assertIn('route="SeekFrameOracleValidation"', script)
        self.assertIn("SWIFTVLC_SEEK_FRAME_ORACLE_DEVICE=YES", script)
        self.assertIn("SWIFTVLC_SEEK_FRAME_ORACLE_BASE_URL_BASE64", script)
        self.assertIn(
            'qualification_attachments=("qualification-seek-frame-oracles.json")',
            script,
        )
        self.assertIn('select(.kind == "candidateExcludingPrefixes")', script)
        self.assertIn(
            'test_selection_args+=("-skip-testing:${excluded_prefix%/}")', script
        )
        self.assertNotIn(
            "-skip-testing:iOSUITests/SeekFrameOracleDeviceUITests", script
        )

    def test_runner_wires_progressive_http_range_as_host_transcript_lane(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        test_identifier = (
            "iOSUITests/ProgressiveHTTPRangeSeekDeviceUITests/"
            "test_progressiveRangeSeekUsesFresh206AndNoRangeRejectsStrictly"
        )
        self.assertIn(f'"{test_identifier}"', script)
        self.assertIn('route="ProgressiveHTTPRangeSeekValidation"', script)
        for environment in (
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_DEVICE=YES",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES",
            "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_ATTEMPT_TOKEN",
        ):
            self.assertIn(environment, script)
        self.assertIn('"$BASE_URL/progressive/$attempt_token/transcript"', script)
        self.assertIn(
            '--progressive-transcripts "$progressive_transcript_root"', script
        )
        self.assertIn(
            'qualification_attachments=("qualification-progressive-http-range-seek.json")',
            script,
        )

        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {row["id"]: row for row in matrix["runnerContracts"]}
        self.assertEqual(
            contracts["progressive-http-range-seek"]["outputs"],
            [
                {
                    "scenario": "progressive-http-range-seek",
                    "attachmentName": "qualification-progressive-http-range-seek.json",
                    "testIdentifiers": [test_identifier],
                }
            ],
        )
        self.assertIn(
            "iOSUITests/ProgressiveHTTPRangeSeekDeviceUITests/",
            contracts["ui-suite"]["selection"]["prefixes"],
        )
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "ProgressiveHTTPRangeSeekDeviceUITests.swift"
        ).read_text()
        self.assertIn(f"func {test_identifier.rsplit('/', 1)[1]}() throws", source)
        self.assertEqual(source.count("attachQualificationEvidence("), 1)
        self.assertIn('scenario: "progressive-http-range-seek"', source)
        self.assertNotIn('"responseStatus"', source)
        self.assertNotIn('"postCommand206"', source)
        self.assertNotIn("if mode == .range {\n      visual", source)
        self.assertNotIn("markCommand(", source)
        self.assertNotIn("commandPath(token:", source)
        self.assertLess(source.index("reveal(command"), source.index("command.tap()"))

        validation_source = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "ProgressiveHTTPRangeSeekValidationCase.swift"
        ).read_text()
        self.assertIn(".aspectRatio(16 / 9, contentMode: .fit)", validation_source)
        self.assertNotIn(".frame(height: 230)", validation_source)
        self.assertIn(
            "ProcessInfo.processInfo.systemUptime - start.systemUptimeSeconds >= 1",
            validation_source,
        )
        self.assertIn(
            "ProgressiveHTTPRangeSeekContract.commandOriginHeader",
            validation_source,
        )
        self.assertIn(
            "ProgressiveHTTPRangeSeekContract.commandOrigin",
            validation_source,
        )
        self.assertIn(
            "try await markCommand(token: attemptToken, mode: mode)\n"
            "        let request = try player.requestSeek(",
            validation_source,
        )
        self.assertIn(
            "try await markCommand(token: attemptToken, mode: mode)\n"
            "        do {\n"
            "          _ = try player.requestSeek(",
            validation_source,
        )
        self.assertIn('"captureSystemUptimeIntervals": captureIntervals', source)
        self.assertNotIn('"captureSystemUptimeSeconds"', source)

    def test_runner_wires_native_renderer_recovery_as_one_physical_lane(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            '"iOSUITests/NativeRendererRecoveryDeviceUITests/'
            'test_pausedNativeRendererRecoversAfterRealOSRevocation"',
            script,
        )
        self.assertIn('route="NativeRendererRecoveryValidation"', script)
        self.assertIn("SWIFTVLC_NATIVE_RENDERER_RECOVERY_DEVICE=YES", script)
        self.assertIn("SWIFTVLC_NATIVE_RENDERER_RECOVERY_URL_BASE64", script)
        self.assertIn(
            "qualification_attachments=("
            '"qualification-playback-foreground-displaylayer-recovery.json")',
            script,
        )
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {row["id"]: row for row in matrix["runnerContracts"]}
        contract = contracts["playback-foreground-displaylayer-recovery"]
        self.assertEqual(
            contract["outputs"],
            [
                {
                    "scenario": "playback-foreground-displaylayer-recovery",
                    "attachmentName": (
                        "qualification-playback-foreground-displaylayer-recovery.json"
                    ),
                    "testIdentifiers": [
                        "iOSUITests/NativeRendererRecoveryDeviceUITests/"
                        "test_pausedNativeRendererRecoversAfterRealOSRevocation"
                    ],
                }
            ],
        )
        excluded = set(contracts["ui-suite"]["selection"]["prefixes"])
        self.assertIn("iOSUITests/NativeRendererRecoveryDeviceUITests/", excluded)

    def test_runner_wires_exact_candidate_bound_local_playback_lanes(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        expected = {
            "local-file-matrix": {
                "test": (
                    "iOSUITests/LocalPlaybackMatrixDeviceUITests/"
                    "test_localFileContainerCodecMatrixProducesMovingVideo"
                ),
                "route": "LocalFileMatrixValidation",
                "attachment": "qualification-local-file-matrix.json",
            },
            "audio-only-playback": {
                "test": (
                    "iOSUITests/AudioOnlyPlaybackDeviceUITests/"
                    "test_audioOnlyCodecMatrixAdvancesNativeOutput"
                ),
                "route": "AudioOnlyPlaybackValidation",
                "attachment": "qualification-audio-only-playback.json",
            },
        }
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {row["id"]: row for row in matrix["runnerContracts"]}
        excluded = set(contracts["ui-suite"]["selection"]["prefixes"])
        for scenario, contract in expected.items():
            with self.subTest(scenario=scenario):
                self.assertIn(f'"{contract["test"]}"', script)
                self.assertIn(f'route="{contract["route"]}"', script)
                self.assertIn(
                    f'qualification_attachments=("{contract["attachment"]}")',
                    script,
                )
                self.assertEqual(
                    contracts[scenario]["outputs"],
                    [
                        {
                            "scenario": scenario,
                            "attachmentName": contract["attachment"],
                            "testIdentifiers": [contract["test"]],
                        }
                    ],
                )
                class_name = contract["test"].split("/", 2)[1]
                self.assertIn(f"iOSUITests/{class_name}/", excluded)
                source = (
                    ROOT.parent
                    / "Showcase"
                    / "UITests"
                    / "iOS"
                    / "Tests"
                    / f"{class_name}.swift"
                ).read_text()
                method_name = contract["test"].rsplit("/", 1)[1]
                self.assertRegex(
                    source,
                    rf"func {re.escape(method_name)}\(\)(?: async)? throws",
                )
                self.assertEqual(source.count("attachQualificationEvidence("), 1)
                self.assertIn(f'scenario: "{scenario}"', source)
        self.assertIn("SWIFTVLC_LOCAL_PLAYBACK_DEVICE=YES", script)
        self.assertIn("SWIFTVLC_LOCAL_PLAYBACK_BASE_URL_BASE64", script)
        self.assertIn(
            'cp "$FIXTURES/manifest.json" "$OUTPUT_DIR/fixture-manifest.json"', script
        )
        video_source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "LocalPlaybackMatrixDeviceUITests.swift"
        ).read_text()
        app_source = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "LocalPlaybackQualificationValidationCases.swift"
        ).read_text()
        self.assertIn('waitForLabel(result, equals: "measuring"', video_source)
        self.assertIn('result = "measuring"', app_source)

    def test_reset_lane_uses_a_per_attempt_four_hour_hls_timeline(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            'attempt_token="$run_id-audio-reset-$attempt"',
            script,
        )
        self.assertIn(
            'reset_url="$BASE_URL/adaptive/$attempt_token/'
            'timebase-vod-ts/master.m3u8"',
            script,
        )
        self.assertIn(
            "SWIFTVLC_AUDIO_MEDIA_SERVICES_RESET_URL_BASE64",
            script,
        )
        self.assertNotIn(
            '"audio-media-services-reset" ]]; then\n'
            '        attempt_token="$run_id-audio-reset-$attempt"\n'
            '        local reset_url="$BASE_URL/live/',
            script,
        )

    def test_reset_operator_prompt_waits_for_candidate_readiness_marker(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        branch = re.search(
            r'elif \[\[ "\$scenario" == "audio-media-services-reset" \]\]; then\n'
            r"(?P<body>(?:(?!\n    (?:elif|else|fi)\b).)*)\n"
            r"    else\n",
            script,
            re.DOTALL,
        )
        self.assertIsNotNone(branch)
        body = branch.group("body")
        marker = "SWIFTVLC_AUDIO_RESET_READY_FOR_OPERATOR:$attempt_token"
        self.assertIn(marker, body)
        self.assertIn('> "$attempt_log" 2>&1 &', body)
        self.assertIn('grep -Fq -- "$reset_readiness_marker" "$attempt_log"', body)
        self.assertLess(
            body.index("xcodebuild test-without-building"),
            body.index("ACTION REQUIRED"),
        )
        self.assertLess(
            body.index('grep -Fq -- "$reset_readiness_marker"'),
            body.index("ACTION REQUIRED"),
        )
        self.assertIn('if [[ "$reset_ready" != true ]]; then', body)
        self.assertIn("test_status=1", body)

    def test_ownership_lane_injects_a_per_attempt_four_hour_hls_timeline(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            'attempt_token="$run_id-audio-ownership-$attempt"',
            script,
        )
        self.assertIn(
            'ownership_url="$BASE_URL/adaptive/$attempt_token/'
            'timebase-vod-ts/master.m3u8"',
            script,
        )
        self.assertIn(
            "ownership_url_base64=$(printf '%s' \"$ownership_url\" "
            "| base64 | tr -d '\\r\\n')",
            script,
        )
        self.assertIn(
            "--environment SWIFTVLC_AUDIO_SESSION_OWNERSHIP_URL_BASE64="
            '"$ownership_url_base64"',
            script,
        )
        self.assertNotIn(
            '"audio-session-ownership" ]]; then\n'
            '        attempt_token="$run_id-audio-ownership-$attempt"\n'
            '        local ownership_url="$BASE_URL/live/',
            script,
        )

    def test_ownership_lane_has_an_explicit_ten_minute_xctest_allowance(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        branch = re.search(
            r'elif \[\[ "\$scenario" == "audio-session-ownership" \]\]; then\n'
            r"(?P<body>(?:(?!\n    (?:elif|else|fi)\b).)*)\n"
            r'    elif \[\[ "\$scenario" == "audio-media-services-reset" \]\]; then',
            script,
            re.DOTALL,
        )
        self.assertIsNotNone(branch)
        body = branch.group("body")
        self.assertIn("xcodebuild test-without-building", body)
        self.assertIn("-test-timeouts-enabled YES", body)
        self.assertIn("-default-test-execution-time-allowance 600", body)
        self.assertIn("-maximum-test-execution-time-allowance 600", body)

    def test_apple_audio_source_proof_is_host_retained_and_quiescent(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        support = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Support"
            / "ShowcaseIOSTestCase.swift"
        ).read_text()
        reset_test = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "MediaServicesResetDeviceUITests.swift"
        ).read_text()
        ownership_test = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "AudioSessionOwnershipDeviceUITests.swift"
        ).read_text()
        materializer = (ROOT / "qualification" / "materialize-evidence.py").read_text()
        policy_source = (ROOT / "qualification" / "qualification_policy.py").read_text()

        self.assertNotIn("adaptiveSourceRequestProof", support)
        self.assertNotIn('payload["sourceRequestProof"]', reset_test)
        self.assertNotIn('payload["sourceRequestProof"]', ownership_test)
        self.assertIn("capture_apple_audio_source_metrics()", script)
        self.assertGreaterEqual(
            script.count('curl -fsS "$BASE_URL/adaptive/$token/metrics"'),
            2,
        )
        self.assertIn('cmp -s "$first_snapshot" "$second_snapshot"', script)
        self.assertIn("snapshots across three seconds", script)
        self.assertIn("&& sleep 3", script)
        self.assertIn("apple-audio-source-metrics/$run_id-$scenario", script)
        self.assertIn(
            '--adaptive-source-metrics "$final_apple_audio_source_metrics"',
            script,
        )
        self.assertIn('"sourceRequestProof",', materializer)
        self.assertIn("bind_apple_audio_source_request_proof", materializer)
        self.assertIn(
            "sourceRequestProof", qualification_policy._ATTACHMENT_HOST_FIELDS
        )
        for scenario in (
            "audio-media-services-reset",
            "audio-session-ownership",
        ):
            self.assertEqual(
                qualification_policy._AUGMENTED_ATTACHMENT_PATHS[scenario],
                {"sourceRequestProof"},
            )
        self.assertIn(
            '{"sourceRequestProof": evidence.get("sourceRequestProof")}',
            policy_source,
        )

    def test_adaptive_ui_retains_sustained_visual_checkpoints(self):
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "AdaptiveHLSSoakDeviceUITests.swift"
        ).read_text()
        maximum = re.search(r"maximumVisualGapSeconds\s*=\s*(\d+)", source)
        period = re.search(r"visualCheckpointPeriodSeconds\s*=\s*(\d+)", source)
        self.assertIsNotNone(maximum)
        self.assertIsNotNone(period)
        self.assertGreater(int(maximum.group(1)), 0)
        self.assertLess(int(period.group(1)), int(maximum.group(1)))
        self.assertIn("observedElapsed >= nextVisualCheckpointElapsed", source)
        self.assertIn("deviceObservedDuration - maximumGapSeconds", source)
        self.assertIn("current.elapsedSeconds - previous.elapsedSeconds", source)
        self.assertIn("Set(observations.map(\\.mode))", source)

    def test_delayed_start_source_and_runner_share_one_exact_dual_output_contract(
        self,
    ):
        source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Tests"
            / "PiPDelayedStartFailureDeviceUITests.swift"
        ).read_text()
        emitted_scenarios = set(
            re.findall(
                r'attachQualificationEvidence\([\s\S]*?scenario:\s*"([a-z0-9-]+)"\s*\)',
                source,
            )
        )
        self.assertEqual(
            emitted_scenarios,
            {"failed-start", "accepted-start-delayed-failure"},
        )

        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {item["id"]: item for item in matrix["runnerContracts"]}
        self.assertNotIn("accepted-start-delayed-failure", contracts)
        contract = contracts["failed-start"]
        self.assertEqual(contract["attachmentEmission"], "allOutputs")
        expected_test = (
            "iOSUITests/PiPDelayedStartFailureDeviceUITests/"
            "test_acceptedStartRetainsAttributionThroughDelayedFailure"
        )
        self.assertEqual(
            {
                output["scenario"]: (
                    output["attachmentName"],
                    output["testIdentifiers"],
                )
                for output in contract["outputs"]
            },
            {
                scenario: (f"qualification-{scenario}.json", [expected_test])
                for scenario in emitted_scenarios
            },
        )
        self.assertEqual(
            qualification_policy.runner_attachment_expectations(
                contract, {"failed-start"}
            ),
            {
                f"qualification-{scenario}.json": [expected_test]
                for scenario in emitted_scenarios
            },
        )

        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertNotIn("accepted-start-delayed-failure)", runner)
        self.assertIn(
            'qualification_scenarios+=("accepted-start-delayed-failure")', runner
        )
        self.assertIn("if can_run_iphone_current_lanes; then", runner)

    def test_host_only_xctests_are_owned_by_analyzer_not_ui_suite(self):
        matrix = json.loads((ROOT / "qualification" / "matrix.json").read_text())
        contracts = {item["id"]: item for item in matrix["runnerContracts"]}
        expected = {
            "iOSUITests/DeferredPauseSettlementObservationTests/",
            "iOSUITests/HLSSeekLandingFrameGateTests/",
            "iOSUITests/NativeRendererRecoveryEvidenceTests/",
            "iOSUITests/NativeRendererRecoveryVisualEvidenceTests/",
            "iOSUITests/PiPMotionRegionAnalyzerTests/",
            "iOSUITests/VideoSurfaceMotionEvidenceTests/",
            "iOSUITests/VideoOracleAnalyzerTests/",
        }
        analyzer = contracts["analyzer"]["selection"]
        self.assertEqual(analyzer["kind"], "candidatePrefixes")
        self.assertEqual(set(analyzer["prefixes"]), expected)
        source_owned = set()
        tests_root = ROOT.parent / "Showcase" / "UITests" / "iOS" / "Tests"
        for source in tests_root.glob("*.swift"):
            for line in source.read_text().splitlines():
                stripped = line.strip()
                if stripped.startswith("final class ") and stripped.endswith(
                    ": XCTestCase {"
                ):
                    test_class = stripped.split()[2].removesuffix(":")
                    source_owned.add(f"iOSUITests/{test_class}/")
        self.assertEqual(source_owned, expected)
        ui_suite = contracts["ui-suite"]["selection"]
        self.assertTrue(expected <= set(ui_suite["prefixes"]))
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        for prefix in expected:
            self.assertIn(f'"{prefix.removesuffix("/")}"', script)
        visual_source = (
            ROOT.parent
            / "Showcase"
            / "UITests"
            / "iOS"
            / "Support"
            / "VideoSurfaceMotionEvidence.swift"
        ).read_text()
        for contract in (
            qualification_policy.VISUAL_OBSERVATION_METHOD,
            "static let width = 64",
            "static let height = 36",
            '"swiftvlc-rgb8-64x36-v1\\0"',
            "pixelDeltaThreshold = 12",
            "ratios.min()",
        ):
            self.assertIn(contract, visual_source)

    def test_require_stable_rejects_shortened_duration_before_device_discovery(self):
        script = ROOT / "qualification" / "run-device-tests.sh"
        environment = os.environ.copy()
        environment["SWIFTVLC_ADAPTIVE_SOAK_SECONDS"] = "60"
        completed = subprocess.run(
            ["bash", str(script), "--require-stable"],
            check=False,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("immutable minimum is 7200s", completed.stderr)

    def test_temporary_work_defaults_beside_the_repository(self):
        script = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        self.assertIn(
            'WORK_ROOT="${SWIFTVLC_DEVICE_WORK_ROOT:-$ROOT_DIR/.qualification-work}"',
            script,
        )
        self.assertIn(
            'WORK_DIR=$(mktemp -d "$WORK_ROOT/swiftvlc-device-tests.XXXXXX")',
            script,
        )
        self.assertNotIn("${TMPDIR:-/tmp}/swiftvlc-device-tests", script)
        self.assertIn('export TMPDIR="$WORK_DIR"', script)


class XCTestrunTests(unittest.TestCase):
    @staticmethod
    def ui_test_plan():
        return {
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

    def test_destination_artifact_transform_removes_local_paths(self):
        original = self.ui_test_plan()
        transformed = prepare_xctestrun.transform(original, {"ATTACH": "YES"})
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        for key in prepare_xctestrun.REMOVED_PATH_KEYS:
            self.assertNotIn(key, target)
        self.assertTrue(target["UseDestinationArtifacts"])
        self.assertEqual(target["TestingEnvironmentVariables"]["ATTACH"], "YES")

    def test_build_product_transform_preserves_paths_and_injects_environment(self):
        original = self.ui_test_plan()
        transformed = prepare_xctestrun.transform(
            original,
            {"FIXTURE": "http://127.0.0.1/media.mp4"},
            use_destination_artifacts=False,
        )
        target = transformed["TestConfigurations"][0]["TestTargets"][0]
        self.assertEqual(target["TestBundlePath"], "/tmp/test.xctest")
        self.assertEqual(target["TestHostPath"], "/tmp/Runner.app")
        self.assertNotIn("UseDestinationArtifacts", target)
        self.assertEqual(
            target["TestingEnvironmentVariables"]["FIXTURE"],
            "http://127.0.0.1/media.mp4",
        )


class CandidateMetadataTests(unittest.TestCase):
    def test_source_digest_is_scoped_to_the_selected_clean_checkout(self):
        source_root = Path("/tmp/SwiftVLC qualification snapshot")
        calls = []
        original = candidate_metadata.command_output

        def command_output(arguments):
            calls.append(arguments)
            if "status" in arguments:
                return ""
            if "rev-parse" in arguments:
                return "b" * 40
            return "c" * 64

        candidate_metadata.command_output = command_output
        try:
            identity = candidate_metadata.source_identity(source_root, "1.1.0")
        finally:
            candidate_metadata.command_output = original

        self.assertEqual(identity["sourceCommit"], "b" * 40)
        self.assertEqual(identity["releaseSourceDigest"], "c" * 64)
        self.assertEqual(
            calls[-1],
            [
                "python3",
                str(source_root / "scripts" / "release-source-digest.py"),
                "1.1.0",
                "--root",
                str(source_root),
            ],
        )

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
            "artifactDigestAlgorithm": "swiftvlc-tree-v1",
            "artifactDigest": "d" * 64,
        }
        self.assertEqual(
            candidate_metadata.validate(metadata, "1.1.0", app_digest, "d" * 64),
            metadata,
        )
        with self.assertRaises(candidate_metadata.CandidateMetadataError):
            candidate_metadata.validate(metadata, "1.1.0", "e" * 64, "d" * 64)

    def test_format_two_metadata_accepts_the_complete_runner_binding(self):
        catalog = ["iOSUITests/AnalyzerTests/test_pixels"]
        metadata = {
            "formatVersion": 2,
            "version": "1.1.0",
            "sourceCommit": "b" * 40,
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": "c" * 64,
            "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
            "candidateAppDigest": "a" * 64,
            "artifactDigestAlgorithm": "swiftvlc-tree-v1",
            "artifactDigest": "d" * 64,
            "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
            "testRunnerDigest": "e" * 64,
            "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
            "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
            "testBundleDigest": "f" * 64,
            "baseXCTestRunDigestAlgorithm": "sha256",
            "baseXCTestRunDigest": "1" * 64,
            "baseXCTestRunName": "iOS_iphoneos.xctestrun",
            "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
            "testCatalogDigest": qualification_policy.catalog_digest(catalog),
            "testCatalogCount": 1,
            "testCatalog": catalog,
            "qualificationMatrixChecksum": "2" * 64,
            "featureManifestChecksum": "3" * 64,
            "qualificationProfilesChecksum": "4" * 64,
            "fixtureManifestChecksum": "5" * 64,
            "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
            "qualificationPolicyDigest": qualification_policy.policy_digest(),
        }
        self.assertEqual(
            candidate_metadata.validate(
                metadata,
                "1.1.0",
                metadata["candidateAppDigest"],
                metadata["artifactDigest"],
            ),
            metadata,
        )

    def test_metadata_reads_source_identity_from_the_signed_app_payload(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "iOS.app"
            app.mkdir()
            xcframework = root / "libvlc.xcframework"
            xcframework.mkdir()
            with (app / "Info.plist").open("wb") as output:
                plistlib.dump(
                    {
                        "SwiftVLCSourceCommit": "b" * 40,
                        "SwiftVLCReleaseSourceDigest": "c" * 64,
                        "SwiftVLCArtifactDigest": "a" * 64,
                    },
                    output,
                )
            digest_script = root / "digest.py"
            digest_script.write_text(f'print("{"a" * 64}")\n')

            metadata = candidate_metadata.create(
                app, xcframework, "1.1.0", digest_script
            )
            self.assertEqual(metadata["sourceCommit"], "b" * 40)
            self.assertEqual(metadata["releaseSourceDigest"], "c" * 64)
            self.assertEqual(metadata["candidateAppDigest"], "a" * 64)
            self.assertEqual(metadata["artifactDigest"], "a" * 64)

            forged = dict(metadata, sourceCommit="d" * 40)
            with self.assertRaises(candidate_metadata.CandidateMetadataError):
                candidate_metadata.verify(
                    forged, app, xcframework, "1.1.0", digest_script
                )


class FixtureManifestTests(unittest.TestCase):
    def test_local_playback_fixture_contract_is_shared_and_decode_verified(self):
        contract = qualification_policy.LOCAL_PLAYBACK_FIXTURE_CONTRACT
        self.assertEqual(
            verify_fixtures.EXPECTED_RELEASE_FIXTURE_METADATA["localPlayback"],
            contract,
        )
        self.assertEqual(len(contract["video"]), 5)
        self.assertEqual(len(contract["audio"]), 6)
        self.assertEqual(
            {row["container"] for row in contract["video"]},
            {"mp4", "matroska", "webm", "mpegts"},
        )
        self.assertEqual(
            {row["audioCodec"] for row in contract["audio"]},
            {"aac", "alac", "mp3", "flac", "opus", "pcm_s16le"},
        )
        generator = (ROOT / "qualification" / "generate-fixtures.sh").read_text()
        verifier = (ROOT / "qualification" / "verify-fixtures.py").read_text()
        swift_contract = (
            ROOT.parent
            / "Showcase"
            / "Shared"
            / "LocalPlaybackQualificationContract.swift"
        ).read_text()
        for kind in ("video", "audio"):
            for fixture in contract[kind]:
                with self.subTest(fixture=fixture["id"]):
                    self.assertIn(fixture["id"], generator)
                    self.assertIn(fixture["path"], generator)
                    self.assertIn(fixture["id"], swift_contract)
                    self.assertIn(fixture["path"], swift_contract)
        self.assertIn("+frag_keyframe+empty_moov+default_base_moof", generator)
        self.assertIn("_validate_local_video_motion(path)", verifier)
        self.assertIn("_validate_local_audio_signal(path)", verifier)
        self.assertIn('b"moof" not in payload', verifier)

    def test_progressive_range_fixture_is_large_content_coded_and_decode_verified(self):
        generator = (ROOT / "qualification" / "generate-fixtures.sh").read_text()
        verifier = (ROOT / "qualification" / "verify-fixtures.py").read_text()
        self.assertIn('"$fixture_tmp/oracles/progressive-range.mp4"', generator)
        self.assertIn("-b:v 4000k -minrate 4000k -maxrate 4000k", generator)
        self.assertIn("nal-hrd=cbr:filler=1", generator)
        self.assertIn("-g 300 -keyint_min 300 -sc_threshold 0", generator)
        self.assertIn("[0:v]split=2[first][second]", generator)
        self.assertIn("drawbox=x=480:y=300:w=120:h=40:color=white:t=fill", generator)
        self.assertIn("-frames:v 3600", generator)
        self.assertIn('"minimumBytes": 50000000', generator)
        self.assertIn("progressive_path.stat().st_size", verifier)
        self.assertIn("for seconds in (43.5, 103.5)", verifier)
        self.assertIn("cycle != expected_cycle", verifier)
        self.assertEqual(
            verify_fixtures.EXPECTED_RELEASE_ORACLES["progressiveHTTPRange"][
                "timelineCycleIndicator"
            ]["secondHalfStartSeconds"],
            60,
        )
        self.assertEqual(
            verify_fixtures.EXPECTED_RELEASE_ORACLES["progressiveHTTPRange"][
                "minimumBytes"
            ],
            50_000_000,
        )

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

    def test_release_oracle_contract_cannot_be_self_signed_away(self):
        manifest = {
            "formatVersion": 1,
            "oracles": verify_fixtures.EXPECTED_RELEASE_ORACLES,
            "files": {
                oracle["path"]: {"bytes": 1, "sha256": "0" * 64}
                for oracle in verify_fixtures.EXPECTED_RELEASE_ORACLES.values()
            },
        }
        verify_fixtures.verify_release_oracles(manifest)

        weakened = json.loads(json.dumps(manifest))
        weakened["oracles"]["frameAllIntra"]["allIntra"] = False
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(weakened)

        weakened_progressive = json.loads(json.dumps(manifest))
        weakened_progressive["oracles"]["progressiveHTTPRange"]["minimumBytes"] = 1
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(weakened_progressive)

        missing = json.loads(json.dumps(manifest))
        missing["files"].pop("oracles/seek-sparse-gop.mp4")
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(missing)

        missing_progressive = json.loads(json.dumps(manifest))
        missing_progressive["files"].pop("oracles/progressive-range.mp4")
        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures.verify_release_oracles(missing_progressive)

    def test_release_seek_oracle_rejects_a_declared_band_without_a_marker(self):
        solid_band = bytes((0xC0, 0x20, 0x20)) * (640 * 360)

        with self.assertRaises(verify_fixtures.FixtureVerificationError):
            verify_fixtures._seek_pixel_observation(solid_band)

    def test_progressive_cycle_indicator_distinguishes_the_second_minute(self):
        frame = bytearray(bytes((0xA0, 0x20, 0xA0)) * (640 * 360))
        self.assertEqual(verify_fixtures._progressive_cycle_index(frame), 0)
        for y in range(300, 340):
            for x in range(480, 600):
                offset = (y * 640 + x) * 3
                frame[offset : offset + 3] = b"\xff\xff\xff"
        self.assertEqual(verify_fixtures._progressive_cycle_index(frame), 1)

    def test_release_seek_oracle_decodes_the_encoded_marker_contract(self):
        frame = bytearray(bytes((0x20, 0x40, 0xC0)) * (640 * 360))
        marker_x = 40 + 3 * 56
        for y in range(80, 280):
            for x in range(marker_x, marker_x + 24):
                offset = (y * 640 + x) * 3
                frame[offset : offset + 3] = b"\xff\xff\xff"

        band, observed_x, color_distance, marker_contrast = (
            verify_fixtures._seek_pixel_observation(bytes(frame))
        )

        self.assertEqual(band, 2)
        self.assertEqual(observed_x, marker_x)
        self.assertEqual(color_distance, 0)
        self.assertGreater(marker_contrast, 100)

    def test_release_all_intra_oracle_decodes_a_frame_code(self):
        color = tuple(int(component) for component in verify_fixtures._frame_color(73))
        frame = bytes(color) * (640 * 360)

        index, distance, margin = verify_fixtures._all_intra_pixel_observation(frame)

        self.assertEqual(index, 73)
        self.assertEqual(distance, 0)
        self.assertGreaterEqual(margin, 8)


class QualificationEvidenceTests(unittest.TestCase):
    @staticmethod
    def artifact_producer(runner: str, attempt: int = 1) -> dict:
        return {
            "runnerScenario": runner,
            "sourceAttempt": attempt,
            "sourceXcresultDigest": "9" * 64,
        }

    @staticmethod
    def xctrace_summary(
        trace: Path,
        toc: Path,
        *,
        scenario_id: str,
        role: str,
        template: str,
        target_device_identifier: str,
        producer_fields: dict,
    ) -> dict:
        full_duration = qualification_policy.STABLE_MINIMUM_DURATION_SECONDS[
            scenario_id
        ]
        minimum_duration = qualification_policy.trace_minimum_capture_duration(
            scenario_id, role, full_duration
        )
        metric, unit = qualification_policy.TRACE_MEASUREMENT_SPECS[role]
        return {
            "formatVersion": 1,
            "status": "captured",
            "source": "xctrace-export-v1",
            "runNumber": 1,
            "scenario": scenario_id,
            "artifactRole": role,
            "template": template,
            "targetProcess": "iOS",
            "targetDeviceIdentifier": target_device_identifier,
            "captureDurationSeconds": minimum_duration,
            "tables": [
                {
                    "schema": f"{role}-samples",
                    "rowCount": 10,
                    "targetProcessRowCount": 10,
                }
            ],
            "totalRowCount": 10,
            "measurement": {
                "metric": metric,
                "unit": unit,
                "sampleCount": 10,
                "targetProcessRowCount": 10,
                "minimumValue": 1.0,
                "averageValue": 1.0,
                "maximumValue": 1.0,
                "timelineStartSeconds": 0.0,
                "timelineEndSeconds": minimum_duration,
                "maximumSampleGapSeconds": 1.0,
                "sourceFields": [f"{role}-fixture-value"],
            },
            "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
            "traceTreeDigest": qualification_policy.tree_digest(trace),
            "tableOfContentsDigestAlgorithm": "sha256",
            "tableOfContentsDigest": qualification_policy.sha256_file(toc),
            **producer_fields,
        }

    def make_export(
        self,
        root: Path,
        payload: dict,
        attachment_count: int = 1,
        attachment_name: str = "qualification-native-hls-seek-continuity.json",
        test_identifier: str = "iOSUITests/PiPOverlayDeviceUITests/test_nativePiPHLSSeeksRemainActive",
    ):
        exported = root / "attachment.json"
        exported.write_text(json.dumps(payload))
        attachment = {
            "exportedFileName": exported.name,
            "suggestedHumanReadableName": attachment_name,
        }
        canonical_identifier = (
            test_identifier
            if test_identifier.startswith("iOSUITests/")
            else f"iOSUITests/{test_identifier}"
        )
        short_identifier = "/".join(canonical_identifier.split("/")[-2:]) + "()"
        manifest = [
            {
                "testIdentifier": short_identifier,
                "testIdentifierURL": (
                    "test://com.apple.xcode/SwiftVLCShowcase/" f"{canonical_identifier}"
                ),
                "attachments": [attachment] * attachment_count,
            }
        ]
        (root / "manifest.json").write_text(json.dumps(manifest))

    def make_delayed_start_export(self, root: Path) -> None:
        owner = (
            "iOSUITests/PiPDelayedStartFailureDeviceUITests/"
            "test_acceptedStartRetainsAttributionThroughDelayedFailure"
        )
        payloads = {
            "qualification-failed-start.json": {
                "formatVersion": 1,
                "scenario": "failed-start",
                "events": {
                    "failedToStartCount": 1,
                    "didStartCount": 0,
                    "order": "pass",
                },
                "failureSurfaced": True,
                "orderedEvents": ["willStart", "failedToStart"],
                "failureDomain": "SwiftVLC.Qualification.DelayedPiPStartFailure",
                "failureCode": 1,
            },
            "qualification-accepted-start-delayed-failure.json": {
                "formatVersion": 1,
                "scenario": "accepted-start-delayed-failure",
                "startResult": "accepted",
                "orderedEvents": ["willStart", "failedToStart"],
                "controllerGeneration": 3,
                "mediaGeneration": 7,
                "expectedControllerGeneration": 3,
                "expectedMediaGeneration": 7,
                "orderedAttribution": True,
                "quiescenceMilliseconds": 3000,
                "controllerActiveAfterCleanup": False,
                "failureDomain": "SwiftVLC.Qualification.DelayedPiPStartFailure",
                "failureCode": 1,
            },
        }
        attachments = []
        for index, (name, payload) in enumerate(payloads.items()):
            exported = root / f"delayed-start-{index}.json"
            exported.write_text(json.dumps(payload))
            attachments.append(
                {
                    "exportedFileName": exported.name,
                    "suggestedHumanReadableName": name,
                }
            )
        (root / "manifest.json").write_text(
            json.dumps(
                [
                    {
                        "testIdentifier": (
                            "PiPDelayedStartFailureDeviceUITests/"
                            "test_acceptedStartRetainsAttributionThroughDelayedFailure()"
                        ),
                        "testIdentifierURL": (
                            "test://com.apple.xcode/SwiftVLCShowcase/" + owner
                        ),
                        "attachments": attachments,
                    }
                ]
            )
        )

    def test_materializes_test_payload_with_host_owned_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "native-hls-seek-continuity",
                    "seekResults": {"forward": "pass"},
                    "commandEvidence": {
                        "forward": {
                            "command": "forward",
                            "outcome": "pass",
                            "accepted": True,
                            "durationMilliseconds": 60_000,
                            "baselineNativeTimeMilliseconds": 2_000,
                            "expectedTimeMilliseconds": 12_000,
                            "landingToleranceMilliseconds": 3_000,
                            "landingNativeTimeMilliseconds": 12_100,
                            "postCommandDisplayedPictures": 12,
                            "displayedPicturesAtLanding": 13,
                            "finalDisplayedPictures": 14,
                            "commandToRecoveryMilliseconds": 400,
                        }
                    },
                },
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-native-hls-seek-continuity.json",
                "native-hls-seek-continuity",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["artifactDigest"], "a" * 64)
            self.assertEqual(evidence["releaseSourceDigest"], "b" * 64)
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["seekResults"]["forward"], "pass")
            command = evidence["commandEvidence"]["forward"]
            self.assertEqual(command["command"], "forward")
            self.assertGreater(
                command["finalDisplayedPictures"],
                command["displayedPicturesAtLanding"],
            )

    def test_materializes_xcode_decorated_attachment_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "vod-controls",
                    "controls": "pass",
                },
                attachment_name=(
                    "qualification-vod-controls_0_"
                    "363D852A-C7EB-4013-A3F0-3C775E761E8D.json"
                ),
                test_identifier=(
                    "PiPVODControlsDeviceUITests/"
                    "test_vodControlsAcrossNativeAndDirectBackends"
                ),
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-vod-controls.json",
                "vod-controls",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["controls"], "pass")

    def test_rejects_names_that_only_resemble_xcode_decoration(self):
        uuid = "363D852A-C7EB-4013-A3F0-3C775E761E8D"
        invalid_names = [
            f"qualification-vod-controls-extra_0_{uuid}.json",
            f"qualification-vod-controls_00_{uuid}.json",
            "qualification-vod-controls_0_not-a-uuid.json",
            f"qualification-vod-controls_0_{uuid}.json.bak",
            f"qualification-vod-controls_0_{uuid}.JSON",
        ]
        for invalid_name in invalid_names:
            with self.subTest(invalid_name=invalid_name):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    self.make_export(
                        root,
                        {"scenario": "vod-controls"},
                        attachment_name=invalid_name,
                    )
                    with self.assertRaisesRegex(
                        materialize_evidence.EvidenceError,
                        "unauthorized qualification attachment",
                    ):
                        materialize_evidence.materialize(
                            root,
                            "qualification-vod-controls.json",
                            "vod-controls",
                            "iphone-current",
                            "a" * 64,
                            "b" * 64,
                        )

    def test_rejects_exact_and_decorated_logical_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {"scenario": "vod-controls"},
                attachment_name="qualification-vod-controls.json",
                test_identifier=(
                    "PiPVODControlsDeviceUITests/"
                    "test_vodControlsAcrossNativeAndDirectBackends"
                ),
            )
            manifest = json.loads((root / "manifest.json").read_text())
            manifest[0]["attachments"].append(
                {
                    "exportedFileName": "attachment.json",
                    "suggestedHumanReadableName": (
                        "qualification-vod-controls_1_"
                        "363D852A-C7EB-4013-A3F0-3C775E761E8D.json"
                    ),
                }
            )
            (root / "manifest.json").write_text(json.dumps(manifest))
            with self.assertRaisesRegex(
                materialize_evidence.EvidenceError,
                "attachment counts mismatch",
            ):
                materialize_evidence.materialize(
                    root,
                    "qualification-vod-controls.json",
                    "vod-controls",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

    def test_materializes_combined_live_media_backend_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "live-media",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "playbackRange": "unbounded",
                    "linearPlayback": True,
                    "backendResults": {"native": "pass", "direct": "pass"},
                },
                attachment_name="qualification-live-media.json",
                test_identifier="PiPLiveDeviceUITests/test_liveMediaQualificationAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-live-media.json",
                "live-media",
                "ipad-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["scenario"], "live-media")
            self.assertEqual(evidence["hardware"], "ipad-current")
            self.assertEqual(
                evidence["backendResults"], {"native": "pass", "direct": "pass"}
            )

    def test_materializes_background_audio_counter_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "background-audio",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "audioContinuity": "pass",
                    "backgroundApplicationState": True,
                    "measurementMethod": "libvlc-played-audio-buffers",
                    "measurements": {
                        "playedAudioBuffersBeforeBackground": 100,
                        "playedAudioBuffersAfterBackground": 180,
                    },
                },
                attachment_name="qualification-background-audio.json",
                test_identifier="PiPLiveDeviceUITests/test_backgroundAudioQualificationWhileAppIsBackgrounded",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-background-audio.json",
                "background-audio",
                "iphone-minimum",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["scenario"], "background-audio")
            self.assertEqual(evidence["hardware"], "iphone-minimum")
            self.assertTrue(evidence["backgroundApplicationState"])
            self.assertEqual(
                evidence["measurementMethod"], "libvlc-played-audio-buffers"
            )
            self.assertGreater(
                evidence["measurements"]["playedAudioBuffersAfterBackground"],
                evidence["measurements"]["playedAudioBuffersBeforeBackground"],
            )

    def test_materializes_replacement_continuity_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "replacement-continuity",
                    "combinations": {
                        "vodToLive": "pass",
                        "liveToVOD": "pass",
                    },
                    "snapshotCoherence": "pass",
                    "measurements": {
                        "audioGapMilliseconds": 325,
                        "videoGapMilliseconds": 210,
                    },
                    "audioContinuityWithinBudget": True,
                    "videoContinuityWithinBudget": True,
                    "controls": "pass",
                    "recoveryOutcome": "preserved",
                    "staleSuccessorMutations": 0,
                },
                attachment_name="qualification-replacement-continuity.json",
                test_identifier="PiPContinuityDeviceUITests/test_nativePiPReplacementContinuityAcrossVODAndLive",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-replacement-continuity.json",
                "replacement-continuity",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["combinations"]["vodToLive"], "pass")
            self.assertEqual(evidence["combinations"]["liveToVOD"], "pass")
            self.assertEqual(evidence["staleSuccessorMutations"], 0)
            self.assertGreater(evidence["measurements"]["audioGapMilliseconds"], 0)
            self.assertTrue(evidence["audioContinuityWithinBudget"])
            self.assertTrue(evidence["videoContinuityWithinBudget"])

    def test_materializes_capability_convergence_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "capability-convergence",
                    "backendResults": {"native": "pass", "direct": "pass"},
                    "transitions": "pass",
                    "skipControls": "pass",
                    "faultInjection": {
                        "rawEventsSuppressed": True,
                        "nativePlayerObserverExercised": True,
                        "nativeControllerObserverExercised": True,
                        "directPlayerObserverExercised": True,
                        "directControllerObserverExercised": True,
                        "nativePlayerLengthEvents": 2,
                        "nativePlayerSeekableEvents": 1,
                        "nativeControllerLengthEvents": 2,
                        "nativeControllerSeekableEvents": 1,
                        "directPlayerLengthEvents": 2,
                        "directPlayerSeekableEvents": 1,
                        "directControllerLengthEvents": 2,
                        "directControllerSeekableEvents": 1,
                    },
                },
                attachment_name="qualification-capability-convergence.json",
                test_identifier="PiPCapabilityDeviceUITests/test_capabilityConvergenceAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-capability-convergence.json",
                "capability-convergence",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(
                evidence["backendResults"], {"native": "pass", "direct": "pass"}
            )
            self.assertEqual(evidence["transitions"], "pass")
            self.assertEqual(evidence["skipControls"], "pass")
            self.assertTrue(evidence["faultInjection"]["rawEventsSuppressed"])
            for field in (
                "nativePlayerLengthEvents",
                "nativePlayerSeekableEvents",
                "nativeControllerLengthEvents",
                "nativeControllerSeekableEvents",
                "directPlayerLengthEvents",
                "directPlayerSeekableEvents",
                "directControllerLengthEvents",
                "directControllerSeekableEvents",
            ):
                self.assertGreater(evidence["faultInjection"][field], 0)

    def test_materializes_deferred_pause_rejection_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "deferred-pause-rejection",
                    "permanentCase": {
                        "outcome": "rejected",
                        "forcedRejectionCount": 40,
                        "nativePauseCommandCount": 0,
                        "taskStayedSettled": True,
                        "truthfulControls": True,
                    },
                    "transientCase": {
                        "outcome": "issued",
                        "forcedRejectionCount": 3,
                        "nativePauseCommandCount": 1,
                        "taskStayedSettled": True,
                        "truthfulControls": True,
                    },
                    "cancellationCases": "pass",
                    "cancellationResults": {
                        "newerCommand": "cancelled",
                        "replacement": "cancelled",
                        "stop": "cancelled",
                    },
                    "endlessTaskCount": 0,
                    "duplicatePauseCount": 0,
                    "truthfulControls": True,
                },
                attachment_name="qualification-deferred-pause-rejection.json",
                test_identifier="PiPDeferredPauseDeviceUITests/test_deferredPauseRejectionAndCancellationStayTruthful",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-deferred-pause-rejection.json",
                "deferred-pause-rejection",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["permanentCase"]["outcome"], "rejected")
            self.assertEqual(evidence["transientCase"]["outcome"], "issued")
            self.assertEqual(evidence["cancellationCases"], "pass")
            self.assertEqual(evidence["endlessTaskCount"], 0)
            self.assertEqual(evidence["duplicatePauseCount"], 0)
            self.assertTrue(evidence["truthfulControls"])

    def test_materializes_vod_controls_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "vod-controls",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "controls": {
                        "play": "pass",
                        "pause": "pass",
                        "scrub": "pass",
                        "skipForward": "pass",
                        "skipBackward": "pass",
                    },
                    "backendResults": {"native": {}, "direct": {}},
                    "systemPiPMotion": {"native": "pass", "direct": "pass"},
                },
                attachment_name="qualification-vod-controls.json",
                test_identifier="PiPVODControlsDeviceUITests/test_vodControlsAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-vod-controls.json",
                "vod-controls",
                "ipad-minimum",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "ipad-minimum")
            self.assertEqual(evidence["events"]["unexpectedStopCount"], 0)
            self.assertEqual(evidence["controls"]["scrub"], "pass")
            self.assertEqual(evidence["systemPiPMotion"]["native"], "pass")

    def test_materializes_long_stall_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "long-stall",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "recoveryOutcome": "recovered",
                    "boundedMemory": True,
                    "backendResults": {
                        "native": {"memory": {"growthBytes": 1024}},
                        "direct": {"memory": {"growthBytes": 2048}},
                    },
                    "systemPiPMotionAfterRecovery": {
                        "native": "pass",
                        "direct": "pass",
                    },
                },
                attachment_name="qualification-long-stall.json",
                test_identifier="PiPLongStallDeviceUITests/test_longStallRecoversAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-long-stall.json",
                "long-stall",
                "iphone-minimum",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-minimum")
            self.assertEqual(evidence["recoveryOutcome"], "recovered")
            self.assertTrue(evidence["boundedMemory"])
            self.assertEqual(
                evidence["backendResults"]["direct"]["memory"]["growthBytes"], 2048
            )

    def test_materializes_restore_and_close_evidence(self):
        for scenario, restore_count, reason in (
            ("restore", 1, "restoreRequested"),
            ("close", 0, "userClosed"),
        ):
            with self.subTest(
                scenario=scenario
            ), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                self.make_export(
                    root,
                    {
                        "formatVersion": 1,
                        "scenario": scenario,
                        "events": {
                            "didStartCount": 1,
                            "willStopReason": reason,
                            "didStopReason": reason,
                            "order": "pass",
                        },
                        "backends": {
                            "native": {
                                "reason": reason,
                                "restoreCallbackCount": restore_count,
                                "systemPiPMotion": "pass",
                            },
                            "direct": {
                                "reason": reason,
                                "restoreCallbackCount": restore_count,
                                "systemPiPMotion": "pass",
                            },
                        },
                        **(
                            {"restoreResult": "pass", "completionCount": 1}
                            if scenario == "restore"
                            else {"stopReason": "userClosed"}
                        ),
                        "aggregationBasis": "per-backend invariant",
                        "systemAffordance": "pass",
                    },
                    attachment_name=f"qualification-{scenario}.json",
                    test_identifier="PiPDismissalDeviceUITests/test_systemRestoreAndCloseAcrossNativeAndDirectBackends",
                )
                evidence = materialize_evidence.materialize(
                    root,
                    f"qualification-{scenario}.json",
                    scenario,
                    "ipad-current",
                    "a" * 64,
                    "b" * 64,
                )
                self.assertEqual(evidence["hardware"], "ipad-current")
                self.assertEqual(evidence["events"]["didStartCount"], 1)
                self.assertEqual(evidence["events"]["willStopReason"], reason)
                self.assertEqual(evidence["events"]["didStopReason"], reason)
                self.assertEqual(evidence["backends"]["native"]["reason"], reason)
                self.assertEqual(evidence["systemAffordance"], "pass")
                if scenario == "restore":
                    self.assertEqual(evidence["restoreResult"], "pass")
                    self.assertEqual(evidence["completionCount"], 1)
                else:
                    self.assertEqual(evidence["stopReason"], "userClosed")

    def test_materializes_interruption_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "interruptions",
                    "events": {
                        "started": True,
                        "unexpectedStopCount": 0,
                        "order": "pass",
                    },
                    "interruptionRecovery": "pass",
                    "routeChangeRecovery": "pass",
                    "interruptionSource": "exclusive-XCTest-runner-audio-session",
                    "routeLossSource": "deterministic-oldDeviceUnavailable-notification",
                    "backends": {
                        "native": {
                            "interruptionBeganCount": 1,
                            "routeLossCount": 1,
                            "audioRecovered": True,
                        },
                        "direct": {
                            "interruptionBeganCount": 1,
                            "routeLossCount": 1,
                            "audioRecovered": True,
                        },
                    },
                    "recoveryOutcome": "preserved",
                    "systemPiPMotionAfterRecovery": "pass",
                },
                attachment_name="qualification-interruptions.json",
                test_identifier="PiPInterruptionDeviceUITests/test_audioInterruptionAndRouteLossAcrossNativeAndDirectBackends",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-interruptions.json",
                "interruptions",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["events"]["unexpectedStopCount"], 0)
            self.assertEqual(evidence["interruptionRecovery"], "pass")
            self.assertEqual(evidence["routeChangeRecovery"], "pass")
            self.assertEqual(evidence["backends"]["direct"]["routeLossCount"], 1)
            self.assertTrue(evidence["backends"]["native"]["audioRecovered"])
            self.assertEqual(evidence["recoveryOutcome"], "preserved")

    def test_materializes_native_lifecycle_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = {
                "restore": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:restoreRequested",
                        "didStop:restoreRequested",
                    ],
                    "restoreCallbackCount": 1,
                },
                "close": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:userClosed",
                        "didStop:userClosed",
                    ],
                    "restoreCallbackCount": 0,
                },
                "failed-start": {"orderedEvents": ["willStart", "failedToStart"]},
                "programmatic": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:programmatic",
                        "didStop:programmatic",
                    ]
                },
                "media-end": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:mediaEnded",
                        "didStop:mediaEnded",
                    ]
                },
                "failure": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:failure",
                        "didStop:failure",
                    ]
                },
                "recast": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:controllerReplaced",
                        "didStop:controllerReplaced",
                    ]
                },
                "replacement": {
                    "orderedEvents": [
                        "willStart",
                        "didStart",
                        "willStop:controllerReplaced",
                        "didStop:controllerReplaced",
                    ]
                },
            }
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "native-lifecycle",
                    "bridgeProbe": True,
                    "cases": cases,
                    "orderedEvents": {
                        name: value["orderedEvents"] for name, value in cases.items()
                    },
                    "authoritativeStopReasons": True,
                    "restoreExactlyOnce": True,
                    "unsupportedBridgeVisible": True,
                    "unsupportedBridgeVisibility": "typed-probe-required",
                    "unsupportedRevisionExercised": False,
                    "processIsolation": "one-launch-per-transition",
                },
                attachment_name="qualification-native-lifecycle.json",
                test_identifier="PiPNativeLifecycleDeviceUITests/test_nativeLifecyclePublishesAuthoritativeOrderedEvents",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-native-lifecycle.json",
                "native-lifecycle",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertTrue(evidence["bridgeProbe"])
            self.assertEqual(len(evidence["cases"]), 8)
            self.assertEqual(evidence["cases"]["restore"]["restoreCallbackCount"], 1)
            self.assertEqual(
                evidence["orderedEvents"]["failed-start"],
                ["willStart", "failedToStart"],
            )
            self.assertTrue(evidence["authoritativeStopReasons"])
            self.assertTrue(evidence["restoreExactlyOnce"])
            self.assertTrue(evidence["unsupportedBridgeVisible"])
            self.assertFalse(evidence["unsupportedRevisionExercised"])

    def test_materializes_terminal_outcome_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            failure_classifications = {
                "source": "source",
                "demux": "demux",
                "decoder": "decoder",
                "renderer": "renderer",
                "output": "output",
            }
            cases = {
                "clean-eof": {"cause": "naturalEnd"},
                "explicit-stop": {"cause": "requestedStop"},
                "replacement": {"cause": "replacement"},
                "server-close": {"cause": "failure:source"},
                "malformed": {"cause": "failure:demux"},
                "decode-failure": {"cause": "failure:decoder"},
                "renderer-failure": {"cause": "failure:renderer"},
                "output-failure": {"cause": "failure:output"},
                "network-loss": {"cause": "failure:source"},
            }
            final_timelines = {
                name: {
                    "timeMilliseconds": index * 100,
                    "durationMilliseconds": 60000,
                    "position": index / 10,
                    "bufferFill": 1,
                    "activeVideoOutputs": 1,
                }
                for index, name in enumerate(cases)
            }
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "terminal-outcomes",
                    "cases": cases,
                    "finalTimelines": final_timelines,
                    "generationIsolation": True,
                    "failureClassifications": failure_classifications,
                    "maximumTerminalOutcomesPerGeneration": 1,
                    "unattributedStopNaturalEndCount": 0,
                    "subscriberPayloadsIdentical": True,
                    "expectedFailureLogsPreserved": True,
                    "processIsolation": "one-launch-per-transition",
                },
                attachment_name="qualification-terminal-outcomes.json",
                test_identifier="TerminalOutcomesDeviceUITests/test_terminalOutcomeMatrixIsGenerationScopedAndPreReset",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-terminal-outcomes.json",
                "terminal-outcomes",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(len(evidence["cases"]), 9)
            self.assertEqual(len(evidence["finalTimelines"]), 9)
            self.assertTrue(evidence["generationIsolation"])
            self.assertEqual(
                evidence["failureClassifications"], failure_classifications
            )
            self.assertEqual(evidence["maximumTerminalOutcomesPerGeneration"], 1)
            self.assertEqual(evidence["unattributedStopNaturalEndCount"], 0)
            self.assertTrue(evidence["subscriberPayloadsIdentical"])

    def test_materializes_adaptive_hls_soak_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            payload = {
                "formatVersion": 1,
                "scenario": "adaptive-hls-soak",
                "durationSeconds": 7200,
                "playlistCoverage": {
                    "playlistTypes": ["event", "live", "vod"],
                    "containers": ["fmp4", "ts"],
                    "variants": ["high", "low"],
                    "variantTransitions": 4,
                    "discontinuityManifests": 3,
                    "expiredWindows": 2,
                    "retryFailures": 1,
                    "retryRecoveries": 1,
                    "cancellations": 7,
                },
                "allocationProvenance": {
                    "allocator": "Darwin default malloc zone",
                    "sourceOwnershipRegression": "SegmentChunkOwnership_test",
                    "expectedSourceReleaseCount": 1,
                },
                "memorySeries": [
                    {"elapsedSeconds": 0, "residentBytes": 100},
                    {"elapsedSeconds": 7200, "residentBytes": 101},
                ],
                "sanitizerFindings": 0,
                "crashes": 0,
                "unboundedRecoveries": 0,
                "monotonicGrowth": False,
                "upstreamCrossLink": "https://code.videolan.org/videolan/vlc/-/work_items/29845",
            }
            self.make_export(
                root,
                payload,
                attachment_name="qualification-adaptive-hls-soak.json",
                test_identifier="AdaptiveHLSSoakDeviceUITests/test_adaptiveHLSMatrixSoakRemainsBounded",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-adaptive-hls-soak.json",
                "adaptive-hls-soak",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                duration_seconds=7200,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["sanitizerFindings"], 0)
            self.assertFalse(evidence["monotonicGrowth"])
            self.assertEqual(
                evidence["allocationProvenance"]["expectedSourceReleaseCount"], 1
            )

    def test_host_binds_allocation_trace_digest_to_adaptive_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence.json"
            evidence.write_text(
                json.dumps(
                    {
                        "scenario": "adaptive-hls-soak",
                        "deviceObservedDurationSeconds": 7200,
                        "deviceIdentifier": "fixture-device",
                        "allocationProvenance": {"allocator": "malloc"},
                        "qualificationProducer": self.artifact_producer(
                            "adaptive-hls-soak"
                        ),
                    }
                )
            )
            trace = root / "adaptive-hls-soak-allocations-attempt1.trace"
            trace.mkdir()
            (trace / "data.bin").write_bytes(b"candidate allocation stacks")
            toc = root / "adaptive-hls-soak-allocations-attempt1-toc.xml"
            toc.write_text('<table schema="allocations"/>')
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )

            with mock.patch.object(
                augment_allocation_trace.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_allocation_trace.augment(
                    evidence, trace, toc, digest_script
                )
            record = augmented["allocationProvenance"]["instrumentsTrace"]
            self.assertRegex(record["treeDigest"], r"^[0-9a-f]{64}$")
            self.assertEqual(record["template"], "Allocations")
            self.assertEqual(
                record["runArtifact"],
                "artifacts/evidence/adaptive-hls-soak-allocations-attempt1.trace",
            )
            self.assertTrue((evidence.parent / record["runArtifact"]).is_dir())
            self.assertTrue((evidence.parent / record["tableOfContents"]).is_file())

            toc.write_text("<trace-toc/>")
            with self.assertRaises(augment_allocation_trace.TraceEvidenceError):
                augment_allocation_trace.augment(evidence, trace, toc, digest_script)

    def test_materializes_cadence_matrix_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            rates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
            payload = {
                "formatVersion": 1,
                "scenario": "cadence-matrix",
                "durationSeconds": 600,
                "samples": [
                    {"elapsedSeconds": 0},
                    {"elapsedSeconds": 600},
                ],
                "rates": rates,
                "vfr": True,
                "presentationMetrics": [
                    {"profile": str(rate), "deliveredFrames": 100, "dropRate": 0}
                    for rate in rates
                ]
                + [{"profile": "vfr-24-60", "deliveredFrames": 100, "dropRate": 0}],
                "transitionResults": {
                    "rateChanges": 36,
                    "pauseResumeCycles": 9,
                    "replacements": 8,
                    "resizeCycles": 4,
                    "resizeTargets": ["640x360", "320x180"],
                    "monotonicityViolations": 0,
                },
                "fabricatedDurationCount": 0,
            }
            self.make_export(
                root,
                payload,
                attachment_name="qualification-cadence-matrix.json",
                test_identifier="PiPCadenceDeviceUITests/test_directPiPCadenceMatrix",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-cadence-matrix.json",
                "cadence-matrix",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                duration_seconds=600,
            )
            self.assertEqual(evidence["hardware"], "iphone-current")
            self.assertEqual(evidence["rates"], rates)
            self.assertTrue(evidence["vfr"])
            self.assertEqual(len(evidence["presentationMetrics"]), 9)
            self.assertEqual(evidence["fabricatedDurationCount"], 0)

    def test_host_binds_all_performance_trace_digests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence.json"
            evidence.write_text(
                json.dumps(
                    {
                        "scenario": "pip-render-performance-4k60",
                        "deviceObservedDurationSeconds": 900,
                        "deviceIdentifier": "fixture-device",
                        "metrics": {
                            "gpu": {"status": "required-host-augmentation"},
                            "energy": {"status": "required-host-augmentation"},
                            "conversionCost": {
                                "sourcePixels": 3840 * 2160,
                                "averageMilliseconds": 1.0,
                                "maximumMilliseconds": 1.0,
                                "hostTraceStatus": "required-host-augmentation",
                            },
                        },
                        "hostTraceRequirements": {},
                        "qualificationProducer": self.artifact_producer(
                            "pip-render-performance-4k60"
                        ),
                    }
                )
            )
            traces = {}
            for key in ("game", "power", "time"):
                basename = f"pip-render-performance-4k60-{key}-attempt1"
                trace = root / f"{basename}.trace"
                trace.mkdir()
                (trace / "data.bin").write_bytes(f"{key} instrument data".encode())
                toc = root / f"{basename}-toc.xml"
                toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
                traces[key] = (trace, toc)
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )

            with mock.patch.object(
                augment_performance_traces.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_performance_traces.augment(
                    evidence, traces, digest_script
                )
            self.assertNotIn("hostTraceRequirements", augmented)
            self.assertEqual(augmented["metrics"]["gpu"]["status"], "captured")
            self.assertEqual(
                augmented["metrics"]["energy"]["template"], "Power Profiler"
            )
            conversion_trace = augmented["metrics"]["conversionCost"]["hostTrace"]
            self.assertEqual(conversion_trace["template"], "Time Profiler")
            self.assertRegex(conversion_trace["treeDigest"], r"^[0-9a-f]{64}$")
            for record in (
                augmented["metrics"]["gpu"],
                augmented["metrics"]["energy"],
                conversion_trace,
            ):
                self.assertTrue((evidence.parent / record["runArtifact"]).is_dir())
                self.assertTrue((evidence.parent / record["tableOfContents"]).is_file())

            (traces["game"][0] / "data.bin").unlink()
            with self.assertRaises(augment_performance_traces.PerformanceTraceError):
                augment_performance_traces.augment(evidence, traces, digest_script)

    def test_materializes_and_augments_native_subtitle_matrix(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            support = {
                key: "supported"
                for key in ("text", "styled", "bitmap", "forced", "live", "osd")
            }
            payload = {
                "formatVersion": 1,
                "scenario": "native-subtitle-matrix",
                "durationSeconds": 900,
                "supportMatrix": support,
                "timingTransitions": [{"profile": "text", "pauseResume": "pass"}],
                "metrics": {
                    "cpu": {
                        "value": 10,
                        "hostTraceStatus": "required-host-augmentation",
                    },
                    "gpu": {"status": "required-host-augmentation"},
                    "colorHDRImpact": {
                        "sourcePixelFormat": "yuv420p10le",
                        "screenshotMeasurements": {
                            "baseline": {},
                            "hdrWithSubtitle": {},
                        },
                        "hostTraceStatus": "required-host-augmentation",
                    },
                    "samples": [
                        {"elapsedSeconds": 0},
                        {"elapsedSeconds": 900},
                    ],
                },
                "hostTraceRequirements": {},
            }
            self.make_export(
                root,
                payload,
                attachment_name="qualification-native-subtitle-matrix.json",
                test_identifier="NativeSubtitleMatrixDeviceUITests/test_nativeSubtitleMatrixIsVisibleAndBounded",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-native-subtitle-matrix.json",
                "native-subtitle-matrix",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                duration_seconds=900,
            )
            evidence["qualificationProducer"] = self.artifact_producer(
                "native-subtitle-matrix"
            )
            evidence["deviceIdentifier"] = "fixture-device"
            evidence_path = root / "evidence.json"
            evidence_path.write_text(json.dumps(evidence))
            traces = {}
            for key in ("time", "game", "metal"):
                basename = f"native-subtitle-matrix-{key}-attempt1"
                trace = root / f"{basename}.trace"
                trace.mkdir()
                (trace / "data.bin").write_bytes(f"{key} trace".encode())
                toc = root / f"{basename}-toc.xml"
                toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
                traces[key] = (trace, toc)
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )
            with mock.patch.object(
                augment_native_subtitle_traces.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_native_subtitle_traces.augment(
                    evidence_path, traces, digest_script
                )
            self.assertEqual(augmented["supportMatrix"], support)
            self.assertNotIn("hostTraceRequirements", augmented)
            self.assertEqual(
                augmented["metrics"]["cpu"]["hostTrace"]["template"],
                "Time Profiler",
            )
            self.assertEqual(
                augmented["metrics"]["gpu"]["template"], "Game Performance"
            )
            self.assertEqual(
                augmented["metrics"]["colorHDRImpact"]["hostTrace"]["template"],
                "Metal System Trace",
            )
            records = (
                augmented["metrics"]["cpu"]["hostTrace"],
                augmented["metrics"]["gpu"],
                augmented["metrics"]["colorHDRImpact"]["hostTrace"],
            )
            for record in records:
                self.assertEqual(record["treeDigestAlgorithm"], "swiftvlc-tree-v1")
                self.assertFalse(Path(record["runArtifact"]).is_absolute())
                self.assertFalse(Path(record["tableOfContents"]).is_absolute())
                staged_trace = evidence_path.parent / record["runArtifact"]
                staged_toc = evidence_path.parent / record["tableOfContents"]
                self.assertTrue(staged_trace.is_dir())
                self.assertTrue((staged_trace / "data.bin").is_file())
                self.assertTrue(staged_toc.is_file())

    def test_augments_timebase_raw_capture_and_audio_trace(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "swiftvlc-timebase-fixture-vod-1-vod.jsonl"
            with raw.open("w") as output:
                for index in range(7200):
                    rate = (0.5, 1.0, 2.0)[index // 2400]
                    media_time = (
                        index * 0.5
                        if index < 2400
                        else (
                            1200 + (index - 2400)
                            if index < 4800
                            else 3600 + (index - 4800) * 2
                        )
                    )
                    sample = timebase_raw_sample(index, rate, media_time)
                    output.write(json.dumps(sample) + "\n")
                output.write(json.dumps(timebase_raw_correction(8)) + "\n")
                output.write(
                    json.dumps(
                        timebase_raw_correction(
                            9, reason="playbackRateTransition", drift=0
                        )
                    )
                    + "\n"
                )
            evidence_path = root / "evidence.json"
            evidence_path.write_text(
                json.dumps(
                    {
                        "scenario": "timebase-vod-soak",
                        "durationSeconds": 7200,
                        "deviceObservedDurationSeconds": 7200,
                        "deviceIdentifier": "fixture-device",
                        "corrections": [{"sequence": 8}, {"sequence": 9}],
                        "driftBudget": {"maximumSeconds": 2.1},
                        "correctionBudget": {"maximumSeconds": 2.1},
                        "audioPresentationSeries": {
                            "hostTraceStatus": "required-host-augmentation"
                        },
                        "rawCapture": {
                            "fileName": raw.name,
                            "sampleIntervalSeconds": 1,
                        },
                        "hostTraceRequirements": {
                            "audioPresentationSeries": "Audio System Trace"
                        },
                        "qualificationProducer": self.artifact_producer(
                            "timebase-vod-soak"
                        ),
                    }
                )
            )
            trace = root / "timebase-vod-soak-audio-attempt1.trace"
            trace.mkdir()
            (trace / "data.bin").write_bytes(b"audio trace")
            toc = root / "timebase-vod-soak-audio-attempt1-toc.xml"
            toc.write_text('<trace-toc><table schema="audio-io"/></trace-toc>')
            digest_script = (
                Path(__file__).resolve().parents[2] / "artifact-tree-digest.py"
            )
            with mock.patch.object(
                augment_timebase_evidence.policy,
                "capture_xctrace_export_summary",
                side_effect=self.xctrace_summary,
            ):
                augmented = augment_timebase_evidence.augment(
                    evidence_path, root, trace, toc, digest_script
                )
            self.assertEqual(augmented["rawCapture"]["sampleCount"], 7200)
            self.assertEqual(augmented["rawCapture"]["firstCorrectionSequence"], 8)
            self.assertEqual(
                augmented["audioPresentationSeries"]["hostTrace"]["template"],
                "Audio System Trace",
            )
            raw_record = augmented["rawCapture"]
            trace_record = augmented["audioPresentationSeries"]["hostTrace"]
            self.assertEqual(raw_record["digestAlgorithm"], "sha256")
            self.assertTrue(
                (evidence_path.parent / raw_record["runArtifact"]).is_file()
            )
            self.assertTrue(
                (evidence_path.parent / trace_record["runArtifact"]).is_dir()
            )
            self.assertTrue(
                (evidence_path.parent / trace_record["tableOfContents"]).is_file()
            )
            self.assertNotIn("hostTraceRequirements", augmented)

    def test_timebase_route_enables_decoded_frame_clock_before_sampling(self):
        source = (
            ROOT.parent
            / "Showcase"
            / "iOS"
            / "ValidationHarness"
            / "TimebaseSoakValidationCase.swift"
        ).read_text()
        self.assertLess(
            source.index("controller.enableFrameContentDiagnostics()"),
            source.index("controller.timebaseDiagnosticSnapshot()"),
        )

    def test_rejects_gap_in_raw_timebase_corrections(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.jsonl"
            lines = [
                timebase_raw_sample(0, 1, 0),
                timebase_raw_correction(4),
                timebase_raw_correction(6),
            ]
            raw.write_text("".join(json.dumps(line) + "\n" for line in lines))
            with self.assertRaises(augment_timebase_evidence.TimebaseEvidenceError):
                augment_timebase_evidence.raw_record(
                    root,
                    {"fileName": raw.name, "sampleIntervalSeconds": 1},
                    1,
                )

    def test_rejects_raw_timebase_capture_without_drift_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.jsonl"
            sample = timebase_raw_sample(0, 1, 0)
            sample["clock"].pop("driftSeconds")
            raw.write_text(json.dumps(sample) + "\n")
            with self.assertRaisesRegex(
                augment_timebase_evidence.TimebaseEvidenceError,
                "missing clock-drift samples",
            ):
                augment_timebase_evidence.raw_record(
                    root,
                    {"fileName": raw.name, "sampleIntervalSeconds": 1},
                    1,
                )

    def test_rejects_duplicate_raw_timebase_timeline_samples(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            raw = root / "capture.jsonl"
            sample = timebase_raw_sample(0, 1, 0)
            raw.write_text(json.dumps(sample) + "\n" + json.dumps(sample) + "\n")
            with self.assertRaisesRegex(
                augment_timebase_evidence.TimebaseEvidenceError,
                "timeline is not strictly increasing",
            ):
                augment_timebase_evidence.raw_record(
                    root,
                    {"fileName": raw.name, "sampleIntervalSeconds": 1},
                    2,
                )

    def test_rejects_mismatched_compact_timebase_correction_sequences(self):
        with self.assertRaisesRegex(
            augment_timebase_evidence.TimebaseEvidenceError,
            "compact and raw correction sequences differ",
        ):
            augment_timebase_evidence.require_matching_correction_sequences(
                [{"sequence": 8}, {"sequence": 10}],
                [8, 9],
            )

    def test_materializes_accepted_start_delayed_failure_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_delayed_start_export(root)
            evidence = materialize_evidence.materialize(
                root,
                "qualification-accepted-start-delayed-failure.json",
                "accepted-start-delayed-failure",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["startResult"], "accepted")
            self.assertEqual(evidence["orderedEvents"][-1], "failedToStart")
            self.assertEqual(evidence["controllerGeneration"], 3)
            self.assertEqual(evidence["mediaGeneration"], 7)
            self.assertTrue(evidence["orderedAttribution"])

    def test_materializes_failed_start_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_delayed_start_export(root)
            evidence = materialize_evidence.materialize(
                root,
                "qualification-failed-start.json",
                "failed-start",
                "ipad-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["hardware"], "ipad-current")
            self.assertEqual(evidence["events"]["failedToStartCount"], 1)
            self.assertEqual(evidence["events"]["didStartCount"], 0)
            self.assertTrue(evidence["failureSurfaced"])

    def test_delayed_start_all_outputs_contract_is_exact(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_delayed_start_export(root)
            manifest_path = root / "manifest.json"
            manifest = json.loads(manifest_path.read_text())

            for label, mutation in {
                "missing sibling": lambda value: value[0]["attachments"].pop(),
                "unknown sibling": lambda value: value[0]["attachments"].append(
                    {
                        "exportedFileName": "delayed-start-0.json",
                        "suggestedHumanReadableName": "qualification-unknown.json",
                    }
                ),
            }.items():
                with self.subTest(label=label):
                    candidate = json.loads(json.dumps(manifest))
                    mutation(candidate)
                    manifest_path.write_text(json.dumps(candidate))
                    with self.assertRaises(materialize_evidence.EvidenceError):
                        materialize_evidence.materialize(
                            root,
                            "qualification-failed-start.json",
                            "failed-start",
                            "ipad-current",
                            "a" * 64,
                            "b" * 64,
                        )
            manifest_path.write_text(json.dumps(manifest))

    def test_materializes_focused_replacement_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "formatVersion": 1,
                    "scenario": "replacement",
                    "events": {
                        "controllerReplacementCount": 1,
                        "unattributedStopCount": 0,
                        "order": "pass",
                    },
                    "controls": "pass",
                    "recoveryOutcome": "preserved",
                },
                attachment_name="qualification-replacement.json",
                test_identifier="PiPContinuityDeviceUITests/test_nativePiPSurvivesSamePlayerReplacement",
            )
            evidence = materialize_evidence.materialize(
                root,
                "qualification-replacement.json",
                "replacement",
                "iphone-current",
                "a" * 64,
                "b" * 64,
            )
            self.assertEqual(evidence["events"]["controllerReplacementCount"], 1)
            self.assertEqual(evidence["events"]["unattributedStopCount"], 0)
            self.assertEqual(evidence["recoveryOutcome"], "preserved")

    def test_rejects_duplicate_attachments_and_forged_identity(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "scenario": "native-hls-seek-continuity",
                    "artifactDigest": "forged",
                },
                attachment_count=2,
            )
            with self.assertRaises(materialize_evidence.EvidenceError):
                materialize_evidence.materialize(
                    root,
                    "qualification-native-hls-seek-continuity.json",
                    "native-hls-seek-continuity",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

            self.make_export(
                root,
                {
                    "scenario": "native-hls-seek-continuity",
                    "artifactDigest": "forged",
                },
            )
            with self.assertRaises(materialize_evidence.EvidenceError):
                materialize_evidence.materialize(
                    root,
                    "qualification-native-hls-seek-continuity.json",
                    "native-hls-seek-continuity",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

    def test_apple_audio_attachment_cannot_forge_host_source_proof(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {
                    "scenario": "audio-media-services-reset",
                    "sourceRequestProof": {"method": "forged-in-xctest"},
                },
                attachment_name="qualification-audio-media-services-reset.json",
                test_identifier=(
                    "MediaServicesResetDeviceUITests/"
                    "test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs"
                ),
            )
            with self.assertRaisesRegex(
                materialize_evidence.EvidenceError,
                "test attachment may not supply host identity fields: sourceRequestProof",
            ):
                materialize_evidence.materialize(
                    root,
                    "qualification-audio-media-services-reset.json",
                    "audio-media-services-reset",
                    "iphone-current",
                    "a" * 64,
                    "b" * 64,
                )

    def test_materializer_binds_retained_host_source_metrics(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.make_export(
                root,
                {"scenario": "audio-media-services-reset"},
                attachment_name="qualification-audio-media-services-reset.json",
                test_identifier=(
                    "MediaServicesResetDeviceUITests/"
                    "test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs"
                ),
            )
            metrics = root / (
                "apple-audio-source-metrics/"
                "run-audio-media-services-reset/attempt-1.json"
            )
            metrics.parent.mkdir(parents=True)
            metrics.write_text(
                json.dumps(
                    {
                        "formatVersion": 1,
                        "token": "run-audio-reset-1",
                        "masterRequests": 1,
                        "mediaPlaylistRequests": 1,
                        "segmentRequests": 2,
                        "successfulSegments": 2,
                        "successfulSegmentsByVariant": {"low": 0, "high": 2},
                        "retryFailures": 0,
                        "retryRecoveries": 0,
                        "expiredWindows": 0,
                        "discontinuityManifests": 1,
                        "variantTransitions": 0,
                        "clientCompleted": False,
                        "playlistTypes": ["vod"],
                        "containers": ["ts"],
                        "variants": ["high"],
                        "modes": ["timebase-vod-ts"],
                        "maxMediaSequenceByMode": {"timebase-vod-ts": 0},
                    },
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
            )
            execution = {"fixture": "same final execution object"}
            attempts = [
                {
                    "attempt": 1,
                    "classification": "passed",
                    "testExecution": execution,
                    "xcresultArtifact": "audio-media-services-reset.xcresult",
                    "xcresultDigestAlgorithm": "swiftvlc-tree-v1",
                    "xcresultDigest": "c" * 64,
                    "xcresultSizeBytes": 123,
                }
            ]
            evidence = materialize_evidence.materialize(
                root,
                "qualification-audio-media-services-reset.json",
                "audio-media-services-reset",
                "iphone-current",
                "a" * 64,
                "b" * 64,
                test_execution=execution,
                retained_root_base=root,
                runner_scenario="audio-media-services-reset",
                attempts=attempts,
                adaptive_source_metrics=metrics,
            )
            proof = evidence["sourceRequestProof"]
            self.assertEqual(proof["formatVersion"], 2)
            self.assertEqual(proof["sourceAttempt"], 1)
            self.assertEqual(proof["attemptToken"], "run-audio-reset-1")
            self.assertEqual(
                proof["metricsDigest"], qualification_policy.sha256_file(metrics)
            )
            self.assertEqual(proof["metricsSizeBytes"], metrics.stat().st_size)


class QualificationRecordAssemblyTests(unittest.TestCase):
    @staticmethod
    def trace_binding(
        trace: Path,
        toc: Path,
        *,
        run_artifact: str,
        toc_artifact: str,
        role: str,
        template: str,
        producer: dict,
        evidence_stem: str,
        scenario: str,
        target_device_identifier: str,
        device_duration: int,
        extra: dict | None = None,
    ) -> dict:
        producer_fields = qualification_policy.host_artifact_producer_fields(
            {"qualificationProducer": producer}, evidence_stem
        )
        summary_path = toc.with_name(f"{trace.stem}-summary.json")
        minimum_duration = qualification_policy.trace_minimum_capture_duration(
            scenario, role, device_duration
        )
        metric, unit = qualification_policy.TRACE_MEASUREMENT_SPECS[role]
        summary = {
            "formatVersion": 1,
            "status": "captured",
            "source": "xctrace-export-v1",
            "runNumber": 1,
            "scenario": scenario,
            "artifactRole": role,
            "template": template,
            "targetProcess": "iOS",
            "targetDeviceIdentifier": target_device_identifier,
            "captureDurationSeconds": minimum_duration,
            "tables": [
                {
                    "schema": f"{role}-samples",
                    "rowCount": 10,
                    "targetProcessRowCount": 10,
                }
            ],
            "totalRowCount": 10,
            "measurement": {
                "metric": metric,
                "unit": unit,
                "sampleCount": 10,
                "targetProcessRowCount": 10,
                "minimumValue": 1.0,
                "averageValue": 1.0,
                "maximumValue": 1.0,
                "timelineStartSeconds": 0.0,
                "timelineEndSeconds": minimum_duration,
                "maximumSampleGapSeconds": 1.0,
                "sourceFields": [f"{role}-fixture-value"],
            },
            "traceTreeDigestAlgorithm": "swiftvlc-tree-v1",
            "traceTreeDigest": qualification_policy.tree_digest(trace),
            "tableOfContentsDigestAlgorithm": "sha256",
            "tableOfContentsDigest": qualification_policy.sha256_file(toc),
            **producer_fields,
        }
        summary_path.write_text(json.dumps(summary, sort_keys=True))
        return {
            "status": "captured",
            "artifactRole": role,
            "template": template,
            "format": "com.apple.instruments.trace",
            "runArtifact": run_artifact,
            "tableOfContents": toc_artifact,
            "treeDigestAlgorithm": "swiftvlc-tree-v1",
            "treeDigest": qualification_policy.tree_digest(trace),
            "treeSizeBytes": qualification_policy.tree_size_bytes(trace),
            "treeEntryCount": qualification_policy.tree_entry_count(trace),
            "tableOfContentsDigestAlgorithm": "sha256",
            "tableOfContentsDigest": qualification_policy.sha256_file(toc),
            "tableOfContentsSizeBytes": toc.stat().st_size,
            "targetProcess": "iOS",
            "exportSummary": summary_path.relative_to(trace.parents[2]).as_posix(),
            "exportSummaryDigestAlgorithm": "sha256",
            "exportSummaryDigest": qualification_policy.sha256_file(summary_path),
            "exportSummarySizeBytes": summary_path.stat().st_size,
            **producer_fields,
            **(extra or {}),
        }

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.matrix = self.root / "matrix.json"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [{"id": "seek"}],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        self.candidate = self.root / "candidate.json"
        catalog = ["iOSUITests/FixtureQualificationTests/test_fixture"]
        self.catalog = catalog
        self.original_xcresult_reader = assemble_record.policy.xcresult_test_document
        self.original_attachment_inspector = (
            assemble_record.policy.inspect_xcresult_qualification_attachments
        )
        assemble_record.policy.xcresult_test_document = lambda _path: {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": identifier,
                    "result": "Passed",
                }
                for identifier in self.catalog
            ]
        }

        def inspect_fixture_attachments(xcresult, expected_owners):
            runner = xcresult.parent.name.removesuffix("-attempt-artifacts")
            attachment_root = xcresult.parent.parent / f"{runner}-attachments"
            try:
                exported = qualification_policy.exported_qualification_attachments(
                    attachment_root, expected_owners
                )
            except qualification_policy.QualificationPolicyError as error:
                raise assemble_record.policy.QualificationPolicyError(
                    str(error)
                ) from error
            return {
                name: {
                    "payload": payload,
                    "sha256": qualification_policy.sha256_file(path),
                    "sizeBytes": path.stat().st_size,
                    "testIdentifier": owner,
                }
                for name, (path, payload, owner) in exported.items()
            }

        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            inspect_fixture_attachments
        )
        self.candidate.write_text(
            json.dumps(
                {
                    "formatVersion": 2,
                    "version": "1.1.0",
                    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
                    "artifactDigest": "a" * 64,
                    "sourceCommit": "b" * 40,
                    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
                    "releaseSourceDigest": "c" * 64,
                    "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
                    "candidateAppDigest": "d" * 64,
                    "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
                    "testRunnerDigest": "e" * 64,
                    "testBundleRelativePath": "PlugIns/iOSUITests.xctest",
                    "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
                    "testBundleDigest": "f" * 64,
                    "baseXCTestRunDigestAlgorithm": "sha256",
                    "baseXCTestRunDigest": "1" * 64,
                    "baseXCTestRunName": "fixture.xctestrun",
                    "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
                    "testCatalogDigest": qualification_policy.catalog_digest(catalog),
                    "testCatalogCount": 1,
                    "testCatalog": catalog,
                    "qualificationMatrixChecksum": self.matrix_checksum,
                    "featureManifestChecksum": "2" * 64,
                    "qualificationProfilesChecksum": "3" * 64,
                    "fixtureManifestChecksum": "4" * 64,
                    "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
                    "qualificationPolicyDigest": qualification_policy.policy_digest(),
                }
            )
        )

    def tearDown(self):
        assemble_record.policy.xcresult_test_document = self.original_xcresult_reader
        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            self.original_attachment_inspector
        )
        self.temporary.cleanup()

    def make_report(self, hardware: str, release_type: str = "stable") -> Path:
        matrix = json.loads(self.matrix.read_text())
        scenario = matrix["scenarios"][0]["id"]
        output_contract = {
            "scenario": scenario,
            "attachmentName": f"qualification-{scenario}.json",
            "testIdentifiers": self.catalog,
        }
        matrix["runnerContracts"] = [
            {
                "id": runner,
                "selection": {"kind": "exact", "testIdentifiers": self.catalog},
                "outputs": [],
            }
            for runner in sorted(
                qualification_policy.REQUIRED_RELEASE_RUNNER_SCENARIOS - {scenario}
            )
        ] + [{"id": scenario, "outputs": [output_contract]}]
        self.matrix.write_text(json.dumps(matrix))
        duration = qualification_policy.STABLE_MINIMUM_DURATION_SECONDS.get(
            scenario, 10
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        candidate = json.loads(self.candidate.read_text())
        candidate["qualificationMatrixChecksum"] = self.matrix_checksum
        self.candidate.write_text(json.dumps(candidate))
        catalog = qualification_policy.catalog_record(candidate["testCatalog"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        directory = self.root / f"report-{hardware}"
        evidence_directory = directory / "evidence"
        evidence_directory.mkdir(parents=True)
        raw_log_root = directory / "raw-logs"
        raw_log_root.mkdir()
        declared_children = qualification_policy.DECLARED_TEST_CHILD_LOGS.get(scenario)
        for test_index, test_identifier in enumerate(self.catalog, 1):
            children = (
                [None, *sorted(declared_children)] if declared_children else [None]
            )
            for child in children:
                raw_log_name = qualification_policy.test_log_filename(
                    "run",
                    test_identifier,
                    f"00000000-0000-4000-8000-{test_index:012d}",
                    child=child,
                )
                (raw_log_root / raw_log_name).write_text(
                    json.dumps(
                        {
                            "ts": "2026-08-31T12:00:00Z",
                            "level": "debug",
                            "module": qualification_policy.LOG_MIRROR_HEALTH_MODULE,
                            "message": qualification_policy.LOG_MIRROR_HEALTH_MESSAGE,
                        }
                    )
                    + "\n"
                )
        error_inventory = qualification_policy.build_error_inventory(
            raw_log_root,
            "run",
            scenario,
            retained_root=raw_log_root.name,
            expected_test_catalog=catalog,
        )
        attachment_directory = directory / f"{scenario}-attachments"
        attachment_directory.mkdir()
        attachment_payload = attachment_directory / "payload.json"
        raw_attachment = {
            "scenario": scenario,
            "outcome": "pass",
            "durationSeconds": duration,
        }
        if scenario in qualification_policy.RAW_HOST_TRACE_REQUIREMENTS:
            raw_attachment["hostTraceRequirements"] = (
                qualification_policy.RAW_HOST_TRACE_REQUIREMENTS[scenario]
            )
        if scenario in {"timebase-vod-soak", "timebase-live-soak"}:
            mode = "vod" if scenario == "timebase-vod-soak" else "live"
            raw_attachment["rawCapture"] = {
                "status": "required-host-augmentation",
                "fileName": (f"swiftvlc-timebase-fixture-{mode}-1-{mode}.jsonl"),
                "sampleIntervalSeconds": 1,
            }
        attachment_payload.write_text(json.dumps(raw_attachment))
        (attachment_directory / "manifest.json").write_text(
            json.dumps(
                [
                    {
                        "testIdentifier": self.catalog[0],
                        "attachments": [
                            {
                                "suggestedHumanReadableName": output_contract[
                                    "attachmentName"
                                ],
                                "exportedFileName": attachment_payload.name,
                            }
                        ],
                    }
                ]
            )
        )
        attempt_root = directory / f"{scenario}-attempt-artifacts"
        attempt_root.mkdir()
        attempt_log = attempt_root / "attempt-1.log"
        attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
        attempt_bundle = attempt_root / "attempt-1.xcresult"
        attempt_bundle.mkdir()
        (attempt_bundle / "Info.plist").write_text("fixture xcresult")
        attempts = qualification_policy.bind_attempt_artifacts(
            [
                {
                    "attempt": 1,
                    "classification": "passed",
                    "retryable": False,
                    "intendedTestBegan": True,
                    "xcodebuildExitCode": 0,
                    "logArtifact": attempt_log.relative_to(directory).as_posix(),
                    "xcresultArtifact": attempt_bundle.relative_to(
                        directory
                    ).as_posix(),
                    "testExecution": execution,
                }
            ],
            directory,
        )
        evidence = evidence_directory / "seek.json"
        evidence.write_text(
            json.dumps(
                {
                    **{
                        field: candidate[field]
                        for field in qualification_policy.CORE_IDENTITY_FIELDS
                    },
                    "scenario": scenario,
                    "hardware": hardware,
                    "deviceIdentifier": f"fixture-{hardware}",
                    "outcome": "pass",
                    "durationSeconds": duration,
                    "testExecution": execution,
                    "hostErrorInventory": error_inventory,
                    "qualificationProducer": {
                        "runnerScenario": scenario,
                        "sourceAttempt": 1,
                        "sourceXcresultArtifact": attempts[-1]["xcresultArtifact"],
                        "sourceXcresultDigestAlgorithm": attempts[-1][
                            "xcresultDigestAlgorithm"
                        ],
                        "sourceXcresultDigest": attempts[-1]["xcresultDigest"],
                        "sourceXcresultSizeBytes": attempts[-1]["xcresultSizeBytes"],
                        "attachmentName": output_contract["attachmentName"],
                        "attachmentTestIdentifier": output_contract["testIdentifiers"][
                            0
                        ],
                        "retainedAttachmentRoot": attachment_directory.name,
                        "manifestRelativePath": (attachment_directory / "manifest.json")
                        .relative_to(directory)
                        .as_posix(),
                        "manifestDigestAlgorithm": "sha256",
                        "manifestDigest": qualification_policy.sha256_file(
                            attachment_directory / "manifest.json"
                        ),
                        "manifestSizeBytes": (attachment_directory / "manifest.json")
                        .stat()
                        .st_size,
                        "attachmentRelativePath": attachment_payload.relative_to(
                            directory
                        ).as_posix(),
                        "attachmentDigestAlgorithm": "sha256",
                        "attachmentDigest": qualification_policy.sha256_file(
                            attachment_payload
                        ),
                        "attachmentSizeBytes": attachment_payload.stat().st_size,
                    },
                }
            )
        )
        report = directory / "report.json"
        report.write_text(
            json.dumps(
                {
                    **candidate,
                    "qualificationEligibleEnvironment": release_type == "stable",
                    "device": {"udid": f"fixture-{hardware}"},
                    "mode": (
                        "qualification" if release_type == "stable" else "exploratory"
                    ),
                    "result": "pass",
                    "scenarios": [
                        {
                            "scenario": scenario,
                            "result": "pass",
                            "xcodebuildExitCode": 0,
                            "libraryErrorCount": 0,
                            "appLog": "captured",
                            "expectedTestCatalog": catalog,
                            "testExecution": execution,
                            "hostErrorInventory": error_inventory,
                            "attempts": attempts,
                            "attemptArtifactRoot": attempt_root.name,
                            "durationSeconds": duration,
                            "qualificationEvidence": "captured",
                        }
                    ],
                    "qualificationRows": [
                        {
                            "scenario": scenario,
                            "runnerScenario": scenario,
                            "hardware": hardware,
                            "device": f"Fixture {hardware}",
                            "deviceFamily": (
                                "iPhone" if hardware == "iphone" else "iPad"
                            ),
                            "productType": "Fixture1,1",
                            "osVersion": "26.0",
                            "osBuild": "23A1",
                            "osReleaseType": release_type,
                            "fixture": "qualification-fixtures:" + "4" * 64,
                            "duration": f"{duration}s",
                            "durationSeconds": duration,
                            "evidence": "evidence/seek.json",
                            "result": "pass",
                        }
                    ],
                }
            )
        )
        return report

    def add_support_runner(
        self, report_path: Path, runner: str, *, capture_log: bool = True
    ) -> dict:
        report = json.loads(report_path.read_text())
        catalog = qualification_policy.catalog_record(report["testCatalog"])
        execution = {
            "expected": catalog,
            "executed": catalog,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        attempt_root = report_path.parent / f"{runner}-attempt-artifacts"
        attempt_root.mkdir()
        attempt_log = attempt_root / "attempt-1.log"
        attempt_log.write_text("** TEST EXECUTE SUCCEEDED **\n")
        attempt_bundle = attempt_root / "attempt-1.xcresult"
        attempt_bundle.mkdir()
        (attempt_bundle / "Info.plist").write_text("fixture xcresult")
        attempts = qualification_policy.bind_attempt_artifacts(
            [
                {
                    "attempt": 1,
                    "classification": "passed",
                    "retryable": False,
                    "intendedTestBegan": True,
                    "xcodebuildExitCode": 0,
                    "logArtifact": attempt_log.relative_to(
                        report_path.parent
                    ).as_posix(),
                    "xcresultArtifact": attempt_bundle.relative_to(
                        report_path.parent
                    ).as_posix(),
                    "testExecution": execution,
                }
            ],
            report_path.parent,
        )
        inventory = None
        if capture_log:
            raw_root = report_path.parent / f"{runner}-raw-jsonl"
            raw_root.mkdir(parents=True)
            declared_children = qualification_policy.DECLARED_TEST_CHILD_LOGS.get(
                runner
            )
            for test_index, test_identifier in enumerate(self.catalog, 1):
                children = (
                    [None, *sorted(declared_children)] if declared_children else [None]
                )
                for child in children:
                    raw_log_name = qualification_policy.test_log_filename(
                        "run",
                        test_identifier,
                        f"00000000-0000-4000-8000-{test_index:012d}",
                        child=child,
                    )
                    (raw_root / raw_log_name).write_text(
                        json.dumps(
                            {
                                "ts": "2026-08-31T12:00:00Z",
                                "level": "debug",
                                "module": qualification_policy.LOG_MIRROR_HEALTH_MODULE,
                                "message": qualification_policy.LOG_MIRROR_HEALTH_MESSAGE,
                            }
                        )
                        + "\n"
                    )
            inventory = qualification_policy.build_error_inventory(
                raw_root,
                "run",
                runner,
                retained_root=raw_root.relative_to(report_path.parent).as_posix(),
                expected_test_catalog=catalog,
            )
        runner_row = {
            "scenario": runner,
            "result": "pass",
            "xcodebuildExitCode": 0,
            "libraryErrorCount": 0,
            "appLog": "captured" if capture_log else "none",
            "expectedTestCatalog": catalog,
            "testExecution": execution,
            "hostErrorInventory": inventory,
            "attempts": attempts,
            "attemptArtifactRoot": attempt_root.name,
            "durationSeconds": 10,
            "qualificationEvidence": "not-applicable",
        }
        report["scenarios"].append(runner_row)
        report_path.write_text(json.dumps(report))
        return runner_row

    def test_assembles_rows_and_copies_candidate_bound_evidence(self):
        output = self.root / "qualification" / "1.1.0.json"
        record = assemble_record.assemble(
            "1.1.0",
            self.candidate,
            self.matrix,
            [self.make_report("iphone"), self.make_report("ipad")],
            output,
        )
        self.assertEqual(len(record["rows"]), 2)
        self.assertEqual(len(record["sourceReports"]), 2)
        self.assertEqual(record["artifactDigest"], "a" * 64)
        for row in record["rows"]:
            self.assertTrue((output.parent / row["evidence"]).is_file())

    def test_rejects_retained_raw_log_swap_extra_delete_and_rename(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        raw_record = payload["scenarios"][0]["hostErrorInventory"]["rawFiles"][0]
        raw = report.parent / "raw-logs" / raw_record["path"]
        original = raw.read_text()
        output = self.root / "qualification" / "1.1.0.json"

        raw.write_text('{"level":"debug","message":"swapped"}\n')
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        raw.write_text(original)

        extra = raw.parent / "run-seek-extra.jsonl"
        extra.write_text('{"level":"error","message":"uninventoryed fatal"}\n')
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        extra.unlink()

        deleted = raw.with_suffix(".saved")
        raw.rename(deleted)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        deleted.rename(raw)

        renamed = raw.with_name("run-seek-renamed.jsonl")
        raw.rename(renamed)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )

    def test_rejects_attempt_deletion_swap_rename_and_type_confusion(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "1.1.0.json"
        attempt_log = report.parent / "seek-attempt-artifacts" / "attempt-1.log"
        attempt_bundle = report.parent / "seek-attempt-artifacts" / "attempt-1.xcresult"
        original_log = attempt_log.read_text()

        attempt_log.write_text("swapped product output\n")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        attempt_log.write_text(original_log)

        saved_log = attempt_log.with_suffix(".saved")
        attempt_log.rename(saved_log)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        saved_log.rename(attempt_log)

        saved_bundle = attempt_bundle.with_suffix(".saved")
        attempt_bundle.rename(saved_bundle)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        saved_bundle.rename(attempt_bundle)

        attempt_bundle.rename(saved_bundle)
        attempt_bundle.write_text("not an xcresult directory")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )
        attempt_bundle.unlink()
        saved_bundle.rename(attempt_bundle)

        attempt_bundle.rename(saved_bundle)
        attempt_bundle.symlink_to(saved_bundle, target_is_directory=True)
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report], output
            )

    def test_rejects_unreferenced_attempt_artifacts(self):
        report = self.make_report("iphone")
        attempt_root = report.parent / "seek-attempt-artifacts"
        (attempt_root / "attempt-2.log").write_text(
            "Fatal decoder heap corruption in omitted prior attempt\n"
        )
        orphan_bundle = attempt_root / "attempt-2.xcresult"
        orphan_bundle.mkdir()
        (orphan_bundle / "Info.plist").write_text("orphaned xcresult")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "orphan.json",
            )

    def test_rejects_unrelated_runner_substitution_for_qualification_row(self):
        report = self.make_report("iphone")
        analyzer = self.add_support_runner(report, "analyzer", capture_log=False)
        payload = json.loads(report.read_text())
        payload["scenarios"] = [analyzer]
        report.write_text(json.dumps(payload))
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "substituted-runner.json",
            )

    def test_rejects_runner_duration_that_does_not_underwrite_evidence(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["scenarios"][0]["durationSeconds"] = 1
        report.write_text(json.dumps(payload))
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "short-runner.json",
            )

    def test_record_reopens_runner_duration_binding(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "duration-record.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        binding = record["sourceReports"][0]
        retained_root = output.parent / binding["path"]
        retained_report = retained_root / binding["reportRelativePath"]
        retained_payload = json.loads(retained_report.read_text())
        retained_payload["scenarios"][0]["durationSeconds"] = 1
        retained_report.write_text(json.dumps(retained_payload))
        source_report_relative = (
            Path(binding["path"]) / binding["reportRelativePath"]
        ).as_posix()
        record["runnerScenarios"] = [
            assemble_record.policy.runner_record_summary(
                retained_payload["scenarios"][0], "iphone", source_report_relative
            )
        ]
        binding["reportDigest"] = assemble_record.policy.sha256_file(retained_report)
        binding["reportSizeBytes"] = retained_report.stat().st_size
        binding["treeDigest"] = assemble_record.policy.tree_digest(retained_root)
        binding["treeSizeBytes"] = assemble_record.policy.tree_size_bytes(retained_root)
        output.write_text(json.dumps(record))
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

    def test_rejects_catalog_leaf_outside_candidate_and_runner_contract(self):
        report = self.make_report("iphone")
        unrelated = qualification_policy.catalog_record(
            ["iOSUITests/UnrelatedTests/test_alwaysPasses"]
        )
        execution = {
            "expected": unrelated,
            "executed": unrelated,
            "identityAndCountMatch": True,
            "allPassed": True,
        }
        payload = json.loads(report.read_text())
        payload["scenarios"][0]["expectedTestCatalog"] = unrelated
        payload["scenarios"][0]["testExecution"] = execution
        payload["scenarios"][0]["attempts"][-1]["testExecution"] = execution
        report.write_text(json.dumps(payload))
        original_reader = assemble_record.policy.xcresult_test_document
        assemble_record.policy.xcresult_test_document = lambda _path: {
            "testNodes": [
                {
                    "nodeType": "Test Case",
                    "nodeIdentifier": unrelated["testIdentifiers"][0],
                    "result": "Passed",
                }
            ]
        }
        try:
            with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                assemble_record.policy.validate_report(
                    report,
                    json.loads(self.matrix.read_text()),
                    candidate=json.loads(self.candidate.read_text()),
                    stable_required=True,
                    strict_provenance=True,
                )
            with self.assertRaises(assemble_record.AssemblyError):
                assemble_record.assemble(
                    "1.1.0",
                    self.candidate,
                    self.matrix,
                    [report],
                    self.root / "qualification" / "unrelated-catalog.json",
                )
        finally:
            assemble_record.policy.xcresult_test_document = original_reader

    def test_semantic_evidence_must_exist_in_final_xcresult(self):
        report = self.make_report("iphone")
        original_inspector = (
            assemble_record.policy.inspect_xcresult_qualification_attachments
        )

        def missing_attachment(_xcresult, _expected_names):
            raise assemble_record.policy.QualificationPolicyError(
                "xcresult qualification attachment counts mismatch"
            )

        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            missing_attachment
        )
        try:
            with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                assemble_record.policy.validate_report(
                    report,
                    json.loads(self.matrix.read_text()),
                    candidate=json.loads(self.candidate.read_text()),
                    stable_required=True,
                    strict_provenance=True,
                )
            with self.assertRaises(assemble_record.AssemblyError):
                assemble_record.assemble(
                    "1.1.0",
                    self.candidate,
                    self.matrix,
                    [report],
                    self.root / "qualification" / "missing-attachment.json",
                )
        finally:
            assemble_record.policy.inspect_xcresult_qualification_attachments = (
                original_inspector
            )

        output = self.root / "qualification" / "attachment-record.json"
        assemble_record.assemble("1.1.0", self.candidate, self.matrix, [report], output)
        assemble_record.policy.inspect_xcresult_qualification_attachments = (
            missing_attachment
        )
        try:
            with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                assemble_record.policy.validate_record(
                    output,
                    json.loads(self.matrix.read_text()),
                    expected_identity=json.loads(self.candidate.read_text()),
                    strict_provenance=True,
                    require_complete=False,
                )
        finally:
            assemble_record.policy.inspect_xcresult_qualification_attachments = (
                original_inspector
            )

    def test_attachment_xctest_owner_is_bound_at_report_assembly_and_record(self):
        report = self.make_report("iphone")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        wrong_owner = "iOSUITests/UnrelatedTests/test_siblingProducedEvidence"

        def forge_owner(root: Path) -> None:
            manifest_path = root / "seek-attachments" / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest[0].pop("testIdentifierURL", None)
            manifest[0]["testIdentifier"] = wrong_owner
            manifest_path.write_text(json.dumps(manifest))
            evidence_path = root / "evidence" / "seek.json"
            evidence = json.loads(evidence_path.read_text())
            producer = evidence["qualificationProducer"]
            producer["attachmentTestIdentifier"] = wrong_owner
            producer["manifestDigest"] = qualification_policy.sha256_file(manifest_path)
            producer["manifestSizeBytes"] = manifest_path.stat().st_size
            evidence_path.write_text(json.dumps(evidence))

        forge_owner(report.parent)
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_report(
                report,
                matrix,
                candidate=candidate,
                stable_required=True,
                strict_provenance=True,
            )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "wrong-owner.json",
            )

        report = self.make_report("ipad")
        output = self.root / "qualification" / "owner-record.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        binding = record["sourceReports"][0]
        retained_root = output.parent / binding["path"]
        forge_owner(retained_root)
        binding["treeDigest"] = qualification_policy.tree_digest(retained_root)
        binding["treeSizeBytes"] = qualification_policy.tree_size_bytes(retained_root)
        output.write_text(json.dumps(record))
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

    def test_only_analyzer_may_omit_retained_device_logs(self):
        report = self.make_report("iphone")
        matrix = json.loads(self.matrix.read_text())
        candidate = json.loads(self.candidate.read_text())
        for runner in ("ui-suite", "harness-regressions"):
            with self.subTest(runner=runner):
                support = self.add_support_runner(report, runner, capture_log=False)
                with self.assertRaises(assemble_record.policy.QualificationPolicyError):
                    assemble_record.policy.validate_report(
                        report,
                        matrix,
                        candidate=candidate,
                        stable_required=True,
                        strict_provenance=True,
                    )
                with self.assertRaises(assemble_record.AssemblyError):
                    assemble_record.assemble(
                        "1.1.0",
                        self.candidate,
                        self.matrix,
                        [report],
                        self.root / "qualification" / f"logless-{runner}.json",
                    )
                payload = json.loads(report.read_text())
                payload["scenarios"] = [
                    row for row in payload["scenarios"] if row is not support
                ]
                payload["scenarios"] = [
                    row for row in payload["scenarios"] if row.get("scenario") != runner
                ]
                report.write_text(json.dumps(payload))

        self.add_support_runner(report, "analyzer", capture_log=False)
        assemble_record.policy.validate_report(
            report,
            matrix,
            candidate=candidate,
            stable_required=True,
            strict_provenance=True,
        )

    def test_multitest_support_runners_require_one_healthy_log_family_per_leaf(self):
        self.catalog = [
            "iOSUITests/FirstUITests/test_first",
            "iOSUITests/SecondUITests/test_second",
        ]
        candidate = json.loads(self.candidate.read_text())
        catalog = qualification_policy.catalog_record(self.catalog)
        candidate["testCatalog"] = self.catalog
        candidate["testCatalogCount"] = catalog["testCount"]
        candidate["testCatalogDigest"] = catalog["digest"]
        self.candidate.write_text(json.dumps(candidate))

        for hardware, runner in (
            ("iphone", "ui-suite"),
            ("ipad", "harness-regressions"),
        ):
            with self.subTest(runner=runner):
                report = self.make_report(hardware)
                support = self.add_support_runner(report, runner)
                matrix = json.loads(self.matrix.read_text())
                candidate = json.loads(self.candidate.read_text())
                assemble_record.policy.validate_report(
                    report,
                    matrix,
                    candidate=candidate,
                    stable_required=True,
                    strict_provenance=True,
                )
                inventory = support["hostErrorInventory"]
                missing_record = next(
                    record
                    for record in inventory["rawFiles"]
                    if record["testIdentifier"] == self.catalog[1]
                )
                missing = (
                    report.parent / inventory["retainedRoot"] / missing_record["path"]
                )
                original = missing.read_text()
                for mutation, replacement in (
                    ("deleted", None),
                    ("empty", ""),
                    ("truncated", '{"level":"debug"'),
                ):
                    with self.subTest(runner=runner, mutation=mutation):
                        if replacement is None:
                            missing.unlink()
                        else:
                            missing.write_text(replacement)
                        with self.assertRaises(
                            assemble_record.policy.QualificationPolicyError
                        ):
                            assemble_record.policy.validate_report(
                                report,
                                matrix,
                                candidate=candidate,
                                stable_required=True,
                                strict_provenance=True,
                            )
                        missing.write_text(original)
                missing.unlink()
                with self.assertRaises(assemble_record.AssemblyError):
                    assemble_record.assemble(
                        "1.1.0",
                        self.candidate,
                        self.matrix,
                        [report],
                        self.root / "qualification" / f"missing-{runner}-leaf-log.json",
                    )

    def test_release_runner_coverage_is_required_per_hardware(self):
        iphone = self.make_report("iphone")
        common_release_runners = sorted(
            qualification_policy.REQUIRED_RELEASE_RUNNER_SCENARIOS
            - qualification_policy.IPHONE_CURRENT_ONLY_RUNNER_SCENARIOS
        )
        for runner in common_release_runners:
            self.add_support_runner(iphone, runner, capture_log=runner != "analyzer")
        ipad = self.make_report("ipad")
        output = self.root / "qualification" / "per-hardware.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [iphone, ipad], output
        )
        self.assertTrue(
            set(common_release_runners)
            <= {row["scenario"] for row in record["runnerScenarios"]}
        )
        with self.assertRaisesRegex(
            assemble_record.policy.QualificationPolicyError,
            "missing release runner coverage",
        ):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=True,
            )

    def test_record_reopens_full_retained_attempt_history(self):
        report = self.make_report("iphone")
        output = self.root / "qualification" / "1.1.0.json"
        record = assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report], output
        )
        retained_root = output.parent / record["sourceReports"][0]["path"]
        retained_log = retained_root / "seek-attempt-artifacts" / "attempt-1.log"
        retained_log.write_text("tampered after assembly\n")
        with self.assertRaises(assemble_record.policy.QualificationPolicyError):
            assemble_record.policy.validate_record(
                output,
                json.loads(self.matrix.read_text()),
                expected_identity=json.loads(self.candidate.read_text()),
                strict_provenance=True,
                require_complete=False,
            )

    def test_assembles_digest_verified_allocation_trace_artifacts(self):
        iphone = self.make_report("iphone")
        ipad = self.make_report("ipad")
        evidence_path = iphone.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        artifact_directory = evidence_path.parent / "artifacts" / "seek"
        trace = artifact_directory / "allocations.trace"
        trace.mkdir(parents=True)
        (trace / "data.bin").write_bytes(b"allocation stacks")
        toc = artifact_directory / "allocations-toc.xml"
        toc.write_text('<table schema="allocations"/>')
        summary = artifact_directory / "allocations-summary.json"
        summary.write_text('{"fixture":"xctrace export"}')
        evidence["allocationProvenance"] = {
            "instrumentsTrace": {
                "runArtifact": "artifacts/seek/allocations.trace",
                "tableOfContents": "artifacts/seek/allocations-toc.xml",
                "treeDigestAlgorithm": "swiftvlc-tree-v1",
                "treeDigest": assemble_record.tree_digest(trace),
                "exportSummary": "artifacts/seek/allocations-summary.json",
                "exportSummaryDigestAlgorithm": "sha256",
                "exportSummaryDigest": qualification_policy.sha256_file(summary),
                "exportSummarySizeBytes": summary.stat().st_size,
            }
        }
        evidence_path.write_text(json.dumps(evidence))

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [iphone, ipad], output
        )

        retained = output.parent / "evidence" / "1.1.0" / "artifacts" / "seek"
        self.assertTrue((retained / "allocations.trace" / "data.bin").is_file())
        self.assertTrue((retained / "allocations-toc.xml").is_file())
        self.assertTrue((retained / "allocations-summary.json").is_file())

    def test_assembles_digest_verified_performance_trace_artifacts(self):
        scenario = "pip-render-performance-4k60"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [
                        {
                            "id": scenario,
                            "hardware": ["iphone"],
                            "minimumDurationSeconds": 900,
                        }
                    ],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone")
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        evidence["profile"] = "4k60"
        evidence["deviceObservedDurationSeconds"] = 900
        evidence["hostAttemptDurationSeconds"] = 900
        evidence["samples"] = [
            {
                "elapsedSeconds": elapsed,
                "residentBytes": 100_000_000,
                "cpuSeconds": elapsed * 2,
                "thermalState": "nominal",
                "sourceWidth": 3840,
                "sourceHeight": 2160,
                "targetWidth": 640,
                "targetHeight": 360,
                "presentationCopyFrames": elapsed * 60 + 1,
                "presentationCopyFailures": 0,
                "measuredConversionCount": elapsed * 60 + 1,
                "decodedContentChanges": elapsed * 60 + 1,
                "displayConsumeFailures": 0,
                "renderPoolAllocationFailureCount": 0,
                "lastRenderPoolAllocationStatus": None,
                "deliveredFrameCount": elapsed * 60 + 1,
                "droppedFrameCount": 0,
            }
            for elapsed in range(0, 901, 5)
        ]
        evidence["systemPiPMotionSeries"] = [
            {
                "elapsedSeconds": elapsed,
                "motionScore": 0.5,
                "distinctFrameHashes": 3,
            }
            for elapsed in range(0, 901, 60)
        ]
        evidence["visualObservations"] = {
            "formatVersion": 1,
            "method": qualification_policy.VISUAL_OBSERVATION_METHOD,
            "records": [
                {
                    "elapsedSeconds": elapsed,
                    "frameHashes": ["a" * 64, "b" * 64, "c" * 64],
                    "adjacentChangedPixelRatios": [0.5, 0.5],
                    "changedPixelScore": 0.5,
                }
                for elapsed in range(0, 901, 60)
            ],
        }
        artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
        trace_records = {}
        roles = {
            "game": ("gpu", "Game Performance"),
            "power": ("energy", "Power Profiler"),
            "time": ("conversionCost", "Time Profiler"),
        }
        for name, (role, template) in roles.items():
            basename = f"{scenario}-{name}-attempt1"
            trace = artifact_directory / f"{basename}.trace"
            trace.mkdir(parents=True)
            (trace / "data.bin").write_bytes(f"{name} samples".encode())
            toc = artifact_directory / f"{basename}-toc.xml"
            toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
            trace_records[name] = self.trace_binding(
                trace,
                toc,
                run_artifact=f"artifacts/{evidence_path.stem}/{basename}.trace",
                toc_artifact=(f"artifacts/{evidence_path.stem}/{basename}-toc.xml"),
                role=role,
                template=template,
                producer=evidence["qualificationProducer"],
                evidence_stem=evidence_path.stem,
                scenario=scenario,
                target_device_identifier="fixture-iphone",
                device_duration=900,
            )
        evidence["metrics"] = {
            "cpu": {
                "value": 1800,
                "unit": "cpu-seconds",
                "source": "Mach task thread times",
            },
            "gpu": trace_records["game"],
            "rss": {
                "baselineBytes": 100_000_000,
                "peakBytes": 100_000_000,
                "finalBytes": 100_000_000,
                "growthBytes": 0,
                "limitBytes": 160 * 1_048_576,
                "peakGrowthBytes": 0,
                "peakLimitBytes": 256 * 1_048_576,
            },
            "energy": trace_records["power"],
            "thermal": {"states": ["nominal"]},
            "conversionCost": {
                "measuredConversions": 54_001,
                "averageMilliseconds": 1.0,
                "maximumMilliseconds": 1.0,
                "hostTrace": trace_records["time"],
            },
            "frameDrops": {"libVLCDropRate": 0.0, "rendererDropRate": 0.0},
            "presentationRate": {
                "value": 60.0,
                "unit": "frames-per-second",
            },
        }
        raw_payload = {
            "scenario": scenario,
            "outcome": "pass",
            "durationSeconds": 900,
            "profile": evidence["profile"],
            "samples": evidence["samples"],
            "visualObservations": evidence["visualObservations"],
            "systemPiPMotionSeries": evidence["systemPiPMotionSeries"],
            "metrics": {
                **evidence["metrics"],
                "gpu": {"status": "required-host-augmentation"},
                "energy": {"status": "required-host-augmentation"},
                "conversionCost": {
                    key: value
                    for key, value in evidence["metrics"]["conversionCost"].items()
                    if key != "hostTrace"
                }
                | {"hostTraceStatus": "required-host-augmentation"},
            },
            "hostTraceRequirements": (
                qualification_policy.RAW_HOST_TRACE_REQUIREMENTS[scenario]
            ),
        }
        attachment_payload = (
            report_path.parent / f"{scenario}-attachments" / "payload.json"
        )
        attachment_payload.write_text(json.dumps(raw_payload))
        evidence["qualificationProducer"]["attachmentDigest"] = (
            qualification_policy.sha256_file(attachment_payload)
        )
        evidence["qualificationProducer"][
            "attachmentSizeBytes"
        ] = attachment_payload.stat().st_size
        evidence_path.write_text(json.dumps(evidence))

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = (
            output.parent / "evidence" / "1.1.0" / "artifacts" / evidence_path.stem
        )
        for name in ("game", "power", "time"):
            basename = f"{scenario}-{name}-attempt1"
            self.assertTrue((retained / f"{basename}.trace" / "data.bin").is_file())
            self.assertTrue((retained / f"{basename}-toc.xml").is_file())

        (retained / f"{scenario}-game-attempt1.trace" / "data.bin").write_bytes(
            b"tampered"
        )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report_path], output
            )

    def test_assembles_digest_verified_native_subtitle_trace_artifacts(self):
        scenario = "native-subtitle-matrix"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [
                        {
                            "id": scenario,
                            "hardware": ["iphone"],
                            "minimumDurationSeconds": 900,
                        }
                    ],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone")
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        evidence["deviceObservedDurationSeconds"] = 900
        evidence["hostAttemptDurationSeconds"] = 900
        artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
        trace_records = {}
        roles = {
            "time": ("cpu", "Time Profiler"),
            "game": ("gpu", "Game Performance"),
            "metal": ("colorHDRImpact", "Metal System Trace"),
        }
        for name, (role, template) in roles.items():
            basename = f"{scenario}-{name}-attempt1"
            trace = artifact_directory / f"{basename}.trace"
            trace.mkdir(parents=True)
            (trace / "data.bin").write_bytes(f"{name} samples".encode())
            toc = artifact_directory / f"{basename}-toc.xml"
            toc.write_text('<trace-toc><table schema="samples"/></trace-toc>')
            trace_records[name] = self.trace_binding(
                trace,
                toc,
                run_artifact=f"artifacts/{evidence_path.stem}/{basename}.trace",
                toc_artifact=(f"artifacts/{evidence_path.stem}/{basename}-toc.xml"),
                role=role,
                template=template,
                producer=evidence["qualificationProducer"],
                evidence_stem=evidence_path.stem,
                scenario=scenario,
                target_device_identifier="fixture-iphone",
                device_duration=900,
            )
        evidence["metrics"] = {
            "cpu": {"hostTrace": trace_records["time"]},
            "gpu": trace_records["game"],
            "colorHDRImpact": {"hostTrace": trace_records["metal"]},
            "samples": [{"elapsedSeconds": elapsed} for elapsed in range(0, 901, 100)],
        }
        evidence_path.write_text(json.dumps(evidence))

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = (
            output.parent / "evidence" / "1.1.0" / "artifacts" / evidence_path.stem
        )
        for name in ("time", "game", "metal"):
            basename = f"{scenario}-{name}-attempt1"
            self.assertTrue((retained / f"{basename}.trace" / "data.bin").is_file())
            self.assertTrue((retained / f"{basename}-toc.xml").is_file())

        (retained / f"{scenario}-metal-attempt1.trace" / "data.bin").write_bytes(
            b"tampered"
        )
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report_path], output
            )

    def test_assembles_digest_verified_timebase_trace_and_raw_capture(self):
        scenario = "timebase-vod-soak"
        self.matrix.write_text(
            json.dumps(
                {
                    "scenarios": [
                        {
                            "id": scenario,
                            "hardware": ["iphone"],
                            "minimumDurationSeconds": 7200,
                        }
                    ],
                    "hardware": [
                        {"id": "iphone", "deviceFamily": "iPhone", "osMajor": 26},
                        {"id": "ipad", "deviceFamily": "iPad", "osMajor": 26},
                    ],
                }
            )
        )
        self.matrix_checksum = hashlib.sha256(self.matrix.read_bytes()).hexdigest()
        report_path = self.make_report("iphone")
        report = json.loads(report_path.read_text())
        report["qualificationRows"][0]["scenario"] = scenario
        report_path.write_text(json.dumps(report))

        evidence_path = report_path.parent / "evidence" / "seek.json"
        evidence = json.loads(evidence_path.read_text())
        evidence["scenario"] = scenario
        evidence["deviceObservedDurationSeconds"] = 7200
        evidence["hostAttemptDurationSeconds"] = 7200
        artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
        trace_basename = f"{scenario}-audio-attempt1"
        trace = artifact_directory / f"{trace_basename}.trace"
        trace.mkdir(parents=True)
        (trace / "data.bin").write_bytes(b"audio samples")
        toc = artifact_directory / f"{trace_basename}-toc.xml"
        toc.write_text('<trace-toc><table schema="audio"/></trace-toc>')
        raw_name = "swiftvlc-timebase-fixture-vod-1-vod.jsonl"
        raw = artifact_directory / raw_name
        raw.write_text(
            "".join(
                json.dumps(
                    timebase_raw_sample(
                        elapsed,
                        (0.5, 1, 2)[elapsed // 2400],
                        (
                            elapsed * 0.5
                            if elapsed < 2400
                            else (
                                1200 + (elapsed - 2400)
                                if elapsed < 4800
                                else 3600 + (elapsed - 4800) * 2
                            )
                        ),
                    )
                )
                + "\n"
                for elapsed in range(7200)
            )
        )
        evidence["audioPresentationSeries"] = {
            "hostTrace": self.trace_binding(
                trace,
                toc,
                run_artifact=(f"artifacts/{evidence_path.stem}/{trace_basename}.trace"),
                toc_artifact=(
                    f"artifacts/{evidence_path.stem}/{trace_basename}-toc.xml"
                ),
                role="audioPresentationSeries",
                template="Audio System Trace",
                producer=evidence["qualificationProducer"],
                evidence_stem=evidence_path.stem,
                scenario=scenario,
                target_device_identifier="fixture-iphone",
                device_duration=7200,
            )
        }
        raw_binding = qualification_policy.inspect_timebase_raw_capture(raw, 1)
        raw_binding.pop("_correctionSequences")
        evidence["rawCapture"] = {
            **raw_binding,
            "runArtifact": f"artifacts/{evidence_path.stem}/{raw_name}",
            "digestAlgorithm": "sha256",
            **qualification_policy.host_artifact_producer_fields(
                evidence, evidence_path.stem
            ),
        }
        evidence["corrections"] = []
        evidence["driftBudget"] = {"maximumSeconds": 2.1}
        evidence["correctionBudget"] = {"maximumSeconds": 2.1}
        evidence_path.write_text(json.dumps(evidence))

        output = self.root / "qualification" / "1.1.0.json"
        assemble_record.assemble(
            "1.1.0", self.candidate, self.matrix, [report_path], output
        )

        retained = (
            output.parent / "evidence" / "1.1.0" / "artifacts" / evidence_path.stem
        )
        self.assertTrue((retained / f"{trace_basename}.trace" / "data.bin").is_file())
        self.assertTrue((retained / f"{trace_basename}-toc.xml").is_file())
        self.assertEqual((retained / raw_name).read_bytes(), raw.read_bytes())

        raw.write_text("tampered\n")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0", self.candidate, self.matrix, [report_path], output
            )

    def test_rejects_exploratory_and_duplicate_rows(self):
        output = self.root / "qualification" / "1.1.0.json"
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [self.make_report("iphone", release_type="beta")],
                output,
            )

        report = self.make_report("ipad")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report, report],
                output,
            )

    def test_rejects_report_identity_mismatch(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["releaseSourceDigest"] = "d" * 64
        report.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_mixed_candidate_app_reports(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["candidateAppDigest"] = "9" * 64
        report.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_failed_report_even_when_it_contains_passing_rows(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["result"] = "fail"
        report.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_candidate_algorithm_mismatch(self):
        payload = json.loads(self.candidate.read_text())
        payload["artifactDigestAlgorithm"] = "sha256-file-only"
        self.candidate.write_text(json.dumps(payload))
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [self.make_report("iphone")],
                self.root / "qualification" / "1.1.0.json",
            )

    def test_rejects_evidence_that_escapes_report_directory(self):
        report = self.make_report("iphone")
        payload = json.loads(report.read_text())
        payload["qualificationRows"][0]["evidence"] = "../outside.json"
        report.write_text(json.dumps(payload))
        (report.parent.parent / "outside.json").write_text("{}")
        with self.assertRaises(assemble_record.AssemblyError):
            assemble_record.assemble(
                "1.1.0",
                self.candidate,
                self.matrix,
                [report],
                self.root / "qualification" / "1.1.0.json",
            )


class FixtureServerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        (self.root / "sample.bin").write_bytes(bytes(range(256)) * 64)
        (self.root / "oracles").mkdir()
        (self.root / "oracles" / "progressive-range.mp4").write_bytes(
            bytes(range(256)) * 64
        )
        for container, suffix in (("ts", ".ts"), ("fmp4", ".m4s")):
            for variant in ("low", "high"):
                directory = self.root / "hls" / "soak" / container / variant
                directory.mkdir(parents=True)
                for index in range(4):
                    (directory / f"segment-{index:03d}{suffix}").write_bytes(
                        f"{container}-{variant}-{index}".encode()
                    )
                if container == "fmp4":
                    (directory / "init.mp4").write_bytes(b"fixture-init")
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
        connection = http.client.HTTPConnection(
            "127.0.0.1", self.server.server_port, timeout=3
        )
        connection.request("GET", path, headers=headers or {})
        response = connection.getresponse()
        return connection, response

    def last_log_record(self) -> dict:
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if self.log.exists() and (lines := self.log.read_text().splitlines()):
                return json.loads(lines[-1])
            time.sleep(0.01)
        self.fail("fixture server did not record the completed request")

    def wait_for_log_path(self, path: str) -> dict:
        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            if self.log.exists():
                for line in reversed(self.log.read_text().splitlines()):
                    record = json.loads(line)
                    if record.get("path") == path:
                        return record
            time.sleep(0.01)
        self.fail(f"fixture server did not record completed request {path}")

    def test_static_file_supports_byte_ranges(self):
        connection, response = self.request(
            "/files/sample.bin", {"Range": "bytes=10-19"}
        )
        self.assertEqual(response.status, 206)
        self.assertEqual(
            response.read(), (self.root / "sample.bin").read_bytes()[10:20]
        )
        connection.close()

        size = (self.root / "sample.bin").stat().st_size
        record = self.last_log_record()
        self.assertEqual(record["requestRange"], "bytes=10-19")
        self.assertEqual(record["responseContentRange"], f"bytes 10-19/{size}")

    def test_progressive_range_transcript_is_command_phase_and_token_bound(self):
        token = "candidate-attempt1"
        connection, response = self.request(
            f"/progressive/{token}/range/media.mp4",
            {"Range": "bytes=0-1023"},
        )
        self.assertEqual(response.status, 206)
        self.assertEqual(len(response.read()), 1024)
        connection.close()

        connection, response = self.request(
            f"/progressive/{token}/range/command",
            {
                fixture_server.PROGRESSIVE_COMMAND_ORIGIN_HEADER: fixture_server.PROGRESSIVE_COMMAND_ORIGIN
            },
        )
        marker = json.loads(response.read())
        connection.close()
        self.assertEqual(marker["kind"], "command-marker")
        self.assertEqual(marker["phase"], "post-command")
        self.assertEqual(marker["origin"], fixture_server.PROGRESSIVE_COMMAND_ORIGIN)
        self.assertEqual(marker["precommandRequestCount"], 1)
        self.assertEqual(marker["precommandTransferredBytes"], 1024)

        connection, response = self.request(
            f"/progressive/{token}/range/media.mp4",
            {"Range": "bytes=4096-8191"},
        )
        self.assertEqual(response.status, 206)
        self.assertEqual(len(response.read()), 4096)
        connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        self.assertEqual(transcript["token"], token)
        self.assertEqual(
            [event["sequence"] for event in transcript["events"]], [1, 2, 3]
        )
        first, command, seek = transcript["events"]
        self.assertEqual(
            (first["kind"], first["phase"]), ("media-request", "pre-command")
        )
        self.assertEqual(
            (command["kind"], command["mode"]), ("command-marker", "range")
        )
        self.assertEqual(first["transferredBytesAtCommand"], 1024)
        self.assertIsNone(seek["transferredBytesAtCommand"])
        self.assertEqual(
            (seek["kind"], seek["phase"]), ("media-request", "post-command")
        )
        self.assertEqual(seek["requestRange"], "bytes=4096-8191")
        self.assertEqual(seek["responseStatus"], 206)
        self.assertEqual(
            seek["responseContentRange"],
            f"bytes 4096-8191/{transcript['fixtureBytes']}",
        )
        self.assertEqual(seek["acceptRanges"], "bytes")

    def test_progressive_no_range_ignores_range_and_omits_capability(self):
        token = "candidate-attempt1"
        connection, response = self.request(
            f"/progressive/{token}/no-range/media.mp4",
            {"Range": "bytes=4096-8191"},
        )
        self.assertEqual(response.status, 200)
        self.assertIsNone(response.getheader("Accept-Ranges"))
        self.assertIsNone(response.getheader("Content-Range"))
        self.assertEqual(
            response.read(),
            (self.root / "oracles" / "progressive-range.mp4").read_bytes(),
        )
        connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        event = transcript["events"][0]
        self.assertEqual(event["mode"], "no-range")
        self.assertEqual(event["requestRange"], "bytes=4096-8191")
        self.assertEqual(event["responseStatus"], 200)
        self.assertIsNone(event["responseContentRange"])
        self.assertIsNone(event["acceptRanges"])

    def test_progressive_request_phase_is_fixed_when_request_begins(self):
        token = "candidate-attempt1"
        self.server.chunk_delay = 0.05
        connection, response = self.request(
            f"/progressive/{token}/range/media.mp4",
            {"Range": "bytes=0-16383"},
        )
        self.assertEqual(len(response.read(512)), 512)
        marker_connection, marker_response = self.request(
            f"/progressive/{token}/range/command",
            {
                fixture_server.PROGRESSIVE_COMMAND_ORIGIN_HEADER: fixture_server.PROGRESSIVE_COMMAND_ORIGIN
            },
        )
        self.assertEqual(marker_response.status, 200)
        marker = json.loads(marker_response.read())
        marker_connection.close()
        response.read()
        connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        media = [
            event for event in transcript["events"] if event["kind"] == "media-request"
        ]
        self.assertEqual(len(media), 1)
        self.assertEqual(media[0]["phase"], "pre-command")
        self.assertLess(media[0]["sequence"], transcript["events"][1]["sequence"])
        self.assertEqual(
            media[0]["transferredBytesAtCommand"],
            marker["precommandTransferredBytes"],
        )
        self.assertGreater(marker["precommandTransferredBytes"], 0)
        self.assertLess(marker["precommandTransferredBytes"], 16_384)

    def test_progressive_command_marker_rejects_non_candidate_origin(self):
        token = "candidate-attempt1"
        for headers in (
            {},
            {fixture_server.PROGRESSIVE_COMMAND_ORIGIN_HEADER: "xcui-test-process"},
        ):
            with self.subTest(headers=headers):
                connection, response = self.request(
                    f"/progressive/{token}/range/command", headers
                )
                self.assertEqual(response.status, 400)
                response.read()
                connection.close()

        connection, response = self.request(f"/progressive/{token}/transcript")
        transcript = json.loads(response.read())
        connection.close()
        self.assertEqual(transcript["events"], [])

    def test_out_of_bounds_range_uses_rfc_status(self):
        size = (self.root / "sample.bin").stat().st_size
        connection, response = self.request(
            "/files/sample.bin", {"Range": f"bytes={size}-"}
        )
        self.assertEqual(response.status, 416)
        self.assertEqual(response.getheader("Content-Range"), f"bytes */{size}")
        self.assertEqual(response.read(), b"")
        connection.close()

        record = self.last_log_record()
        self.assertEqual(record["requestRange"], f"bytes={size}-")
        self.assertEqual(record["responseContentRange"], f"bytes */{size}")

    def test_client_reset_does_not_emit_server_traceback(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            try:
                raise ConnectionResetError("fixture client closed keep-alive")
            except ConnectionResetError:
                self.server.handle_error(object(), ("127.0.0.1", 1234))
        self.assertEqual(stderr.getvalue(), "")

    def test_server_close_quiesces_request_log_before_owner_cleanup(self):
        log_directory = self.root / "closing-request-log"
        log_directory.mkdir()
        log_path = log_directory / "requests.jsonl"
        write_started = threading.Event()
        release_write = threading.Event()
        close_finished = threading.Event()
        failures: list[BaseException] = []

        class BlockingRequestLog:
            def __init__(self):
                self.open_count = 0

            def open(self, *args, **kwargs):
                self.open_count += 1
                write_started.set()
                if not release_write.wait(timeout=2):
                    raise TimeoutError("request-log write was never released")
                return log_path.open(*args, **kwargs)

        blocking_log = BlockingRequestLog()
        closing_server = fixture_server.FixtureHTTPServer(
            ("127.0.0.1", 0), self.root, blocking_log, 512, 0, False
        )

        def write_record():
            try:
                closing_server.record({"path": "/late"})
            except BaseException as error:
                failures.append(error)

        def close_server():
            try:
                closing_server.server_close()
            except BaseException as error:
                failures.append(error)
            finally:
                close_finished.set()

        writer = threading.Thread(target=write_record)
        closer = threading.Thread(target=close_server)
        try:
            writer.start()
            self.assertTrue(write_started.wait(timeout=1))
            closer.start()
            self.assertFalse(close_finished.wait(timeout=0.05))

            release_write.set()
            writer.join(timeout=1)
            closer.join(timeout=1)
            self.assertFalse(writer.is_alive())
            self.assertFalse(closer.is_alive())
            self.assertEqual(failures, [])
            self.assertEqual(blocking_log.open_count, 1)

            log_path.unlink()
            log_directory.rmdir()
            closing_server.record({"path": "/after-close"})
            self.assertEqual(blocking_log.open_count, 1)
            self.assertFalse(log_directory.exists())
        finally:
            release_write.set()
            writer.join(timeout=1)
            if closer.ident is not None:
                closer.join(timeout=1)
            closing_server.server_close()

    def test_bind_failure_preserves_original_socket_error(self):
        with self.assertRaises(OSError) as raised:
            fixture_server.FixtureHTTPServer(
                self.server.server_address,
                self.root,
                self.log,
                512,
                0,
                False,
            )

        self.assertEqual(raised.exception.errno, errno.EADDRINUSE)

    def test_stall_endpoint_delays_then_completes(self):
        started = time.monotonic()
        connection, response = self.request("/fault/stall/0.15/sample.bin")
        self.assertEqual(
            len(response.read()), (self.root / "sample.bin").stat().st_size
        )
        self.assertGreaterEqual(time.monotonic() - started, 0.14)
        connection.close()

    def test_live_endpoint_repeats_content(self):
        connection, response = self.request("/live/sample.bin")
        sample = (self.root / "sample.bin").read_bytes()
        self.assertEqual(response.read(len(sample) + 32), sample + sample[:32])
        connection.close()

    def test_gated_stall_waits_only_after_trigger(self):
        self.server.chunk_delay = 0.01
        connection, response = self.request("/fault/gated-stall/test/0.15/sample.bin")
        self.assertEqual(
            response.read(512), (self.root / "sample.bin").read_bytes()[:512]
        )

        trigger_connection, trigger_response = self.request("/fault/trigger/test")
        self.assertEqual(trigger_response.status, 200)
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        started = time.monotonic()
        self.assertEqual(len(response.read(4096)), 4096)
        self.assertGreaterEqual(time.monotonic() - started, 0.14)
        connection.close()

    def test_gated_stall_also_holds_connections_opened_after_trigger(self):
        trigger_connection, trigger_response = self.request("/fault/trigger/new-client")
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        connection, response = self.request(
            "/fault/gated-stall/new-client/0.15/sample.bin"
        )
        started = time.monotonic()
        self.assertEqual(len(response.read(512)), 512)
        self.assertGreaterEqual(time.monotonic() - started, 0.13)
        connection.close()

    def test_gated_close_terminates_active_and_rejects_new_connections(self):
        self.server.chunk_delay = 0.01
        connection, response = self.request("/fault/gated-close/source-loss/sample.bin")
        self.assertEqual(response.status, 200)
        self.assertEqual(response.getheader("Transfer-Encoding"), "chunked")
        self.assertIsNone(response.getheader("Content-Length"))
        self.assertEqual(
            response.read(512), (self.root / "sample.bin").read_bytes()[:512]
        )

        trigger_connection, trigger_response = self.request(
            "/fault/close-trigger/source-loss"
        )
        self.assertEqual(trigger_response.status, 200)
        self.assertEqual(json.loads(trigger_response.read()), {"generation": 1})
        trigger_connection.close()

        with self.assertRaises(http.client.IncompleteRead) as incomplete:
            response.read()
        buffered_after_trigger = incomplete.exception.partial
        unread_remainder = (self.root / "sample.bin").stat().st_size - 512
        self.assertLess(
            len(buffered_after_trigger),
            unread_remainder,
        )
        connection.close()

        rejected_connection, rejected_response = self.request(
            "/fault/gated-close/source-loss/sample.bin"
        )
        self.assertEqual(rejected_response.status, 503)
        rejected_response.read()
        rejected_connection.close()

        retry_connection, retry_response = self.request(
            "/fault/gated-close/source-loss-retry/sample.bin"
        )
        self.assertEqual(retry_response.status, 200)
        self.assertEqual(
            retry_response.read(512),
            (self.root / "sample.bin").read_bytes()[:512],
        )
        cleanup_connection, cleanup_response = self.request(
            "/fault/close-trigger/source-loss-retry"
        )
        self.assertEqual(json.loads(cleanup_response.read()), {"generation": 1})
        cleanup_connection.close()
        with self.assertRaises(http.client.IncompleteRead):
            retry_response.read()
        retry_connection.close()
        self.wait_for_log_path("/fault/gated-close/source-loss-retry/sample.bin")

    def test_adaptive_origin_serves_master_event_and_sliding_live_telemetry(self):
        connection, response = self.request("/adaptive/run/vod-ts/master.m3u8")
        master = response.read().decode()
        connection.close()
        self.assertEqual(response.status, 200)
        self.assertIn("RESOLUTION=320x180", master)
        self.assertIn("RESOLUTION=640x360", master)

        connection, response = self.request("/adaptive/run/event-fmp4/low.m3u8")
        event = response.read().decode()
        connection.close()
        self.assertIn("#EXT-X-PLAYLIST-TYPE:EVENT", event)
        self.assertIn("#EXT-X-MAP", event)
        self.assertIn("#EXT-X-DISCONTINUITY", event)

        connection, response = self.request("/adaptive/run/live-ts/high.m3u8")
        first_live = response.read().decode()
        connection.close()
        self.server._adaptive_started_at[("run", "live-ts", "high")] -= 4
        connection, response = self.request("/adaptive/run/live-ts/high.m3u8")
        second_live = response.read().decode()
        connection.close()
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:0", first_live)
        self.assertIn("#EXT-X-MEDIA-SEQUENCE:2", second_live)

        connection, response = self.request("/adaptive/run/abr-low-ts/low.m3u8")
        subtitle_vod = response.read().decode()
        connection.close()
        self.assertEqual(subtitle_vod.count("#EXTINF:2.000,"), 60)
        self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", subtitle_vod)
        self.assertIn("#EXT-X-DISCONTINUITY", subtitle_vod)
        self.assertTrue(subtitle_vod.rstrip().endswith("#EXT-X-ENDLIST"))

        connection, response = self.request("/adaptive/run/metrics")
        metrics = json.loads(response.read())
        connection.close()
        self.assertEqual(metrics["formatVersion"], 1)
        self.assertEqual(metrics["token"], "run")
        self.assertEqual(metrics["playlistTypes"], ["event", "live", "vod"])
        self.assertEqual(metrics["containers"], ["fmp4", "ts"])
        self.assertGreater(metrics["expiredWindows"], 0)
        self.assertGreater(metrics["discontinuityManifests"], 0)

        connection, response = self.request("/adaptive/run/complete")
        self.assertEqual(json.loads(response.read()), {"clientCompleted": True})
        connection.close()
        connection, response = self.request("/adaptive/run/metrics")
        self.assertTrue(json.loads(response.read())["clientCompleted"])
        connection.close()

    def test_adaptive_retry_fails_once_then_recovers(self):
        path = "/adaptive/retry/retry-ts/low/segment-000.ts"
        connection, response = self.request(path)
        self.assertEqual(response.status, 503)
        response.read()
        connection.close()

        connection, response = self.request(path)
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), b"ts-low-0")
        connection.close()

        connection, response = self.request("/adaptive/retry/metrics")
        metrics = json.loads(response.read())
        connection.close()
        self.assertEqual(metrics["retryFailures"], 1)
        self.assertEqual(metrics["retryRecoveries"], 1)

    def test_timebase_vod_is_four_hour_seekable_high_variant_timeline(self):
        connection, response = self.request(
            "/adaptive/timebase/timebase-vod-ts/master.m3u8"
        )
        master = response.read().decode()
        connection.close()
        self.assertEqual(master.count("#EXT-X-STREAM-INF:"), 1)
        self.assertIn("RESOLUTION=640x360", master)
        self.assertNotIn("RESOLUTION=320x180", master)

        connection, response = self.request(
            "/adaptive/timebase/timebase-vod-ts/high.m3u8"
        )
        playlist = response.read().decode()
        connection.close()
        segment_count = fixture_server.TIMEBASE_VOD_SECONDS // 2
        self.assertEqual(playlist.count("#EXTINF:2.000,"), segment_count)
        self.assertEqual(playlist.count("?sequence="), segment_count)
        self.assertEqual(
            playlist.count("#EXT-X-DISCONTINUITY\n"),
            segment_count // 4 - 1,
        )
        self.assertIn("#EXT-X-PLAYLIST-TYPE:VOD", playlist)
        self.assertIn("?sequence=7199", playlist)
        self.assertTrue(playlist.rstrip().endswith("#EXT-X-ENDLIST"))

    def test_apple_audio_shell_capture_retains_exact_quiescent_metrics(self):
        token = "hostproof"
        for path in (
            f"/adaptive/{token}/timebase-vod-ts/master.m3u8",
            f"/adaptive/{token}/timebase-vod-ts/high.m3u8",
            f"/adaptive/{token}/timebase-vod-ts/high/segment-000.ts?sequence=0",
            f"/adaptive/{token}/timebase-vod-ts/high/segment-001.ts?sequence=1",
        ):
            connection, response = self.request(path)
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()

        runner = (ROOT / "qualification" / "run-device-tests.sh").read_text()
        start = runner.index("capture_apple_audio_source_metrics() {")
        end = runner.index("\n}\n\nrun_scenario()", start) + 2
        function_source = runner[start:end]
        destination = self.root / "captured" / "attempt-1.json"
        program = (
            "set -euo pipefail\n"
            + function_source
            + '\nBASE_URL="$1"\n'
            + 'capture_apple_audio_source_metrics "$2" 2 "$3"\n'
        )
        subprocess.run(
            [
                "bash",
                "-c",
                program,
                "swiftvlc-source-proof",
                f"http://127.0.0.1:{self.server.server_port}",
                token,
                str(destination),
            ],
            check=True,
            timeout=15,
        )
        retained = json.loads(destination.read_text())
        self.assertEqual(retained["formatVersion"], 1)
        self.assertEqual(retained["token"], token)
        self.assertEqual(retained["segmentRequests"], 2)
        self.assertEqual(retained["successfulSegments"], 2)
        self.assertEqual(retained["successfulSegmentsByVariant"], {"low": 0, "high": 2})

    def test_adaptive_variant_transitions_require_one_multivariant_master(self):
        for path in (
            "/adaptive/transitions/abr-low-ts/low/segment-000.ts",
            "/adaptive/transitions/abr-high-fmp4/high/segment-000.m4s",
        ):
            connection, response = self.request(path)
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()

        connection, response = self.request("/adaptive/transitions/metrics")
        forced_metrics = json.loads(response.read())
        self.assertEqual(forced_metrics["variantTransitions"], 0)
        self.assertEqual(
            forced_metrics["successfulSegmentsByVariant"],
            {"low": 1, "high": 1},
        )
        connection.close()

        for variant in ("low", "high"):
            connection, response = self.request(
                f"/adaptive/transitions/abr-ts/{variant}/segment-000.ts"
            )
            self.assertEqual(response.status, 200)
            response.read()
            connection.close()

        connection, response = self.request("/adaptive/transitions/metrics")
        self.assertEqual(json.loads(response.read())["variantTransitions"], 1)
        connection.close()

    def test_fmp4_generator_places_each_init_beside_its_variant(self):
        script = (ROOT / "qualification" / "generate-fixtures.sh").read_text()
        self.assertIn(
            'cd "$fixture_tmp/hls/soak/fmp4/$variant"',
            script,
        )
        self.assertIn("-hls_fmp4_init_filename init.mp4", script)


if __name__ == "__main__":
    unittest.main()
