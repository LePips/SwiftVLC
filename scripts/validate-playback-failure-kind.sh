#!/bin/bash
# Runtime-check patch 0020 against the exact macOS archive and vendored headers
# that the XCFramework will ship.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCFRAMEWORK="${1:-$REPO_ROOT/Vendor/libvlc.xcframework}"
ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "Playback failure-kind validation skipped (no macOS slice)."
  exit 0
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-failure-kind.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

printf 'not media' > "$WORK_DIR/malformed.mp4"
cp "$REPO_ROOT/Tests/SwiftVLCTests/Fixtures/test.mp4" "$WORK_DIR/unknown-codec.mp4"
perl -pi -e 's/avc1/zzzz/g' "$WORK_DIR/unknown-codec.mp4"

clang -o "$WORK_DIR/probe" \
  "$SCRIPT_DIR/patches/validation/playback-failure-kind-probe.c" \
  -I "$REPO_ROOT/Sources/CLibVLC/include" "$ARCHIVE" \
  -framework AppKit -framework AudioToolbox -framework AudioUnit \
  -framework AVFoundation -framework AVKit -framework CoreAudio \
  -framework CoreFoundation -framework CoreGraphics -framework CoreImage \
  -framework CoreMedia -framework CoreServices -framework CoreText \
  -framework CoreVideo -framework Foundation -framework IOKit \
  -framework IOSurface -framework OpenGL -framework QuartzCore \
  -framework Security -framework SystemConfiguration -framework VideoToolbox \
  -lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz

"$WORK_DIR/probe" "$WORK_DIR/malformed.mp4" "$WORK_DIR/unknown-codec.mp4"
