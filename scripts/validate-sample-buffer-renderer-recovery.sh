#!/bin/bash
# Validate the deterministic and public-ABI portions of the native Apple
# sample-buffer renderer recovery integration against an exact VLC source tree
# and the CLibVLC header copy shipped by this package.
# Physical presentation and app/device lifecycle behavior remain device gates.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VLC_SOURCE_ROOT="${1:-}"

if [[ -z "$VLC_SOURCE_ROOT" ]]; then
    echo "Usage: $0 <patched-vlc-source>" >&2
    exit 2
fi
if [[ ! -d "$VLC_SOURCE_ROOT" ]]; then
    echo "Renderer recovery source root not found: $VLC_SOURCE_ROOT" >&2
    exit 2
fi
VLC_SOURCE_ROOT="$(cd "$VLC_SOURCE_ROOT" && pwd)"

RECOVERY_HEADER="$VLC_SOURCE_ROOT/modules/video_output/apple/VLCSampleBufferRendererRecovery.h"
PUBLIC_HEADER="$VLC_SOURCE_ROOT/include/vlc/libvlc_media_player.h"
SHIPPED_INCLUDE="$REPO_ROOT/Sources/CLibVLC/include"
SHIPPED_PUBLIC_HEADER="$SHIPPED_INCLUDE/vlc/libvlc_media_player.h"
if [[ ! -f "$RECOVERY_HEADER" ]]; then
    echo "Renderer recovery header not found: $RECOVERY_HEADER" >&2
    exit 1
fi
if [[ ! -f "$PUBLIC_HEADER" ]] ||
   ! grep -Fq \
       'swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot' \
       "$PUBLIC_HEADER"; then
    echo "Renderer recovery public snapshot API is missing: $PUBLIC_HEADER" >&2
    exit 1
fi
if [[ ! -f "$SHIPPED_PUBLIC_HEADER" ]] ||
   ! grep -Fq \
       'swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot' \
       "$SHIPPED_PUBLIC_HEADER"; then
    echo "Shipped renderer snapshot API is missing: $SHIPPED_PUBLIC_HEADER" >&2
    exit 1
fi

if [[ "$(uname -s)" != Darwin ]] || ! command -v xcrun >/dev/null 2>&1; then
    echo "Renderer recovery host validation requires macOS and Xcode." >&2
    exit 1
fi

VALIDATION_DIR="$SCRIPT_DIR/patches/validation"
STATE_MODEL="$VALIDATION_DIR/native-sample-buffer-renderer-recovery.c"
ABI_C="$VALIDATION_DIR/sample-buffer-renderer-snapshot-abi.c"
ABI_CXX="$VALIDATION_DIR/sample-buffer-renderer-snapshot-abi.cpp"
HOST_SAMPLE="$VALIDATION_DIR/native-sample-buffer-renderer-immediate-sample.m"

verify_source() {
    local source_file="$1"
    local expected_sha="$2"
    local actual_sha

    if [[ ! -f "$source_file" ]]; then
        echo "Renderer recovery validation source missing: $source_file" >&2
        exit 1
    fi
    actual_sha=$(shasum -a 256 "$source_file" | awk '{print $1}')
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "Renderer recovery validation source hash mismatch:" >&2
        echo "  $source_file" >&2
        echo "  expected $expected_sha" >&2
        echo "  actual   $actual_sha" >&2
        exit 1
    fi
}

# These hashes identify the independently audited sources. Intentional model
# or ABI changes must update the source and this evidence pin together.
verify_source "$STATE_MODEL" \
    9f3407c433419330724fbe7af3c9802edc13a2c0f2430de7ec22d27e674db5f8
verify_source "$ABI_C" \
    47b8dd78feb77fc8676f352f3183271253ad2111baee1a8a35ca836e39b61d65
verify_source "$ABI_CXX" \
    10a838f3c44ee1d968cf39f5abfe4850144ead7cedbe8fca357d4cf276cdc661
verify_source "$HOST_SAMPLE" \
    125a20751f1accb53a4b32ffa0f2865f46215166599a584dcaa701ea8525bc9e

VALIDATION_TMP_ROOT="${TMPDIR:-/tmp}"
WORK_DIR=$(mktemp -d "$VALIDATION_TMP_ROOT/swiftvlc-renderer-recovery.XXXXXX")
trap 'rm -rf -- "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/compiler-tmp" "$WORK_DIR/module-cache"

CLANG=$(xcrun --sdk macosx --find clang)
CLANGXX=$(xcrun --sdk macosx --find clang++)
MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
export TMPDIR="$WORK_DIR/compiler-tmp"
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/module-cache"

SANITIZER_FLAGS=(
    -fno-omit-frame-pointer
    -fsanitize=address,undefined
)
SANITIZER_ENV=(
    ASAN_OPTIONS=detect_leaks=0:halt_on_error=1
    UBSAN_OPTIONS=halt_on_error=1
)

echo "Renderer recovery host validation"
echo "  VLC source: $VLC_SOURCE_ROOT"
echo "  Shipped headers: $SHIPPED_INCLUDE"
echo "  Temporary artifacts: $WORK_DIR"

echo "[1/4] Sanitized deterministic recovery state model"
"$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
    "${SANITIZER_FLAGS[@]}" -I "$VLC_SOURCE_ROOT" \
    "$STATE_MODEL" -o "$WORK_DIR/state-model"
env "${SANITIZER_ENV[@]}" "$WORK_DIR/state-model"

echo "[2/4] Public renderer snapshot ABI (C11, source + shipped)"
for include_root in "$VLC_SOURCE_ROOT/include" "$SHIPPED_INCLUDE"; do
    echo "  Headers: $include_root"
    "$CLANG" -isysroot "$MACOS_SDK" -std=c11 -Wall -Wextra -Werror \
        -fsyntax-only -I "$include_root" "$ABI_C"
done

echo "[3/4] Public renderer snapshot ABI (C++17, source + shipped)"
for include_root in "$VLC_SOURCE_ROOT/include" "$SHIPPED_INCLUDE"; do
    echo "  Headers: $include_root"
    "$CLANGXX" -isysroot "$MACOS_SDK" -std=c++17 -Wall -Wextra -Werror \
        -fsyntax-only -I "$include_root" "$ABI_CXX"
done

echo "[4/4] Sanitized host immediate-sample construction/enqueue smoke"
"$CLANG" -isysroot "$MACOS_SDK" -fobjc-arc -Wall -Wextra -Werror \
    "${SANITIZER_FLAGS[@]}" \
    -fmodules-cache-path="$WORK_DIR/module-cache" \
    "$HOST_SAMPLE" -o "$WORK_DIR/immediate-sample" \
    -framework AVFoundation -framework CoreMedia -framework CoreVideo \
    -framework Foundation -framework QuartzCore
env "${SANITIZER_ENV[@]}" "$WORK_DIR/immediate-sample"

cat <<'EOF'
HOST VALIDATION PASS: state transitions, public C/C++ ABI, sample construction,
and an immediate host enqueue/flush smoke matched the audited contracts.

DEVICE QUALIFICATION STILL REQUIRED: this host gate does not prove visible
pixels, presentation timing, background/foreground recovery, notification
reentrancy, renderer replacement/close races, seek/reset discontinuities, or
long-run backpressure on a physical Apple device. Do not treat enqueue or any
telemetry counter as a visible-pixel oracle.
EOF
