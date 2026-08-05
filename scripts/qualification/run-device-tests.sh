#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

VERSION="1.1.0"
DEVICE_SELECTOR=""
CANDIDATE_APP=""
CANDIDATE_METADATA=""
DERIVED_DATA="${SWIFTVLC_DEVICE_DERIVED_DATA:-$ROOT_DIR/.device-test-build}"
FIXTURES="${SWIFTVLC_DEVICE_FIXTURES:-$ROOT_DIR/.qualification-fixtures}"
OUTPUT_ROOT="${SWIFTVLC_DEVICE_RESULTS:-$ROOT_DIR/.qualification-results}"
REQUIRE_STABLE=false
SKIP_BUILD=false
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
  --candidate-metadata PATH
                          Source/app identity JSON for a prebuilt candidate
  --derived-data PATH     Signed UI-test runner build directory
  --fixtures PATH         Generated fixture directory
  --output PATH           Evidence output root
  --only SCENARIO         Repeat to select: analyzer, ui-suite, native-live,
                          direct-live, live-media, background-audio,
                          continuity, capability-convergence,
                          vod-controls, long-stall, failed-start,
                          deferred-pause-rejection,
                          accepted-start-delayed-failure, hls-seek,
                          harness-regressions, ui-failures, thumbnail-preview
  --require-stable        Refuse beta/unknown OS or a non-matching matrix row
  --skip-build            Reuse an existing signed runner in derived data
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
    --candidate-metadata) CANDIDATE_METADATA="$2"; shift 2 ;;
    --derived-data) DERIVED_DATA="$2"; shift 2 ;;
    --fixtures) FIXTURES="$2"; shift 2 ;;
    --output) OUTPUT_ROOT="$2"; shift 2 ;;
    --only) ONLY_SCENARIOS+=("$2"); shift 2 ;;
    --require-stable) REQUIRE_STABLE=true; shift ;;
    --skip-build) SKIP_BUILD=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in git jq python3 shasum tar xcodebuild xcrun; do
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
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
python3 "$SCRIPT_DIR/verify-fixtures.py" "$FIXTURES" > /dev/null
cp "$FIXTURES/manifest.json" "$OUTPUT_DIR/fixture-manifest.json"
FIXTURE_MANIFEST_CHECKSUM=$(shasum -a 256 "$FIXTURES/manifest.json" | cut -d' ' -f1)

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
PIP_LIVE_URL_BASE64=$(printf '%s' "$BASE_URL/live/live.ts" | base64 | tr -d '\r\n')
PIP_LONG_STALL_URL_BASE64=$(printf '%s' \
  "$BASE_URL/fault/gated-stall/long-stall/12/live.ts" | base64 | tr -d '\r\n')
VOD_URL_BASE64=$(printf '%s' "$BASE_URL/files/vod.mp4" | base64 | tr -d '\r\n')

if [[ "$SKIP_BUILD" == false ]]; then
  if [[ ! -d "$ROOT_DIR/Vendor/libvlc.xcframework" ]]; then
    echo "Error: local Vendor/libvlc.xcframework is required to build the candidate." >&2
    exit 1
  fi
  BUILD_SOURCE_IDENTITY=$(python3 "$SCRIPT_DIR/candidate-metadata.py" source \
    --source-root "$ROOT_DIR" \
    --version "$VERSION")
  BUILD_SOURCE_COMMIT=$(jq -r '.sourceCommit' <<< "$BUILD_SOURCE_IDENTITY")
  BUILD_SOURCE_DIGEST=$(jq -r '.releaseSourceDigest' <<< "$BUILD_SOURCE_IDENTITY")
  BUILD_ARTIFACT_DIGEST=$(python3 "$ROOT_DIR/scripts/artifact-tree-digest.py" \
    "$ROOT_DIR/Vendor/libvlc.xcframework")
  BUILD_SOURCE_ROOT="$WORK_DIR/source"
  mkdir -p "$BUILD_SOURCE_ROOT"
  git -C "$ROOT_DIR" archive HEAD | tar -x -C "$BUILD_SOURCE_ROOT"
  ln -s "$ROOT_DIR/Vendor" "$BUILD_SOURCE_ROOT/Vendor"
  "$BUILD_SOURCE_ROOT/scripts/setup-dev.sh" --skip-download \
    > "$OUTPUT_DIR/setup-local-source.log"
  xcodebuild build-for-testing \
    -project "$BUILD_SOURCE_ROOT/Showcase/SwiftVLCShowcase.xcodeproj" \
    -scheme iOS \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    SWIFTVLC_SOURCE_COMMIT="$BUILD_SOURCE_COMMIT" \
    SWIFTVLC_RELEASE_SOURCE_DIGEST="$BUILD_SOURCE_DIGEST" \
    SWIFTVLC_ARTIFACT_DIGEST="$BUILD_ARTIFACT_DIGEST" \
    CODE_SIGNING_ALLOWED=YES \
    > "$OUTPUT_DIR/build.log"
