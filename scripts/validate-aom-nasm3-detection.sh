#!/usr/bin/env bash
# Mutation-resistant source and behavior proof for VLC patch 0039.

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

PATCH="$SCRIPT_DIR/patches/0039-aom-3.13.2-nasm-detection.patch"
CHECKER="$SCRIPT_DIR/patches/validation/aom-nasm3-detection-source-check.py"
PROBE="$SCRIPT_DIR/patches/validation/aom-nasm3-detection-probe.cmake"
PROVENANCE="$SCRIPT_DIR/patches/validation/0039-aom-3.13.2-nasm-detection-provenance.md"

EXPECTED_PATCH_SHA=f78050944caf0c291cac76e28cc4238b3e407d104446e2876c6e0213923d3581
EXPECTED_CHECKER_SHA=fd62d2f3a4fc536f167e896c516ef2a596143e8d82ef6a4bdda5d6409007dd12
EXPECTED_PROBE_SHA=f3ed2ded2df243ca5d635c6b2a30d298e2ee39a04e4a64c4aabf7a11036ccc3b
EXPECTED_PROVENANCE_SHA=322ffeaef5594aa51458177a71e85bbe0cd6de0de9a5840d067b45048d4d82c9

for input_file in "$PATCH" "$CHECKER" "$PROBE" "$PROVENANCE"; do
    if [[ ! -f "$input_file" ]]; then
        echo "libaom NASM 3 validation input not found: $input_file" >&2
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

check_hash "$PATCH" "$EXPECTED_PATCH_SHA" "libaom NASM 3 patch"
check_hash "$CHECKER" "$EXPECTED_CHECKER_SHA" "libaom NASM 3 source checker"
check_hash "$PROBE" "$EXPECTED_PROBE_SHA" "libaom NASM 3 CMake probe"
check_hash "$PROVENANCE" "$EXPECTED_PROVENANCE_SHA" "libaom NASM 3 provenance"

if ! git -C "$VLC_SOURCE_ROOT" apply --reverse --check "$PATCH"; then
    echo "0039 is not cleanly and completely represented in the VLC source tree" >&2
    exit 1
fi

python3 -B "$CHECKER" \
    "$VLC_SOURCE_ROOT" \
    "$PATCH" \
    "$PROBE" \
    --work-root "$WORK_ROOT"

echo "PASS libaom NASM 3 validation: checker_sha=$EXPECTED_CHECKER_SHA patch_sha=$EXPECTED_PATCH_SHA tmp=$WORK_ROOT"
