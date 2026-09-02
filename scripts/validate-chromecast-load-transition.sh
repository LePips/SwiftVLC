#!/usr/bin/env bash
# Audited inherited/new source mutations plus native probes for VLC patch 0037.

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

CHECKER="$SCRIPT_DIR/patches/validation/chromecast-load-transition-source-check.py"
PROBE="$SCRIPT_DIR/patches/validation/chromecast-load-transition-probe.cpp"
PATCH="$SCRIPT_DIR/patches/0037-chromecast-load-transition-correctness.patch"
SCHEMA_CHECKER="$SCRIPT_DIR/patches/validation/chromecast-metadata-schema-source-check.py"
SCHEMA_PROBE="$SCRIPT_DIR/patches/validation/chromecast-metadata-schema-probe.cpp"
SCHEMA_PATCH="$SCRIPT_DIR/patches/0036-chromecast-metadata-schema-correctness.patch"
WARNING_CHECKER="$SCRIPT_DIR/patches/validation/chromecast-metadata-warning-source-check.py"
WARNING_PATCH="$SCRIPT_DIR/patches/0035-chromecast-metadata-warning.patch"
BASE_CHECKER="$SCRIPT_DIR/patches/validation/chromecast-state-source-check.py"
BASE_PROBE="$SCRIPT_DIR/patches/validation/chromecast-state-probe.cpp"
COMPAT="$SCRIPT_DIR/patches/validation/post-pin-stability-compat.h"
CAST_DIR="$VLC_SOURCE_ROOT/modules/stream_out/chromecast"

EXPECTED_CHECKER_SHA=1d720d36697bb7965d3e8aa333920c2240587addf8b0c30b8a5dfe0127705e0b
EXPECTED_PROBE_SHA=9b34b662485b7932c29c666c5db1e95ba4d9dd2f2f94089f2547d11d0ad64d2a
EXPECTED_PATCH_SHA=dd3c672da9b7a6fcd82e6eadd298d1c5f86ce75e55d86800de8fd83683461105
EXPECTED_SCHEMA_CHECKER_SHA=39fcc62fe9ac56359de49dcd22a54601e9f79d8b20b099fff117661be20ba909
EXPECTED_SCHEMA_PROBE_SHA=d93ac662e8123d8f81ddb415a8a1e543efcd4df42caf240a1935c5792608d08f
EXPECTED_SCHEMA_PATCH_SHA=d2e040c8db4ff529766be4bab875519e8e16242bed4bc645c4a485e422e47295
EXPECTED_WARNING_CHECKER_SHA=155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc
EXPECTED_WARNING_PATCH_SHA=e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d
EXPECTED_BASE_CHECKER_SHA=0bd1b049b103f4a4a2c5ad3f6de23eb97f9fa48be63dcfe65cc460761332704f
EXPECTED_BASE_PROBE_SHA=09829a7423bfe73e322b504e17c9cb625dfcdfd4b7f98951abcb6bdbb59d6e9b
EXPECTED_COMPAT_SHA=13c06861628085b804a245f62222388d34b841d763c4cb471952b565b0db089f

for input_file in \
    "$CHECKER" \
    "$PROBE" \
    "$PATCH" \
    "$SCHEMA_CHECKER" \
    "$SCHEMA_PROBE" \
    "$SCHEMA_PATCH" \
    "$WARNING_CHECKER" \
    "$WARNING_PATCH" \
    "$BASE_CHECKER" \
    "$BASE_PROBE" \
    "$COMPAT" \
    "$CAST_DIR/chromecast_protocol.hpp" \
    "$CAST_DIR/chromecast_demux_eof.hpp" \
    "$VLC_SOURCE_ROOT/modules/stream_out/dlna/dlna.cpp"; do
    if [[ ! -f "$input_file" ]]; then
        echo "Chromecast 0037 validation input not found: $input_file" >&2
        exit 1
    fi
done

check_hash() {
    local input_file="$1"
    local expected="$2"
    local description="$3"
    local actual
    actual="$(shasum -a 256 "$input_file" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "$description hash mismatch: expected $expected, got $actual" >&2
        exit 1
    fi
}

check_hash "$CHECKER" "$EXPECTED_CHECKER_SHA" "Chromecast 0037 source checker"
check_hash "$PROBE" "$EXPECTED_PROBE_SHA" "Chromecast 0037 native probe"
check_hash "$PATCH" "$EXPECTED_PATCH_SHA" "Chromecast 0037 patch"
check_hash "$SCHEMA_CHECKER" "$EXPECTED_SCHEMA_CHECKER_SHA" "Frozen Chromecast 0036 source checker"
check_hash "$SCHEMA_PROBE" "$EXPECTED_SCHEMA_PROBE_SHA" "Frozen Chromecast 0036 native probe"
check_hash "$SCHEMA_PATCH" "$EXPECTED_SCHEMA_PATCH_SHA" "Frozen Chromecast 0036 patch"
check_hash "$WARNING_CHECKER" "$EXPECTED_WARNING_CHECKER_SHA" "Frozen Chromecast 0035 source checker"
check_hash "$WARNING_PATCH" "$EXPECTED_WARNING_PATCH_SHA" "Frozen Chromecast 0035 patch"
check_hash "$BASE_CHECKER" "$EXPECTED_BASE_CHECKER_SHA" "Frozen Chromecast 0034 source checker"
check_hash "$BASE_PROBE" "$EXPECTED_BASE_PROBE_SHA" "Frozen Chromecast 0034 native probe"
check_hash "$COMPAT" "$EXPECTED_COMPAT_SHA" "Chromecast probe compatibility header"

PYTHONDONTWRITEBYTECODE=1 python3 "$CHECKER" "$VLC_SOURCE_ROOT" "$PATCH"

VALIDATION_DIR="$(mktemp -d "$WORK_ROOT/swiftvlc-chromecast-load-transition.XXXXXX")"
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

compile_and_run() {
    local source="$1"
    local output="$2"
    "$CXX" \
        "${SDK_FLAGS[@]}" \
        -std=c++17 -Wall -Wextra -Werror \
        -include "$COMPAT" \
        -I "$VLC_SOURCE_ROOT/include" \
        -I "$VLC_SOURCE_ROOT/src" \
        -I "$CAST_DIR" \
        "$source" \
        -o "$output"
    "$output"
}

# Patch 0037 must preserve every frozen 0036 metadata and 0034 state contract
# while adding generation/token policy. Run all three native truth tables
# against the final headers. The Python checker validates 0036 production
# semantics there, but reverse-replays all seven 0037 patch files before it
# invokes frozen 0036's fail-closed mutation suite on the exact predecessor.
compile_and_run "$BASE_PROBE" "$VALIDATION_DIR/chromecast-state-0034-probe"
compile_and_run "$SCHEMA_PROBE" "$VALIDATION_DIR/chromecast-metadata-schema-0036-probe"
compile_and_run "$PROBE" "$VALIDATION_DIR/chromecast-load-transition-0037-probe"

echo "PASS Chromecast 0037 validation: checker_sha=$EXPECTED_CHECKER_SHA probe_sha=$EXPECTED_PROBE_SHA patch_sha=$EXPECTED_PATCH_SHA tmp=$WORK_ROOT"
