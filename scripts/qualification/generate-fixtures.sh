#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUTPUT_DIR="${1:-$ROOT_DIR/.qualification-fixtures}"
DURATION_SECONDS="${SWIFTVLC_FIXTURE_DURATION_SECONDS:-60}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required to generate qualification fixtures." >&2
  exit 1
fi

case "$DURATION_SECONDS" in
  ''|*[!0-9]*)
    echo "Error: SWIFTVLC_FIXTURE_DURATION_SECONDS must be a positive integer." >&2
    exit 2
    ;;
esac
if [[ "$DURATION_SECONDS" -le 0 ]]; then
  echo "Error: SWIFTVLC_FIXTURE_DURATION_SECONDS must be positive." >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR/hls"
fixture_tmp=$(mktemp -d "${TMPDIR:-/tmp}/swiftvlc-fixtures.XXXXXX")
trap 'rm -rf "$fixture_tmp"' EXIT
LIVE_DURATION_SECONDS="$DURATION_SECONDS"
if [[ "$LIVE_DURATION_SECONDS" -lt 120 ]]; then
  LIVE_DURATION_SECONDS=120
fi

ffmpeg_quiet=(ffmpeg -hide_banner -loglevel error -nostdin -y)

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -t "$DURATION_SECONDS" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 128k -movflags +faststart \
  "$fixture_tmp/vod.mp4"

"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/vod.mp4" -t "$LIVE_DURATION_SECONDS" \
  -c copy -f mpegts "$fixture_tmp/live.ts"

"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/vod.mp4" -c copy \
  -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename "$fixture_tmp/vod-%03d.ts" \
  "$fixture_tmp/vod.m3u8"

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t "$DURATION_SECONDS" -c:a aac -b:a 128k \
  "$fixture_tmp/audio.m4a"

mv "$fixture_tmp/vod.mp4" "$OUTPUT_DIR/vod.mp4"
mv "$fixture_tmp/live.ts" "$OUTPUT_DIR/live.ts"
mv "$fixture_tmp/audio.m4a" "$OUTPUT_DIR/audio.m4a"
mv "$fixture_tmp/vod.m3u8" "$OUTPUT_DIR/hls/vod.m3u8"
for segment in "$fixture_tmp"/vod-*.ts; do
  mv "$segment" "$OUTPUT_DIR/hls/$(basename "$segment")"
done

python3 - "$OUTPUT_DIR/vod.mp4" "$OUTPUT_DIR/unsupported-codec.mp4" <<'PY'
import sys
from pathlib import Path

source, output = map(Path, sys.argv[1:])
payload = source.read_bytes()
if b"avc1" not in payload:
    raise SystemExit("generated VOD has no avc1 sample entry to invalidate")
output.write_bytes(payload.replace(b"avc1", b"zzzz"))
PY

python3 - "$OUTPUT_DIR" "$DURATION_SECONDS" "$LIVE_DURATION_SECONDS" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
duration = int(sys.argv[2])
live_duration = int(sys.argv[3])
vod = (root / "vod.mp4").read_bytes()
(root / "truncated.mp4").write_bytes(vod[: max(1, len(vod) // 3)])
(root / "malformed.bin").write_bytes(b"not-a-media-container\x00" * 256)
(root / "malformed.mp4").write_bytes(b"not-a-media-container\x00" * 256)

files = {}
for path in sorted(root.rglob("*")):
    if path.is_file() and path.name != "manifest.json":
        data = path.read_bytes()
        files[str(path.relative_to(root))] = {
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }

manifest = {
    "formatVersion": 1,
    "durationSeconds": duration,
    "liveDurationSeconds": live_duration,
    "video": {"width": 640, "height": 360, "framesPerSecond": 30},
    "files": files,
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

echo "Generated deterministic qualification fixtures in $OUTPUT_DIR"
