#!/usr/bin/env bash
# Source and bounded macOS runtime proof for VLC patch 0040.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_ROOT=""
XCFRAMEWORK=""
WORK_ROOT="${SWIFTVLC_VALIDATION_TMP_ROOT:-${SWIFTVLC_EXTERNAL_TMPDIR:-${TMPDIR:-/tmp}}}"

usage() {
    cat >&2 <<EOF
Usage: $0 --source-root <patched-vlc-source>
          [--xcframework <libvlc.xcframework>] [--work-root <temp-parent>]

Without --xcframework, validates the patch and integrated source semantics.
With --xcframework, also runs bounded explicit-stop and natural-EOF probes in
a headless macOS process where no NSApplication exists.
EOF
}

fail() {
    echo "ERROR headless vout teardown validation: $*" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-root)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            SOURCE_ROOT="$2"
            shift 2
            ;;
        --xcframework)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            XCFRAMEWORK="$2"
            shift 2
            ;;
        --work-root)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            WORK_ROOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown headless vout teardown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

[[ -n "$SOURCE_ROOT" && -d "$SOURCE_ROOT" ]] \
    || { usage; exit 2; }
SOURCE_ROOT="$(cd "$SOURCE_ROOT" && pwd -P)"
mkdir -p "$WORK_ROOT"
WORK_ROOT="$(cd "$WORK_ROOT" && pwd -P)"

PATCH="$SCRIPT_DIR/patches/0040-headless-vout-teardown-deadlock.patch"
CHECKER="$SCRIPT_DIR/patches/validation/headless-vout-teardown-source-check.py"
PROBE="$SCRIPT_DIR/patches/validation/headless-vout-teardown-probe.c"
PROVENANCE="$SCRIPT_DIR/patches/validation/0040-headless-vout-teardown-provenance.md"

EXPECTED_PATCH_SHA=a4945772122ce3d02f9a5c0c7136fa5dae940f251081238260b760b86c834681
EXPECTED_CHECKER_SHA=b1d7ad84164f9b28ac24e67c6314a55d1248bdcde4af645cdebb47e37db184d1
EXPECTED_PROBE_SHA=4315e376376fc6ccbff83b7c76de06d0b540eb8ccc1bb5914cbea6f9b5dd2fe1
EXPECTED_PROVENANCE_SHA=8f2c4eaadb2253a24a9aabdd96456b79f568456b656eb924f16120d169cbe6b2

check_hash() {
    local input_file="$1"
    local expected="$2"
    local description="$3"
    [[ -f "$input_file" ]] || fail "$description is missing: $input_file"
    local actual
    actual="$(shasum -a 256 "$input_file" | awk '{print $1}')"
    [[ "$actual" = "$expected" ]] \
        || fail "$description hash mismatch: expected $expected, got $actual"
}

check_hash "$PATCH" "$EXPECTED_PATCH_SHA" "0040 patch"
check_hash "$CHECKER" "$EXPECTED_CHECKER_SHA" "0040 source checker"
check_hash "$PROBE" "$EXPECTED_PROBE_SHA" "0040 runtime probe"
check_hash "$PROVENANCE" "$EXPECTED_PROVENANCE_SHA" "0040 provenance"

git -C "$SOURCE_ROOT" apply --reverse --check "$PATCH" \
    || fail "0040 is not cleanly and completely represented in the VLC source"

python3 -B "$CHECKER" "$SOURCE_ROOT" "$PATCH" "$PROBE"

if [[ -z "$XCFRAMEWORK" ]]; then
    echo "PASS headless vout teardown source validation: patch_sha=$EXPECTED_PATCH_SHA"
    exit 0
fi

[[ "$(uname -s)" = Darwin ]] \
    || fail "runtime validation requires macOS"
[[ -d "$XCFRAMEWORK" ]] \
    || fail "XCFramework is missing: $XCFRAMEWORK"
XCFRAMEWORK="$(cd "$XCFRAMEWORK" && pwd -P)"
ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"
FIXTURE="$REPO_ROOT/Tests/SwiftVLCTests/Fixtures/twosec.mp4"
[[ -f "$ARCHIVE" ]] || fail "macOS libVLC archive is missing: $ARCHIVE"
[[ -f "$FIXTURE" ]] || fail "H.264 fixture is missing: $FIXTURE"

RUNTIME_DIR="$(mktemp -d "$WORK_ROOT/swiftvlc-headless-vout.XXXXXX")"
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    case "$RUNTIME_DIR" in
        "$WORK_ROOT"/swiftvlc-headless-vout.*)
            rm -rf -- "$RUNTIME_DIR"
            ;;
        *)
            echo "Refusing to clean unexpected runtime path: $RUNTIME_DIR" >&2
            status=1
            ;;
    esac
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

clang -std=c11 -Wall -Wextra -Werror -o "$RUNTIME_DIR/probe" \
    "$PROBE" \
    -I "$REPO_ROOT/Sources/CLibVLC/include" "$ARCHIVE" \
    -framework AppKit -framework AudioToolbox -framework AudioUnit \
    -framework AVFoundation -framework AVKit -framework CoreAudio \
    -framework CoreFoundation -framework CoreGraphics -framework CoreImage \
    -framework CoreMedia -framework CoreServices -framework CoreText \
    -framework CoreVideo -framework Foundation -framework IOKit \
    -framework IOSurface -framework OpenGL -framework QuartzCore \
    -framework Security -framework SystemConfiguration -framework VideoToolbox \
    -lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz

"$RUNTIME_DIR/probe" "$FIXTURE" stop
"$RUNTIME_DIR/probe" "$FIXTURE" natural-eof

echo "PASS headless vout teardown runtime validation: modes=2 patch_sha=$EXPECTED_PATCH_SHA"
