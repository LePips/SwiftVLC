#!/usr/bin/env bash
# Exercise same-format Core Image overlay rendering and metadata restoration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROBE="${SCRIPT_DIR}/patches/validation/native-pip-overlay-pixels.m"
VALIDATION_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-pip-overlay-pixels.XXXXXX")
trap 'rm -rf "$VALIDATION_DIR"' EXIT

xcrun --sdk macosx clang \
  -fobjc-arc \
  -fmodules \
  -Wall -Wextra -Werror \
  "$PROBE" \
  -framework CoreGraphics \
  -framework CoreImage \
  -framework CoreVideo \
  -framework Foundation \
  -o "$VALIDATION_DIR/native-pip-overlay-pixels"

"$VALIDATION_DIR/native-pip-overlay-pixels"
