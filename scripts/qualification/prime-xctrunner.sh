#!/usr/bin/env bash
set -euo pipefail

DEVICE=""
BUNDLE_IDENTIFIER=""
WORK_ROOT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    --bundle-identifier) BUNDLE_IDENTIFIER="$2"; shift 2 ;;
    --work-root) WORK_ROOT="$2"; shift 2 ;;
    *) echo "Error: unknown option $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DEVICE" || -z "$BUNDLE_IDENTIFIER" || ! -d "$WORK_ROOT" ]]; then
  echo "Usage: $0 --device ID --bundle-identifier ID --work-root DIRECTORY" >&2
  exit 2
fi

PRIME_JSON=$(mktemp "$WORK_ROOT/runner-prime.XXXXXX")
PRIME_RECOVERY_JSON="$PRIME_JSON.recovery"
PRIME_PID=""
PRIME_TERMINATED=false
LAUNCH_ATTEMPTED=false

read_prime_pid() {
  local json_path="${1:-$PRIME_JSON}"
  [[ -s "$json_path" ]] || return 0
  jq -r '.result.process.processIdentifier // empty' "$json_path" 2>/dev/null || true
}

cleanup() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM
  if [[ "$PRIME_TERMINATED" != true && -z "$PRIME_PID" ]]; then
    PRIME_PID=$(read_prime_pid)
  fi
  if [[ "$PRIME_TERMINATED" != true \
    && ! "$PRIME_PID" =~ ^[1-9][0-9]*$ \
    && "$LAUNCH_ATTEMPTED" == true ]]; then
    # devicectl may have started the remote runner but been interrupted before
    # atomically publishing JSON. Relaunching this exact disposable bundle with
    # --terminate-existing closes that window; the replacement is suspended so
    # it cannot execute tests while we obtain a PID for a forced termination.
    xcrun devicectl device process launch \
      --device "$DEVICE" \
      --start-stopped \
      --no-activate \
      --terminate-existing \
      --timeout 10 \
      --json-output "$PRIME_RECOVERY_JSON" \
      "$BUNDLE_IDENTIFIER" \
      >/dev/null 2>&1 || true
    PRIME_PID=$(read_prime_pid "$PRIME_RECOVERY_JSON")
  fi
  if [[ "$PRIME_TERMINATED" != true && "$PRIME_PID" =~ ^[1-9][0-9]*$ ]]; then
    xcrun devicectl device process terminate \
      --device "$DEVICE" \
      --pid "$PRIME_PID" \
      --kill \
      --timeout 10 \
      >/dev/null 2>&1 || true
  fi
  rm -f -- "$PRIME_JSON" "$PRIME_RECOVERY_JSON"
  exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

LAUNCH_ATTEMPTED=true
xcrun devicectl device process launch \
  --device "$DEVICE" \
  --start-stopped \
  --no-activate \
  --terminate-existing \
  --timeout 20 \
  --json-output "$PRIME_JSON" \
  "$BUNDLE_IDENTIFIER"

PRIME_PID=$(read_prime_pid)
if [[ ! "$PRIME_PID" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: the installed UI-test runner did not return a positive process identifier." >&2
  exit 1
fi

xcrun devicectl device process terminate \
  --device "$DEVICE" \
  --pid "$PRIME_PID" \
  --timeout 20
PRIME_TERMINATED=true
PRIME_PID=""
