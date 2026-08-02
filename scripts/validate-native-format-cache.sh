#!/usr/bin/env bash
# Compile and execute the native PiP format-description cache regression
# against the exact helper in an already-patched VLC source checkout.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:?usage: validate-native-format-cache.sh VLC_SOURCE_ROOT}"
HEADER_DIR="${VLC_SOURCE_ROOT}/modules/video_output/apple"
HEADER="${HEADER_DIR}/VLCSampleBufferFormatDescriptionCache.h"
PROBE="${SCRIPT_DIR}/patches/validation/native-format-description-cache.m"

if [ ! -f "$HEADER" ]; then
  echo "Native format-description cache header not found: $HEADER" >&2
  exit 1
fi

VALIDATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-format-cache.XXXXXX")
trap 'rm -rf "$VALIDATION_DIR"' EXIT

xcrun --sdk macosx clang \
  -fmodules \
  -Wall -Wextra -Werror \
  -I "$HEADER_DIR" \
  "$PROBE" \
  -framework CoreMedia \
  -framework CoreVideo \
  -o "$VALIDATION_DIR/native-format-description-cache"

"$VALIDATION_DIR/native-format-description-cache"
