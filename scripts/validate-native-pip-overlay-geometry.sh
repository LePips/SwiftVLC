#!/usr/bin/env bash
# Compile and run overlay geometry cases against the exact engine helper.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:?usage: validate-native-pip-overlay-geometry.sh VLC_SOURCE_ROOT}"
HEADER_DIR="${VLC_SOURCE_ROOT}/modules/video_output/apple"
HEADER="${HEADER_DIR}/VLCSampleBufferOverlayGeometry.h"
PROBE="${SCRIPT_DIR}/patches/validation/native-pip-overlay-geometry.c"

if [ ! -f "$HEADER" ]; then
  echo "Native PiP overlay geometry header not found: $HEADER" >&2
  exit 1
fi

VALIDATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-pip-overlay.XXXXXX")
trap 'rm -rf "$VALIDATION_DIR"' EXIT

xcrun --sdk macosx clang \
  -std=c11 \
  -Wall -Wextra -Werror \
  -I "$HEADER_DIR" \
  "$PROBE" \
  -framework CoreGraphics \
  -o "$VALIDATION_DIR/native-pip-overlay-geometry"

"$VALIDATION_DIR/native-pip-overlay-geometry"