fi

RUNNER_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/iOSUITests-Runner.app"
PREBUILT_CANDIDATE=false
if [[ -n "$CANDIDATE_APP" ]] || [[ "$SKIP_BUILD" == true ]]; then
  PREBUILT_CANDIDATE=true
fi
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

CANDIDATE_IDENTITY="$OUTPUT_DIR/candidate-metadata.json"
if [[ "$PREBUILT_CANDIDATE" == true ]]; then
  if [[ -z "$CANDIDATE_METADATA" || ! -f "$CANDIDATE_METADATA" ]]; then
    echo "Error: --candidate-metadata is required for a prebuilt candidate." >&2
    exit 1
  fi
  python3 "$SCRIPT_DIR/candidate-metadata.py" verify \
    --candidate-app "$CANDIDATE_APP" \
    --xcframework "$ROOT_DIR/Vendor/libvlc.xcframework" \
    --metadata "$CANDIDATE_METADATA" \
    --version "$VERSION" \
    --digest-script "$ROOT_DIR/scripts/artifact-tree-digest.py" \
    > "$WORK_DIR/verified-candidate-metadata.json"
  jq . "$CANDIDATE_METADATA" > "$CANDIDATE_IDENTITY"
else
  python3 "$SCRIPT_DIR/candidate-metadata.py" create \
    --candidate-app "$CANDIDATE_APP" \
    --xcframework "$ROOT_DIR/Vendor/libvlc.xcframework" \
    --version "$VERSION" \
    --digest-script "$ROOT_DIR/scripts/artifact-tree-digest.py" \
    --output "$CANDIDATE_IDENTITY" \
    > /dev/null
fi
CANDIDATE_APP_DIGEST=$(jq -r '.candidateAppDigest' "$CANDIDATE_IDENTITY")
ARTIFACT_DIGEST=$(jq -r '.artifactDigest' "$CANDIDATE_IDENTITY")
SOURCE_COMMIT=$(jq -r '.sourceCommit' "$CANDIDATE_IDENTITY")
SOURCE_DIGEST=$(jq -r '.releaseSourceDigest' "$CANDIDATE_IDENTITY")

XCTESTRUN=$(find "$DERIVED_DATA/Build/Products" -maxdepth 1 -name '*.xctestrun' -type f -print -quit)
if [[ -z "$XCTESTRUN" ]]; then
  echo "Error: no xctestrun was produced in $DERIVED_DATA/Build/Products." >&2
  exit 1
