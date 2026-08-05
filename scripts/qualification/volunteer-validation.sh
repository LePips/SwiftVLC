#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_ROOT="${SWIFTVLC_VOLUNTEER_RESULTS:-$ROOT_DIR/SwiftVLC Device Reports}"
DEVELOPMENT_TEAM="${SWIFTVLC_DEVELOPMENT_TEAM:-}"
DEVICE_SELECTOR=""
ASSUME_YES=false
ONLY_SCENARIOS=()

usage() {
  cat <<'EOF'
Usage: Validate\ SwiftVLC.command [options]

Connect one unlocked iPhone or iPad with Developer Mode enabled, then run the
complete SwiftVLC physical-device validation suite. A compact, privacy-scrubbed
ZIP is produced for attaching to a GitHub issue. Raw diagnostics remain local.

Options:
  --team TEAM        Apple Development team identifier (normally auto-detected)
  --device ID        Device id, UDID, ECID, or exact device name
  --output PATH      Report directory
  --only SCENARIO    Advanced: repeat to run only named scenario drivers
  --yes              Start without the final confirmation prompt
  -h, --help         Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --team) DEVELOPMENT_TEAM="$2"; shift 2 ;;
    --device) DEVICE_SELECTOR="$2"; shift 2 ;;
    --output) OUTPUT_ROOT="$2"; shift 2 ;;
    --only) ONLY_SCENARIOS+=("$2"); shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Error: unknown option $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo "SwiftVLC physical-device validation"
echo "==================================="
echo

for command in curl defaults git jq python3 shasum swift xcodebuild xcrun; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Error: required tool is unavailable: $command" >&2
    echo "Install the current Xcode and its Command Line Tools, then try again." >&2
    exit 1
  fi
done
if [[ ! -d "$ROOT_DIR/.git" ]]; then
  echo "Error: this validator must currently be run from a Git clone." >&2
  echo "Clone https://github.com/harflabs/SwiftVLC, check out the requested tag," >&2
  echo "then double-click Validate SwiftVLC.command." >&2
  exit 1
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "Error: Xcode's first-launch setup is incomplete." >&2
  echo "Open Xcode once, accept its license, install requested components, and retry." >&2
  exit 1
fi

detect_teams() {
  defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
    | sed -nE 's/^[[:space:]]*teamID = ([A-Z0-9]{10});/\1/p' \
    | sort -u
}

teams=()
while IFS= read -r team; do
  [[ -n "$team" ]] && teams+=("$team")
