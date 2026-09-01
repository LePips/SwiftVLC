#!/usr/bin/env bash
# Mutation-resistant source proof for VLC patch 0038.

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

PATCH="$SCRIPT_DIR/patches/0038-apple-assembly-metadata.patch"
CHECKER="$SCRIPT_DIR/patches/validation/apple-assembly-metadata-source-check.py"
PROVENANCE="$SCRIPT_DIR/patches/validation/0038-apple-assembly-metadata-provenance.md"
APPLE_BUILD="$VLC_SOURCE_ROOT/extras/package/apple/build.sh"
NASM_WRAPPER="$VLC_SOURCE_ROOT/extras/package/apple/nasm-wrapper.sh"

EXPECTED_PATCH_SHA=402b7ca09aab50fe89391ea22b8b96113b899bce3028406a3293d574eb706beb
EXPECTED_CHECKER_SHA=86654c8d394f63a8c342ed70286d01bf7fd72c83df45af60e5b456dabfe5341a
EXPECTED_PROVENANCE_SHA=e35aa33a415871af3849036cee7e33aa22a68848bc145d627ff0e6b115cc9cfd

for input_file in \
    "$PATCH" \
    "$CHECKER" \
    "$PROVENANCE" \
    "$APPLE_BUILD" \
    "$NASM_WRAPPER"; do
    if [[ ! -f "$input_file" ]]; then
        echo "Apple assembly metadata validation input not found: $input_file" >&2
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

check_hash "$PATCH" "$EXPECTED_PATCH_SHA" "Apple assembly metadata 0038 patch"
check_hash "$CHECKER" "$EXPECTED_CHECKER_SHA" "Apple assembly metadata 0038 source checker"
check_hash "$PROVENANCE" "$EXPECTED_PROVENANCE_SHA" "Apple assembly metadata 0038 provenance"

bash -n "$APPLE_BUILD"
sh -n "$NASM_WRAPPER"

if ! git -C "$VLC_SOURCE_ROOT" apply --reverse --check "$PATCH"; then
    echo "0038 is not cleanly and completely represented in the VLC source tree" >&2
    exit 1
fi

python3 "$CHECKER" \
    "$VLC_SOURCE_ROOT" \
    "$PATCH" \
    --work-root "$WORK_ROOT"

echo "PASS Apple assembly metadata 0038 validation: checker_sha=$EXPECTED_CHECKER_SHA patch_sha=$EXPECTED_PATCH_SHA tmp=$WORK_ROOT"
