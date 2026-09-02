#!/usr/bin/env bash
# Hash-bound source/supersession/native proof for VLC patch 0036.

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

CHECKER="$SCRIPT_DIR/patches/validation/chromecast-metadata-schema-source-check.py"
PROBE="$SCRIPT_DIR/patches/validation/chromecast-metadata-schema-probe.cpp"
PATCH="$SCRIPT_DIR/patches/0036-chromecast-metadata-schema-correctness.patch"
FROZEN_CHECKER="$SCRIPT_DIR/patches/validation/chromecast-metadata-warning-source-check.py"
FROZEN_PATCH="$SCRIPT_DIR/patches/0035-chromecast-metadata-warning.patch"
COMPAT="$SCRIPT_DIR/patches/validation/post-pin-stability-compat.h"
CAST_DIR="$VLC_SOURCE_ROOT/modules/stream_out/chromecast"

EXPECTED_CHECKER_SHA=39fcc62fe9ac56359de49dcd22a54601e9f79d8b20b099fff117661be20ba909
EXPECTED_PROBE_SHA=d93ac662e8123d8f81ddb415a8a1e543efcd4df42caf240a1935c5792608d08f
EXPECTED_PATCH_SHA=d2e040c8db4ff529766be4bab875519e8e16242bed4bc645c4a485e422e47295
EXPECTED_FROZEN_CHECKER_SHA=155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc
EXPECTED_FROZEN_PATCH_SHA=e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d
EXPECTED_COMPAT_SHA=13c06861628085b804a245f62222388d34b841d763c4cb471952b565b0db089f

paths=(
    "$CHECKER"
    "$PROBE"
    "$PATCH"
    "$FROZEN_CHECKER"
    "$FROZEN_PATCH"
    "$COMPAT"
    "$CAST_DIR/chromecast_protocol.hpp"
    "$CAST_DIR/chromecast_communication.cpp"
)
for path in "${paths[@]}"; do
    if [[ ! -f "$path" ]]; then
        echo "Chromecast 0036 validation input not found: $path" >&2
        exit 1
    fi
done

verify_hash() {
    local description="$1"
    local path="$2"
    local expected="$3"
    local actual
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        echo "Chromecast 0036 $description hash mismatch: expected $expected, got $actual" >&2
        exit 1
    fi
}

verify_hash "source checker" "$CHECKER" "$EXPECTED_CHECKER_SHA"
verify_hash "native probe" "$PROBE" "$EXPECTED_PROBE_SHA"
verify_hash "patch" "$PATCH" "$EXPECTED_PATCH_SHA"
verify_hash "frozen 0035 checker" "$FROZEN_CHECKER" "$EXPECTED_FROZEN_CHECKER_SHA"
verify_hash "frozen 0035 patch" "$FROZEN_PATCH" "$EXPECTED_FROZEN_PATCH_SHA"
verify_hash "compatibility header" "$COMPAT" "$EXPECTED_COMPAT_SHA"

PYTHONDONTWRITEBYTECODE=1 python3 "$CHECKER" \
    "$VLC_SOURCE_ROOT" \
    "$PATCH" \
    "$FROZEN_CHECKER" \
    "$FROZEN_PATCH"

VALIDATION_DIR="$(mktemp -d "$WORK_ROOT/swiftvlc-chromecast-metadata-schema.XXXXXX")"
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
    -o "$VALIDATION_DIR/chromecast-metadata-schema-probe"

"$VALIDATION_DIR/chromecast-metadata-schema-probe"

echo "PASS Chromecast 0036 validation: checker_sha=$EXPECTED_CHECKER_SHA probe_sha=$EXPECTED_PROBE_SHA patch_sha=$EXPECTED_PATCH_SHA tmp=$WORK_ROOT"
