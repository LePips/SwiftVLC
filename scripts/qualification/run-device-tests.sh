#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION="1.1.0"
DEVICE_SELECTOR=""
CANDIDATE_APP=""
DERIVED_DATA="${SWIFTVLC_DEVICE_DERIVED_DATA:-$ROOT_DIR/.device-test-build}"
FIXTURES="${SWIFTVLC_DEVICE_FIXTURES:-$ROOT_DIR/.qualification-fixtures}"
OUTPUT_ROOT="${SWIFTVLC_DEVICE_RESULTS:-$ROOT_DIR/.qualification-results}"
REQUIRE_STABLE=false
SKIP_BUILD=false
SKIP_INSTALL=false
ONLY_SCENARIOS=()

usage() {
  cat <<'EOF'
Usage: scripts/qualification/run-device-tests.sh [options]

Runs automated candidate-bound physical iOS smoke tests and captures xcresult,
app-log, fixture-server, device, source, and binary identity evidence.

Options:
  --version VERSION       Candidate version (default: 1.1.0)
  --device IDENTIFIER     CoreDevice id, UDID, ECID, or exact device name
  --candidate-app PATH    Prebuilt signed iOS.app to install and test
  --derived-data PATH     Signed UI-test runner build directory
  --fixtures PATH         Generated fixture directory
  --output PATH           Evidence output root
  --only SCENARIO         Repeat to select: analyzer, ui-suite, native-live,
                          direct-live, continuity, hls-seek,
                          harness-regressions, ui-failures, thumbnail-preview
  --require-stable        Refuse beta/unknown OS or a non-matching matrix row
  --skip-build            Reuse an existing signed runner in derived data
  --skip-install          Reuse candidate and runner already installed on device
  -h, --help              Show this help

Connecting, unlocking, trusting, and enabling Developer Mode are the only
operator steps. A beta OS can run exploratory tests, but never qualifies a
release row.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --device) DEVICE_SELECTOR="$2"; shift 2 ;;
    --candidate-app) CANDIDATE_APP="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    --fixtures) FIXTURES="$2"; shift 2 ;;
    --output) OUTPUT_ROOT="$2"; shift 2 ;;
    --only) ONLY_SCENARIOS+=("$2"); shift 2 ;;
    --require-stable) REQUIRE_STABLE=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    --skip-install) SKIP_INSTALL=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in python3 xcodebuild xcrun jq shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required command is unavailable: $command" >&2
    exit 1
  fi
done

run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
OUTPUT_DIR="$OUTPUT_ROOT/$run_id"
mkdir -p "$OUTPUT_DIR"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-device-tests.XXXXXX")
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

device_args=(--matrix "$SCRIPT_DIR/matrix.json")
if [[ -n "$DEVICE_SELECTOR" ]]; then
  device_args+=(--device "$DEVICE_SELECTOR")
fi
if [[ "$REQUIRE_STABLE" == true ]]; then
  device_args+=(--require-stable)
fi

set +e
python3 "$SCRIPT_DIR/device-info.py" "${device_args[@]}" > "$OUTPUT_DIR/device.json"
device_status=$?
set -e
if [[ "$device_status" -ne 0 ]]; then
  echo "Error: no eligible connected physical iOS device (status $device_status)." >&2
  jq '.connected' "$OUTPUT_DIR/device.json" >&2 || true
  exit "$device_status"
fi

DEVICE_UDID=$(jq -r '.selected.udid' "$OUTPUT_DIR/device.json")
DEVICE_ECID=$(jq -r '.selected.ecidHex' "$OUTPUT_DIR/device.json")
RUN_MODE=$(jq -r '.mode' "$OUTPUT_DIR/device.json")
echo "Selected $(jq -r '.selected.marketingName' "$OUTPUT_DIR/device.json") on $(jq -r '.selected.osVersion' "$OUTPUT_DIR/device.json") ($RUN_MODE)."

if [[ ! -f "$FIXTURES/manifest.json" ]]; then
  "$SCRIPT_DIR/generate-fixtures.sh" "$FIXTURES"
fi
cp "$FIXTURES/manifest.json" "$OUTPUT_DIR/fixture-manifest.json"

READY_FILE="$WORK_DIR/server-ready.json"
python3 "$SCRIPT_DIR/fixture-server.py" \
  --root "$FIXTURES" \
  --ready-file "$READY_FILE" \
  --request-log "$OUTPUT_DIR/fixture-requests.jsonl" \
  > "$OUTPUT_DIR/fixture-server.log" 2>&1 &