done < <(detect_teams)
if [[ ${#teams[@]} -eq 0 ]]; then
  echo "Error: Xcode has no Apple developer team available for signing." >&2
  echo "In Xcode > Settings > Accounts, add an Apple ID, then retry." >&2
  echo "A free Personal Team is sufficient." >&2
  exit 1
fi

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  if [[ ${#teams[@]} -eq 1 ]]; then
    DEVELOPMENT_TEAM="${teams[0]}"
  elif [[ -t 0 ]]; then
    echo "Choose the Xcode development team to use:"
    index=1
    for team in "${teams[@]}"; do
      echo "  $index) $team"
      index=$((index + 1))
    done
    printf "Team [1-%s]: " "${#teams[@]}"
    read -r selection
    case "$selection" in
      ''|*[!0-9]*) echo "Error: invalid selection." >&2; exit 2 ;;
    esac
    if [[ "$selection" -lt 1 || "$selection" -gt ${#teams[@]} ]]; then
      echo "Error: invalid selection." >&2
      exit 2
    fi
    DEVELOPMENT_TEAM="${teams[$((selection - 1))]}"
  else
    echo "Error: multiple Xcode development teams were found." >&2
    echo "Re-run with --team TEAM. Available teams: ${teams[*]}" >&2
    exit 2
  fi
else
  configured=false
  for team in "${teams[@]}"; do
    [[ "$team" == "$DEVELOPMENT_TEAM" ]] && configured=true
  done
  if [[ "$configured" != true ]]; then
    echo "Error: team $DEVELOPMENT_TEAM is not available in Xcode." >&2
    echo "Available teams: ${teams[*]}" >&2
    exit 2
  fi
fi

mkdir -p "$OUTPUT_ROOT"
session_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
SESSION_ROOT="$OUTPUT_ROOT/$session_id"
RUNS_ROOT="$SESSION_ROOT/raw"
mkdir -p "$RUNS_ROOT"

HOST_INFO="$SESSION_ROOT/host-info.json"
HOST_ARCH="$(uname -m)" \
MACOS_VERSION="$(sw_vers -productVersion)" \
MACOS_BUILD="$(sw_vers -buildVersion)" \
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')" \
python3 - "$HOST_INFO" <<'PY'
import json
import os
import sys

value = {
    "formatVersion": 1,
    "architecture": os.environ["HOST_ARCH"],
    "macOSVersion": os.environ["MACOS_VERSION"],
    "macOSBuild": os.environ["MACOS_BUILD"],
    "xcode": os.environ["XCODE_VERSION"].strip(),
}
with open(sys.argv[1], "w") as output:
    json.dump(value, output, indent=2, sort_keys=True)
    output.write("\n")
PY

echo "Checking the connected device..."
device_args=(--matrix "$SCRIPT_DIR/matrix.json")
[[ -n "$DEVICE_SELECTOR" ]] && device_args+=(--device "$DEVICE_SELECTOR")
if ! python3 "$SCRIPT_DIR/device-info.py" "${device_args[@]}" \
  > "$SESSION_ROOT/preflight-device.json"; then
  echo "Error: no ready physical iPhone or iPad was found." >&2
  echo "Connect and unlock it, trust this Mac, and enable Developer Mode." >&2
  exit 2
fi

DEVICE_DESCRIPTION=$(jq -r \
  '.selected.marketingName + " on iOS/iPadOS " + .selected.osVersion + " (" + .selected.osBuild + ")"' \
  "$SESSION_ROOT/preflight-device.json")
RUN_MODE=$(jq -r '.mode' "$SESSION_ROOT/preflight-device.json")
echo "Device: $DEVICE_DESCRIPTION"
echo "Evidence mode: $RUN_MODE"
echo "Signing team: $DEVELOPMENT_TEAM"
echo
echo "The complete applicable suite includes UI, playback, PiP, seeking, live/HLS,"
echo "subtitles, interruptions, recovery, cadence, performance, and long soak lanes."
echo "A current-iPhone run can take approximately 8-10 hours. Keep the device"
echo "connected to power, unlocked, and leave this Terminal window open."
echo
if [[ "$ASSUME_YES" != true ]]; then
  printf "Press Return to start, or Control-C to cancel: "
  read -r _
fi

finish() {
  status=$?
  trap - EXIT
  set +e
  run_dir=$(find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d -print | sort | tail -1)
  if [[ -n "$run_dir" ]]; then
    cp "$HOST_INFO" "$run_dir/host-info.json"
    share_zip="$SESSION_ROOT/SwiftVLC-Device-Report-$session_id.zip"
    if python3 "$SCRIPT_DIR/package-volunteer-report.py" "$run_dir" \
      --output "$share_zip" >/dev/null; then
      echo
      echo "Shareable report: $share_zip"
      echo "Raw diagnostics:  $run_dir"
      open -R "$share_zip" >/dev/null 2>&1 || true
    else
      echo "Warning: the shareable report could not be packaged." >&2
      echo "Raw diagnostics remain at: $run_dir" >&2
    fi
  else
    echo "No device run was started; no share report was generated." >&2
  fi
  if [[ "$status" -eq 0 ]]; then
    echo "Validation completed successfully. Attach the ZIP to the GitHub issue."
  else
    echo "Validation did not fully pass (exit $status). The ZIP is still useful; upload it." >&2
  fi
  exit "$status"
}
trap finish EXIT

echo "Downloading and verifying the candidate library artifact if needed..."
"$ROOT_DIR/scripts/setup-dev.sh" --artifact-only --manifest-only

VERSION=$(python3 "$ROOT_DIR/scripts/release-artifact-info.py" \
  "$ROOT_DIR/Package.swift" --field tag)
VERSION=${VERSION#v}
runner_args=(
  --version "$VERSION"
  --development-team "$DEVELOPMENT_TEAM"
  --output "$RUNS_ROOT"
)
[[ -n "$DEVICE_SELECTOR" ]] && runner_args+=(--device "$DEVICE_SELECTOR")
for scenario in "${ONLY_SCENARIOS[@]}"; do
  runner_args+=(--only "$scenario")
done

if jq -e --slurpfile matrix "$SCRIPT_DIR/matrix.json" '
  .mode == "exploratory"
  and .selected.deviceFamily == "iPhone"
  and .selected.osMajor
      > ($matrix[0].hardware[] | select(.id == "iphone-current").osMajor)
' "$SESSION_ROOT/preflight-device.json" >/dev/null 2>&1; then
  runner_args+=(--exploratory-current-only)
fi

"$SCRIPT_DIR/run-device-tests.sh" "${runner_args[@]}"
