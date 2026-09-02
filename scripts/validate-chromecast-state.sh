#!/usr/bin/env bash
# Audited source/mutation/native proof for VLC patch 0034.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:-}"
# Positional override, portable shared override, legacy alias, then OS temp.
WORK_ROOT="${2:-${SWIFTVLC_VALIDATION_TMP_ROOT:-${SWIFTVLC_EXTERNAL_TMPDIR:-${TMPDIR:-/tmp}}}}"

if [[ -z "$VLC_SOURCE_ROOT" || ! -d "$VLC_SOURCE_ROOT" ]]; then
    echo "Usage: $0 <patched-vlc-source> [work-root]" >&2
    exit 2
fi
VLC_SOURCE_ROOT="$(cd "$VLC_SOURCE_ROOT" && pwd)"

mkdir -p "$WORK_ROOT"
WORK_ROOT="$(cd "$WORK_ROOT" && pwd)"

CHECKER="$SCRIPT_DIR/patches/validation/chromecast-state-source-check.py"
PROBE="$SCRIPT_DIR/patches/validation/chromecast-state-probe.cpp"
COMPAT="$SCRIPT_DIR/patches/validation/post-pin-stability-compat.h"
CAST_DIR="$VLC_SOURCE_ROOT/modules/stream_out/chromecast"

EXPECTED_CHECKER_SHA=0bd1b049b103f4a4a2c5ad3f6de23eb97f9fa48be63dcfe65cc460761332704f
EXPECTED_PROBE_SHA=09829a7423bfe73e322b504e17c9cb625dfcdfd4b7f98951abcb6bdbb59d6e9b

for path in \
    "$CHECKER" \
    "$PROBE" \
    "$COMPAT" \
    "$CAST_DIR/chromecast_protocol.hpp" \
    "$CAST_DIR/chromecast_demux_eof.hpp"; do
    if [[ ! -f "$path" ]]; then
        echo "Chromecast state validation input not found: $path" >&2
        exit 1
    fi
done

actual_checker_sha="$(shasum -a 256 "$CHECKER" | awk '{print $1}')"
actual_probe_sha="$(shasum -a 256 "$PROBE" | awk '{print $1}')"
if [[ "$actual_checker_sha" != "$EXPECTED_CHECKER_SHA" ]]; then
    echo "Chromecast source checker hash mismatch: expected $EXPECTED_CHECKER_SHA, got $actual_checker_sha" >&2
    exit 1
fi
if [[ "$actual_probe_sha" != "$EXPECTED_PROBE_SHA" ]]; then
    echo "Chromecast native probe hash mismatch: expected $EXPECTED_PROBE_SHA, got $actual_probe_sha" >&2
    exit 1
fi

python3 "$CHECKER" "$VLC_SOURCE_ROOT"

VALIDATION_DIR="$(mktemp -d "$WORK_ROOT/swiftvlc-chromecast-state.XXXXXX")"
cleanup() {
    rm -rf -- "$VALIDATION_DIR"
}
trap cleanup EXIT INT TERM

if [[ "$(uname -s)" == Darwin ]] && command -v xcrun >/dev/null 2>&1; then
    CXX="$(xcrun --sdk macosx --find clang++)"
    SDK_FLAGS=(-isysroot "$(xcrun --sdk macosx --show-sdk-path)")
else
    CXX="${CXX:-clang++}"
    SDK_FLAGS=()
fi

"$CXX" \
    "${SDK_FLAGS[@]}" \
    -std=c++17 -Wall -Wextra -Werror \
    -include "$COMPAT" \
    -I "$VLC_SOURCE_ROOT/include" \
    -I "$VLC_SOURCE_ROOT/src" \
    -I "$CAST_DIR" \
    "$PROBE" \
    -o "$VALIDATION_DIR/chromecast-state-probe"

"$VALIDATION_DIR/chromecast-state-probe"

echo "PASS Chromecast 0034 validation: checker_sha=$actual_checker_sha probe_sha=$actual_probe_sha tmp=$WORK_ROOT"