SERVER_PID=$!
for _ in {1..100}; do
  [[ -s "$READY_FILE" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Error: fixture server exited before becoming ready." >&2
    exit 1
  fi
  sleep 0.1
done
if [[ ! -s "$READY_FILE" ]]; then
  echo "Error: fixture server did not become ready." >&2
  exit 1
fi
cp "$READY_FILE" "$OUTPUT_DIR/fixture-server.json"
BASE_URL=$(jq -r '.baseURL' "$READY_FILE")
PIP_LIVE_URL_BASE64=$(printf '%s' "$BASE_URL/live/live.ts" | base64)
VOD_URL_BASE64=$(printf '%s' "$BASE_URL/files/vod.mp4" | base64)

if [[ "$SKIP_BUILD" == false ]]; then
  xcodebuild build-for-testing \
    -project "$ROOT_DIR/Showcase/SwiftVLCShowcase.xcodeproj" \
    -scheme iOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=YES \
    > "$OUTPUT_DIR/build.log"
fi

RUNNER_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/iOSUITests-Runner.app"
if [[ -z "$CANDIDATE_APP" ]]; then
  CANDIDATE_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/iOS.app"
fi
for app in "$CANDIDATE_APP" "$RUNNER_APP"; do
  if [[ ! -d "$app" ]]; then
    echo "Error: signed application not found: $app" >&2
    exit 1
  fi
  codesign --verify --deep --strict "$app"
done

XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' -type f -print -quit)
if [[ -z "$XCTESTRUN" ]]; then
  echo "Error: no xctestrun was produced in $DERIVED_DATA/Build/Products." >&2
  exit 1
fi
DESTINATION_XCTESTRUN="$WORK_DIR/destination.xctestrun"
python3 "$SCRIPT_DIR/prepare-xctestrun.py" "$XCTESTRUN" "$DESTINATION_XCTESTRUN" \
  --environment SWIFTVLC_PIP_LIVE_URL_BASE64="$PIP_LIVE_URL_BASE64" \
  --environment SWIFTVLC_PIP_CONTINUITY_DEVICE=YES \
  --environment SWIFTVLC_PIP_OVERLAY_DEVICE=YES \
  --environment SWIFTVLC_PIP_SEEK_DEVICE=YES
cp "$DESTINATION_XCTESTRUN" "$OUTPUT_DIR/destination.xctestrun"

LAUNCH_XCTESTRUN="$WORK_DIR/destination-launch.xctestrun"
python3 "$SCRIPT_DIR/prepare-xctestrun.py" "$XCTESTRUN" "$LAUNCH_XCTESTRUN" \
  --environment SWIFTVLC_DEVICE_FIXTURE_URL_BASE64="$VOD_URL_BASE64" \
  --environment SWIFTVLC_DEVICE_LOG_PREFIX="$run_id"
cp "$LAUNCH_XCTESTRUN" "$OUTPUT_DIR/destination-launch.xctestrun"

install_app() {
  local app="$1"
  local configurator="/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"
  if [[ -x "$configurator" ]]; then
    "$configurator" --ecid "$DEVICE_ECID" install-app "$app"
  else
    xcrun devicectl device install app --device "$DEVICE_UDID" "$app"
  fi
}

if [[ "$SKIP_INSTALL" == false ]]; then
  install_app "$CANDIDATE_APP" > "$OUTPUT_DIR/install-candidate.log"
  install_app "$RUNNER_APP" > "$OUTPUT_DIR/install-runner.log"
else
  printf 'Reused candidate already installed on %s.\n' "$DEVICE_UDID" \
    > "$OUTPUT_DIR/install-candidate.log"
  printf 'Reused runner already installed on %s.\n' "$DEVICE_UDID" \
    > "$OUTPUT_DIR/install-runner.log"
fi

STREAMS_FILE="$WORK_DIR/streams.local.json"
python3 - "$BASE_URL" "$STREAMS_FILE" <<'PY'
import json
import sys

base, output = sys.argv[1:]
value = {
    "liveTS": f"{base}/live/live.ts",
    "hlsLive": f"{base}/files/hls/vod.m3u8",
    "vod": f"{base}/files/vod.mp4",
    "catchup": f"{base}/fault/stall/2/vod.mp4",
    "subtitled": f"{base}/files/hls/vod.m3u8",
    "adaptive": f"{base}/files/hls/vod.m3u8",
    "audioOnly": f"{base}/files/audio.m4a",
}
with open(output, "w") as destination:
    json.dump(value, destination, indent=2, sort_keys=True)
    destination.write("\n")
PY
cp "$STREAMS_FILE" "$OUTPUT_DIR/streams.local.json"
xcrun devicectl device copy to \
  --device "$DEVICE_UDID" \
  --domain-type appDataContainer \
  --domain-identifier com.swiftvlc.showcase.ios \
  --source "$STREAMS_FILE" \
  --destination Documents/streams.local.json \
  > "$OUTPUT_DIR/stage-streams.log"

DEFAULT_SCENARIOS=(analyzer ui-suite harness-regressions native-live direct-live continuity hls-seek)
if [[ ${#ONLY_SCENARIOS[@]} -eq 0 ]]; then
  ONLY_SCENARIOS=("${DEFAULT_SCENARIOS[@]}")
fi
for scenario in "${ONLY_SCENARIOS[@]}"; do
  case "$scenario" in
    analyzer|ui-suite|native-live|direct-live|continuity|hls-seek|harness-regressions|ui-failures|thumbnail-preview) ;;
    *) echo "Error: unknown scenario: $scenario" >&2; exit 2 ;;
  esac
done

RESULTS_TSV="$WORK_DIR/results.tsv"
: > "$RESULTS_TSV"

run_scenario() {
  local scenario="$1"
  local route log_name selected_xctestrun
  local test_identifiers=()
  local skip_device_tests=false
  local pip_url=""
  local rendering_path=""
  case "$scenario" in
    analyzer)
      test_identifiers=("iOSUITests/PiPMotionRegionAnalyzerTests")
      route=""
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    ui-suite)
      test_identifiers=("iOSUITests")
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      skip_device_tests=true
      ;;
    native-live)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_nativeLiveMPEGTSRendersMovingFramesInSystemPiP")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      rendering_path="native"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    direct-live)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_directLiveMPEGTSRendersMovingFramesInSystemPiP")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      rendering_path="direct"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    continuity)
      test_identifiers=("iOSUITests/PiPContinuityDeviceUITests/test_nativePiPSurvivesSamePlayerReplacement")
      route="HarnessHome"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    hls-seek)
      test_identifiers=("iOSUITests/PiPOverlayDeviceUITests/test_nativePiPHLSSeekAndReloadRemainActive")
      route="HarnessHome"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    harness-regressions)
      test_identifiers=(
        "iOSUITests/MusicPlayerUITests/test_switchingTracksKeepsTransportStateAndDoesNotCrash"
        "iOSUITests/PiPUITests/test_deep_toggleButtonDisabledWhenNotPossible"
      )
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      ;;
    ui-failures)
      test_identifiers=(
        "iOSUITests/ThumbnailScrubUITests"
        "iOSUITests/RelativeSeekUITests"
        "iOSUITests/VolumeUITests"
      )
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      ;;
    thumbnail-preview)
      test_identifiers=(
        "iOSUITests/ThumbnailScrubUITests/test_deep_scrubbingKeepsPreviewStableAcrossPositions"
        "iOSUITests/ThumbnailScrubUITests/test_deep_scrubbingShowsPreviewTileOnceLoaded"
        "iOSUITests/ThumbnailScrubUITests/test_perf_firstScrubPreviewAppearsWithinBudget"
      )
      route=""
      selected_xctestrun="$LAUNCH_XCTESTRUN"
      ;;
  esac

  log_name="$scenario.jsonl"
  if [[ -n "$route" ]]; then
    selected_xctestrun="$WORK_DIR/destination-$scenario.xctestrun"
    python3 "$SCRIPT_DIR/prepare-xctestrun.py" "$XCTESTRUN" "$selected_xctestrun" \
      --environment SWIFTVLC_PIP_LIVE_URL_BASE64="$PIP_LIVE_URL_BASE64" \
      --environment SWIFTVLC_PIP_CONTINUITY_DEVICE=YES \
      --environment SWIFTVLC_PIP_OVERLAY_DEVICE=YES \
      --environment SWIFTVLC_PIP_SEEK_DEVICE=YES \
      --environment SWIFTVLC_DEVICE_LOG_PREFIX="$run_id-$scenario"
    cp "$selected_xctestrun" "$OUTPUT_DIR/destination-$scenario.xctestrun"
  elif [[ "$scenario" != "analyzer" ]]; then
    selected_xctestrun="$WORK_DIR/destination-$scenario.xctestrun"
    python3 "$SCRIPT_DIR/prepare-xctestrun.py" "$XCTESTRUN" "$selected_xctestrun" \
      --environment SWIFTVLC_DEVICE_FIXTURE_URL_BASE64="$VOD_URL_BASE64" \
      --environment SWIFTVLC_DEVICE_LOG_PREFIX="$run_id-$scenario"
    cp "$selected_xctestrun" "$OUTPUT_DIR/destination-$scenario.xctestrun"
  fi

  local started ended test_status result error_count log_status
  local xcodebuild_log="$OUTPUT_DIR/$scenario-xcodebuild.log"
  local result_bundle="$OUTPUT_DIR/$scenario.xcresult"
  local test_selection_args=()
  local test_identifier
  for test_identifier in "${test_identifiers[@]}"; do
    test_selection_args+=("-only-testing:$test_identifier")
  done
  if [[ "$skip_device_tests" == true ]]; then
    test_selection_args+=(
      -skip-testing:iOSUITests/PiPLiveDeviceUITests
      -skip-testing:iOSUITests/PiPContinuityDeviceUITests
      -skip-testing:iOSUITests/PiPOverlayDeviceUITests
    )
  fi
  started=$(date +%s)
  local attempt attempt_log attempt_bundle retryable_pattern
  retryable_pattern='LaunchServicesDataMismatch|LaunchServices GUID and sequence number do not match|Early unexpected exit, operation never finished bootstrapping|signal kill before establishing connection|Failed to resume target process|process may have already terminated|reason: Busy|is installing or uninstalling'
  for attempt in 1 2 3; do
    attempt_log="$OUTPUT_DIR/$scenario-xcodebuild-attempt$attempt.log"
    attempt_bundle="$OUTPUT_DIR/$scenario-attempt$attempt.xcresult"
    set +e
    xcodebuild test-without-building \
      -xctestrun "$selected_xctestrun" \
      -destination "platform=iOS,id=$DEVICE_UDID" \
      -collect-test-diagnostics never \
      "${test_selection_args[@]}" \
      -resultBundlePath "$attempt_bundle" \
      > "$attempt_log" 2>&1
    test_status=$?
    set -e
    if [[ "$test_status" -eq 0 ]]; then
      break
    fi
    if [[ "$attempt" -eq 3 ]] || ! grep -qE "$retryable_pattern" "$attempt_log"; then
      break
    fi
    sleep 3
  done
  cp "$attempt_log" "$xcodebuild_log"
  if [[ -d "$attempt_bundle" ]]; then
    cp -R "$attempt_bundle" "$result_bundle"
  fi
  ended=$(date +%s)

  error_count=0
  log_status="none"
  if [[ "$scenario" == "ui-suite" || "$scenario" == "harness-regressions" || "$scenario" == "ui-failures" || "$scenario" == "thumbnail-preview" ]]; then
    local document_capture="$OUTPUT_DIR/$scenario-documents"
    set +e
    xcrun devicectl device copy from \
      --device "$DEVICE_UDID" \
      --domain-type appDataContainer \
      --domain-identifier com.swiftvlc.showcase.ios \
      --source Documents \
      --destination "$document_capture" \
      > "$OUTPUT_DIR/$scenario-pull-log.log" 2>&1
    local pull_status=$?
    set -e
    if [[ "$pull_status" -eq 0 ]]; then
      set +e
      error_count=$(python3 - "$document_capture" "$run_id-$scenario" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
prefix = sys.argv[2] + "-"
files = [path for path in root.rglob("*.jsonl") if path.name.startswith(prefix)]
if not files:
    raise SystemExit(2)
errors = 0
for path in files:
    for line in path.read_text(errors="replace").splitlines():
        try:
            if json.loads(line).get("level") == "error":
                errors += 1
        except json.JSONDecodeError:
            errors += 1
print(errors)
PY
      )
      local aggregate_status=$?
      set -e
      if [[ "$aggregate_status" -eq 0 ]]; then
        log_status="captured"
      else
        error_count=0
        log_status="missing"
      fi
    else
      log_status="missing"
    fi
  elif [[ -n "$route" ]]; then
    local document_capture="$OUTPUT_DIR/$scenario-documents"
    set +e
    xcrun devicectl device copy from \
      --device "$DEVICE_UDID" \
      --domain-type appDataContainer \
      --domain-identifier com.swiftvlc.showcase.ios \
      --source Documents \
      --destination "$document_capture" \
      > "$OUTPUT_DIR/$scenario-pull-log.log" 2>&1
    local pull_status=$?
    set -e
    if [[ "$pull_status" -eq 0 ]]; then
      set +e
      error_count=$(python3 - "$document_capture" "$run_id-$scenario" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
prefix = sys.argv[2] + "-"
files = [path for path in root.rglob("*.jsonl") if path.name.startswith(prefix)]
if not files:
    raise SystemExit(2)
errors = 0
for path in files:
    for line in path.read_text(errors="replace").splitlines():
        try:
            if json.loads(line).get("level") == "error":
                errors += 1
        except json.JSONDecodeError:
            errors += 1
print(errors)
PY
      )
      local aggregate_status=$?
      set -e
      if [[ "$aggregate_status" -eq 0 ]]; then
        log_status="captured"
      else
        error_count=0
        log_status="missing"
      fi
    else
      log_status="missing"
    fi
  fi

  result="pass"
  if [[ "$test_status" -ne 0 ]] || [[ "$error_count" -ne 0 ]] || [[ "$log_status" == "missing" ]]; then
    result="fail"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" "$result" "$test_status" "$error_count" "$log_status" "$((ended - started))" \
    >> "$RESULTS_TSV"
  echo "$scenario: $result"
}