fi
DESTINATION_XCTESTRUN="$WORK_DIR/destination.xctestrun"
python3 "$SCRIPT_DIR/prepare-xctestrun.py" "$XCTESTRUN" "$DESTINATION_XCTESTRUN" \
  --environment SWIFTVLC_PIP_LIVE_URL_BASE64="$PIP_LIVE_URL_BASE64" \
  --environment SWIFTVLC_PIP_CONTINUITY_DEVICE=YES \
  --environment SWIFTVLC_PIP_CAPABILITY_DEVICE=YES \
  --environment SWIFTVLC_PIP_VOD_CONTROLS_DEVICE=YES \
  --environment SWIFTVLC_PIP_LONG_STALL_DEVICE=YES \
  --environment SWIFTVLC_PIP_LONG_STALL_URL_BASE64="$PIP_LONG_STALL_URL_BASE64" \
  --environment SWIFTVLC_PIP_DEFERRED_PAUSE_DEVICE=YES \
  --environment SWIFTVLC_PIP_DELAYED_START_FAILURE_DEVICE=YES \
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

install_app "$CANDIDATE_APP" > "$OUTPUT_DIR/install-candidate.log"
install_app "$RUNNER_APP" > "$OUTPUT_DIR/install-runner.log"

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

DEFAULT_SCENARIOS=(analyzer ui-suite harness-regressions live-media background-audio continuity capability-convergence vod-controls long-stall failed-start deferred-pause-rejection accepted-start-delayed-failure hls-seek)
SCENARIOS_WERE_EXPLICIT=false
if [[ ${#ONLY_SCENARIOS[@]} -eq 0 ]]; then
  ONLY_SCENARIOS=("${DEFAULT_SCENARIOS[@]}")
else
  SCENARIOS_WERE_EXPLICIT=true
fi
for scenario in "${ONLY_SCENARIOS[@]}"; do
  case "$scenario" in
    analyzer|ui-suite|native-live|direct-live|live-media|background-audio|continuity|capability-convergence|vod-controls|long-stall|failed-start|deferred-pause-rejection|accepted-start-delayed-failure|hls-seek|harness-regressions|ui-failures|thumbnail-preview) ;;
    *) echo "Error: unknown scenario: $scenario" >&2; exit 2 ;;
  esac
done

device_matches_hardware_row() {
  local hardware_row="$1"
  jq -e --arg hardware_row "$hardware_row" \
    '.selected.matchingHardwareRows | index($hardware_row) != null' \
    "$OUTPUT_DIR/device.json" > /dev/null
}

if ! device_matches_hardware_row "iphone-current"; then
  if [[ "$SCENARIOS_WERE_EXPLICIT" == true ]]; then
    for scenario in "${ONLY_SCENARIOS[@]}"; do
      if [[ "$scenario" == "capability-convergence" || "$scenario" == "deferred-pause-rejection" || "$scenario" == "accepted-start-delayed-failure" ]]; then
        echo "Error: $scenario requires the iphone-current hardware row." >&2
        exit 2
      fi
    done
  else
    FILTERED_SCENARIOS=()
    for scenario in "${ONLY_SCENARIOS[@]}"; do
      if [[ "$scenario" != "capability-convergence" && "$scenario" != "deferred-pause-rejection" && "$scenario" != "accepted-start-delayed-failure" ]]; then
        FILTERED_SCENARIOS+=("$scenario")
      fi
    done
    ONLY_SCENARIOS=("${FILTERED_SCENARIOS[@]}")
    echo "Skipping iphone-current-only qualification scenarios: selected device does not match iphone-current."
  fi
elif [[ "$SCENARIOS_WERE_EXPLICIT" == false ]]; then
  FILTERED_SCENARIOS=()
  for scenario in "${ONLY_SCENARIOS[@]}"; do
    if [[ "$scenario" != "accepted-start-delayed-failure" ]]; then
      FILTERED_SCENARIOS+=("$scenario")
    fi
  done
  ONLY_SCENARIOS=("${FILTERED_SCENARIOS[@]}")
fi

RESULTS_TSV="$WORK_DIR/results.tsv"
: > "$RESULTS_TSV"
QUALIFICATION_ROWS="$WORK_DIR/qualification-rows.jsonl"
: > "$QUALIFICATION_ROWS"

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
    live-media)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_liveMediaQualificationAcrossNativeAndDirectBackends")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    background-audio)
      test_identifiers=("iOSUITests/PiPLiveDeviceUITests/test_backgroundAudioQualificationWhileAppIsBackgrounded")
      route="PiPLiveValidation"
      pip_url="$BASE_URL/live/live.ts"
      rendering_path="native"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    continuity)
      test_identifiers=("iOSUITests/PiPContinuityDeviceUITests/test_nativePiPSurvivesSamePlayerReplacement")
      if jq -e '.selected.matchingHardwareRows | index("iphone-current") != null' \
          "$OUTPUT_DIR/device.json" >/dev/null; then
        test_identifiers+=("iOSUITests/PiPContinuityDeviceUITests/test_nativePiPReplacementContinuityAcrossVODAndLive")
      fi
      route="HarnessHome"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    capability-convergence)
      test_identifiers=(
        "iOSUITests/PiPCapabilityDeviceUITests/test_capabilityConvergenceAcrossNativeAndDirectBackends"
      )
      route="PiPCapabilityValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    vod-controls)
      test_identifiers=(
        "iOSUITests/PiPVODControlsDeviceUITests/test_vodControlsAcrossNativeAndDirectBackends"
      )
      route="PiPVODControlsValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    long-stall)
      test_identifiers=(
        "iOSUITests/PiPLongStallDeviceUITests/test_longStallRecoversAcrossNativeAndDirectBackends"
      )
      route="PiPLongStallValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    failed-start)
      test_identifiers=(
        "iOSUITests/PiPDelayedStartFailureDeviceUITests/test_acceptedStartRetainsAttributionThroughDelayedFailure"
      )
      route="PiPDelayedStartFailureValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    deferred-pause-rejection)
      test_identifiers=(
        "iOSUITests/PiPDeferredPauseDeviceUITests/test_deferredPauseRejectionAndCancellationStayTruthful"
      )
      route="PiPDeferredPauseValidation"
      selected_xctestrun="$DESTINATION_XCTESTRUN"
      ;;
    accepted-start-delayed-failure)
      test_identifiers=(
        "iOSUITests/PiPDelayedStartFailureDeviceUITests/test_acceptedStartRetainsAttributionThroughDelayedFailure"
      )
      route="PiPDelayedStartFailureValidation"
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
      --environment SWIFTVLC_PIP_CAPABILITY_DEVICE=YES \
      --environment SWIFTVLC_PIP_VOD_CONTROLS_DEVICE=YES \
      --environment SWIFTVLC_PIP_LONG_STALL_DEVICE=YES \
      --environment SWIFTVLC_PIP_LONG_STALL_URL_BASE64="$PIP_LONG_STALL_URL_BASE64" \
      --environment SWIFTVLC_PIP_DEFERRED_PAUSE_DEVICE=YES \
      --environment SWIFTVLC_PIP_DELAYED_START_FAILURE_DEVICE=YES \
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

  local started ended test_status result error_count log_status evidence_status
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
      -skip-testing:iOSUITests/PiPCapabilityDeviceUITests
      -skip-testing:iOSUITests/PiPVODControlsDeviceUITests
      -skip-testing:iOSUITests/PiPLongStallDeviceUITests
      -skip-testing:iOSUITests/PiPDeferredPauseDeviceUITests
      -skip-testing:iOSUITests/PiPDelayedStartFailureDeviceUITests
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
  evidence_status="not-applicable"
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

  local qualification_scenarios=()
  local qualification_attachments=()
  case "$scenario" in
    hls-seek)
      qualification_scenarios=("native-hls-seek-continuity")
      qualification_attachments=("qualification-native-hls-seek-continuity.json")
      ;;
    live-media)
      qualification_scenarios=("live-media")
      qualification_attachments=("qualification-live-media.json")
      ;;
    background-audio)
      qualification_scenarios=("background-audio")
      qualification_attachments=("qualification-background-audio.json")
      ;;
    continuity)
      qualification_scenarios=("replacement")
      qualification_attachments=("qualification-replacement.json")
      if jq -e '.selected.matchingHardwareRows | index("iphone-current") != null' \
          "$OUTPUT_DIR/device.json" >/dev/null; then
        qualification_scenarios+=("replacement-continuity")
        qualification_attachments+=("qualification-replacement-continuity.json")
      fi
      ;;
    capability-convergence)
      qualification_scenarios=("capability-convergence")
      qualification_attachments=("qualification-capability-convergence.json")
      ;;
    vod-controls)
      qualification_scenarios=("vod-controls")
      qualification_attachments=("qualification-vod-controls.json")
      ;;
    long-stall)
      qualification_scenarios=("long-stall")
      qualification_attachments=("qualification-long-stall.json")
      ;;
    failed-start)
      qualification_scenarios=("failed-start")
      qualification_attachments=("qualification-failed-start.json")
      if [[ "$SCENARIOS_WERE_EXPLICIT" == false ]] \
        && device_matches_hardware_row "iphone-current"; then
        qualification_scenarios+=("accepted-start-delayed-failure")
        qualification_attachments+=("qualification-accepted-start-delayed-failure.json")
      fi
      ;;
    deferred-pause-rejection)
      qualification_scenarios=("deferred-pause-rejection")
      qualification_attachments=("qualification-deferred-pause-rejection.json")
      ;;
    accepted-start-delayed-failure)
      qualification_scenarios=("accepted-start-delayed-failure")
      qualification_attachments=("qualification-accepted-start-delayed-failure.json")
      ;;
  esac
  if [[ ${#qualification_scenarios[@]} -gt 0 ]]; then
    evidence_status="missing"
    if [[ "$test_status" -eq 0 ]] && [[ "$error_count" -eq 0 ]] \
      && [[ "$log_status" == "captured" ]] && [[ -d "$result_bundle" ]]; then
      local attachments="$OUTPUT_DIR/$scenario-attachments"
      local hardware_id evidence_file evidence_relative export_status materialize_status
      local evidence_index qualification_scenario qualification_attachment
      local materialized_scenarios=()
      local materialized_evidence=()
      local materialized_count=0
      set +e
      xcrun xcresulttool export attachments \
        --path "$result_bundle" \
        --output-path "$attachments" \
        > "$OUTPUT_DIR/$scenario-export-attachments.log" 2>&1
      export_status=$?
      set -e
      hardware_id=$(jq -r '.selected.matchingHardwareRows | if length == 1 then .[0] else "" end' \
        "$OUTPUT_DIR/device.json")
      if [[ "$export_status" -eq 0 ]] && [[ -n "$hardware_id" ]]; then
        for evidence_index in "${!qualification_scenarios[@]}"; do
          qualification_scenario="${qualification_scenarios[$evidence_index]}"
          qualification_attachment="${qualification_attachments[$evidence_index]}"
          evidence_relative="evidence/$qualification_scenario-$hardware_id.json"
          evidence_file="$OUTPUT_DIR/$evidence_relative"
          set +e
          python3 "$SCRIPT_DIR/materialize-evidence.py" \
            --attachments "$attachments" \
            --attachment-name "$qualification_attachment" \
            --scenario "$qualification_scenario" \
            --hardware "$hardware_id" \
            --artifact-digest "$ARTIFACT_DIGEST" \
            --source-digest "$SOURCE_DIGEST" \
            --output "$evidence_file" \
            > "$OUTPUT_DIR/$scenario-$qualification_scenario-materialize-evidence.log" 2>&1
          materialize_status=$?
          set -e
          if [[ "$materialize_status" -ne 0 ]]; then
            continue
          fi
          materialized_count=$((materialized_count + 1))
          materialized_scenarios+=("$qualification_scenario")
          materialized_evidence+=("$evidence_relative")
        done
        if [[ "$materialized_count" -eq "${#qualification_scenarios[@]}" ]]; then
          evidence_status="captured"
          for evidence_index in "${!materialized_scenarios[@]}"; do
            python3 - \
                "$OUTPUT_DIR/device.json" "$QUALIFICATION_ROWS" \
                "${materialized_evidence[$evidence_index]}" \
                "$FIXTURE_MANIFEST_CHECKSUM" "$((ended - started))" \
                "${materialized_scenarios[$evidence_index]}" <<'PY'
import json
import sys

device_path, rows_path, evidence, fixture_checksum, duration, scenario = sys.argv[1:]
device = json.load(open(device_path))["selected"]
row = {
    "scenario": scenario,
    "hardware": device["matchingHardwareRows"][0],
    "device": device["marketingName"],
    "deviceFamily": device["deviceFamily"],
    "productType": device["productType"],
    "osVersion": device["osVersion"],
    "osBuild": device["osBuild"],
    "osReleaseType": device["osReleaseType"],
    "fixture": f"qualification-fixtures:{fixture_checksum}",
    "duration": f"{duration}s",
    "durationSeconds": int(duration),
    "evidence": evidence,
    "result": "pass",
}
with open(rows_path, "a") as output:
    output.write(json.dumps(row, sort_keys=True) + "\n")
PY
          done
        fi
      fi
    fi
  fi

  result="pass"
  if [[ "$test_status" -ne 0 ]] || [[ "$error_count" -ne 0 ]] || [[ "$log_status" == "missing" ]] \
    || [[ "$evidence_status" == "missing" ]]; then
    result="fail"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$scenario" "$result" "$test_status" "$error_count" "$log_status" "$evidence_status" "$((ended - started))" \
    >> "$RESULTS_TSV"
  echo "$scenario: $result"
}

for scenario in "${ONLY_SCENARIOS[@]}"; do
  run_scenario "$scenario"
done

MATRIX_CHECKSUM=$(shasum -a 256 "$SCRIPT_DIR/matrix.json" | cut -d' ' -f1)

python3 - \
  "$RESULTS_TSV" "$OUTPUT_DIR/report.json" "$OUTPUT_DIR/device.json" \
  "$VERSION" "$SOURCE_COMMIT" "$SOURCE_DIGEST" "$MATRIX_CHECKSUM" \
  "$CANDIDATE_APP_DIGEST" "$ARTIFACT_DIGEST" "$RUN_MODE" "$QUALIFICATION_ROWS" <<'PY'
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
    artifact_digest,
    mode,
    qualification_rows_path,
) = sys.argv[1:]

scenarios = []
with open(results_path) as source:
    for line in source:
        scenario, result, exit_code, errors, log_status, evidence_status, duration = line.rstrip("\n").split("\t")
        scenarios.append(
            {
                "scenario": scenario,
                "result": result,
                "xcodebuildExitCode": int(exit_code),
                "libraryErrorCount": int(errors),
                "appLog": log_status,
                "qualificationEvidence": evidence_status,
                "durationSeconds": int(duration),
            }
        )

device = json.load(open(device_path))["selected"]
with open(qualification_rows_path) as source:
    qualification_rows = [json.loads(line) for line in source if line.strip()]
report = {
    "formatVersion": 1,
    "version": version,
    "mode": mode,
    "qualificationEligibleEnvironment": device["qualificationEligible"],
    "releaseGateSatisfied": False,
    "releaseGateReason": "automated smoke coverage is not yet the complete required matrix",
    "sourceCommit": source_commit,
    "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
    "releaseSourceDigest": source_digest,
    "qualificationMatrixChecksum": matrix_checksum,
    "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
    "candidateAppDigest": app_digest,
    "artifactDigestAlgorithm": "swiftvlc-tree-v1",
    "artifactDigest": artifact_digest,
    "device": device,
    "scenarios": scenarios,
    "qualificationRows": qualification_rows,
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
