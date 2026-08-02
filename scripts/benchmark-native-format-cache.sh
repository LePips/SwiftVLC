#!/usr/bin/env bash
# Compare the pinned per-frame CoreMedia path with the patched native cache.
# Optional xctrace recordings make the allocation and CPU profiles inspectable:
#   SWIFTVLC_PROFILE_DIR=/tmp/native-cache-profiles \
#     ./scripts/benchmark-native-format-cache.sh VLC_SOURCE_ROOT

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VLC_SOURCE_ROOT="${1:?usage: benchmark-native-format-cache.sh VLC_SOURCE_ROOT}"
HEADER_DIR="${VLC_SOURCE_ROOT}/modules/video_output/apple"
HEADER="${HEADER_DIR}/VLCSampleBufferFormatDescriptionCache.h"
PROBE="${SCRIPT_DIR}/patches/validation/native-format-description-cache-benchmark.m"
SECONDS_PER_CASE="${SWIFTVLC_BENCHMARK_SECONDS:-60}"
REPETITIONS="${SWIFTVLC_BENCHMARK_REPETITIONS:-25}"
PROFILE_DIR="${SWIFTVLC_PROFILE_DIR:-}"
PROFILE_TIME_LIMIT="${SWIFTVLC_PROFILE_TIME_LIMIT:-10s}"

if [ ! -f "$HEADER" ]; then
  echo "Native format-description cache header not found: $HEADER" >&2
  exit 1
fi

BENCHMARK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-format-cache-benchmark.XXXXXX")
trap 'rm -rf "$BENCHMARK_DIR"' EXIT
BENCHMARK="$BENCHMARK_DIR/native-format-description-cache-benchmark"

xcrun --sdk macosx clang \
  -O2 \
  -fmodules \
  -Wall -Wextra -Werror \
  -I "$HEADER_DIR" \
  "$PROBE" \
  -framework CoreMedia \
  -framework CoreVideo \
  -o "$BENCHMARK"

if [ -n "$PROFILE_DIR" ]; then
  mkdir -p "$PROFILE_DIR"
fi

echo "mode,width,height,fps,seconds,repetitions,iterations,description_creations,reuses,cpu_ms,wall_ms"
for dimensions in 1280x720 1920x1080 3840x2160; do
  width=${dimensions%x*}
  height=${dimensions#*x}
  for fps in 24 30 60; do
    for mode in baseline cached; do
      "$BENCHMARK" "$mode" "$width" "$height" "$fps" \
        "$SECONDS_PER_CASE" "$REPETITIONS"

      if [ -n "$PROFILE_DIR" ]; then
        profile_name="${mode}-${dimensions}-${fps}fps"
        xcrun xctrace record --quiet --no-prompt \
          --template Allocations \
          --time-limit "$PROFILE_TIME_LIMIT" \
          --output "$PROFILE_DIR/${profile_name}-allocations.trace" \
          --launch -- "$BENCHMARK" "$mode" "$width" "$height" "$fps" \
          "$SECONDS_PER_CASE" "$REPETITIONS" >/dev/null
        xcrun xctrace record --quiet --no-prompt \
          --template "Time Profiler" \
          --time-limit "$PROFILE_TIME_LIMIT" \
          --output "$PROFILE_DIR/${profile_name}-time.trace" \
          --launch -- "$BENCHMARK" "$mode" "$width" "$height" "$fps" \
          "$SECONDS_PER_CASE" "$REPETITIONS" >/dev/null
      fi
    done
  done
done