for scenario in "${ONLY_SCENARIOS[@]}"; do
  run_scenario "$scenario"
done

CANDIDATE_APP_DIGEST=$(python3 "$ROOT_DIR/scripts/artifact-tree-digest.py" "$CANDIDATE_APP")
SOURCE_COMMIT=$(git -C "$ROOT_DIR" rev-parse HEAD)
MATRIX_CHECKSUM=$(shasum -a 256 "$SCRIPT_DIR/matrix.json" | cut -d' ' -f1)
set +e
SOURCE_DIGEST=$("$ROOT_DIR/scripts/release-source-digest.py" "$VERSION" 2>/dev/null)
source_digest_status=$?
set -e
if [[ "$source_digest_status" -ne 0 ]]; then
  SOURCE_DIGEST="unavailable-dirty-source"
fi

python3 - \
  "$RESULTS_TSV" "$OUTPUT_DIR/report.json" "$OUTPUT_DIR/device.json" \
  "$VERSION" "$SOURCE_COMMIT" "$SOURCE_DIGEST" "$MATRIX_CHECKSUM" \
  "$CANDIDATE_APP_DIGEST" "$RUN_MODE" <<'PY'
import json
import sys

(
    results_path,
    output_path,
    device_path,
    version,
    source_commit,
    source_digest,
    matrix_checksum,
    app_digest,
    mode,
) = sys.argv[1:]

