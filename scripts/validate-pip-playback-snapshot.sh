#!/bin/bash
# Runtime-check patch 0022 against the exact macOS archive and vendored headers
# that the XCFramework will ship.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
XCFRAMEWORK="${1:-$REPO_ROOT/Vendor/libvlc.xcframework}"
ARCHIVE="$XCFRAMEWORK/macos-arm64_x86_64/libvlc.a"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "PiP playback-snapshot validation skipped (no macOS slice)."
  exit 0
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-pip-snapshot.XXXXXX")
trap 'rm -rf "$WORK_DIR"' EXIT

clang -o "$WORK_DIR/probe" \
  "$SCRIPT_DIR/patches/validation/pip-playback-snapshot-probe.c" \
  -I "$REPO_ROOT/Sources/CLibVLC/include" "$ARCHIVE" \
  -framework AppKit -framework AudioToolbox -framework AudioUnit \
  -framework AVFoundation -framework AVKit -framework CoreAudio \
  -framework CoreFoundation -framework CoreGraphics -framework CoreImage \
  -framework CoreMedia -framework CoreServices -framework CoreText \
  -framework CoreVideo -framework Foundation -framework IOKit \
  -framework IOSurface -framework OpenGL -framework QuartzCore \
  -framework Security -framework SystemConfiguration -framework VideoToolbox \
  -lbz2 -lc++ -liconv -lresolv -lsqlite3 -lxml2 -lz

"$WORK_DIR/probe" "$REPO_ROOT/Tests/SwiftVLCTests/Fixtures/twosec.mp4"