scenarios = []
with open(results_path) as source:
    for line in source:
        scenario, result, exit_code, errors, log_status, duration = line.rstrip("\n").split("\t")
        scenarios.append(
            {
                "scenario": scenario,
                "result": result,
                "xcodebuildExitCode": int(exit_code),
                "libraryErrorCount": int(errors),
                "appLog": log_status,
                "durationSeconds": int(duration),
            }
        )

device = json.load(open(device_path))["selected"]
report = {
    "formatVersion": 1,
    "version": version,
    "mode": mode,
    "qualificationEligibleEnvironment": device["qualificationEligible"],
    "releaseGateSatisfied": False,
    "releaseGateReason": "automated smoke coverage is not yet the complete required matrix",
    "sourceCommit": source_commit,
    "releaseSourceDigest": source_digest,
    "qualificationMatrixChecksum": matrix_checksum,
    "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
    "candidateAppDigest": app_digest,
    "device": device,
    "scenarios": scenarios,
    "result": "pass" if scenarios and all(row["result"] == "pass" for row in scenarios) else "fail",
}
with open(output_path, "w") as output:
    json.dump(report, output, indent=2, sort_keys=True)
    output.write("\n")
PY

jq '{result, mode, qualificationEligibleEnvironment, releaseGateSatisfied, scenarios}' "$OUTPUT_DIR/report.json"
echo "Evidence: $OUTPUT_DIR"

if [[ $(jq -r '.result' "$OUTPUT_DIR/report.json") != "pass" ]]; then
  exit 1
fi
