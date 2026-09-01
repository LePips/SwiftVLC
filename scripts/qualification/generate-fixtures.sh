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
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required to verify qualification fixtures." >&2
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required to fetch the pinned FFmpeg bitmap-subtitle sample." >&2
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
mkdir -p \
  "$fixture_tmp/hls/soak/ts/low" \
  "$fixture_tmp/hls/soak/ts/high" \
  "$fixture_tmp/hls/soak/fmp4/low" \
  "$fixture_tmp/hls/soak/fmp4/high" \
  "$fixture_tmp/oracles" \
  "$fixture_tmp/local-playback/video" \
  "$fixture_tmp/local-playback/audio" \
  "$fixture_tmp/performance" \
  "$fixture_tmp/cadence" \
  "$fixture_tmp/subtitles"
LIVE_DURATION_SECONDS="$DURATION_SECONDS"
if [[ "$LIVE_DURATION_SECONDS" -lt 120 ]]; then
  LIVE_DURATION_SECONDS=120
fi

ffmpeg_quiet=(ffmpeg -hide_banner -loglevel error -nostdin -y)

# A deliberately grayscale moving source makes the subtitle/OSD pixels
# measurable in SpringBoard screenshots. No saturated source color can be
# mistaken for a composited overlay.
"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=700:sample_rate=48000" \
  -vf "hue=s=0,eq=contrast=0.55:brightness=-0.15,format=yuv420p" \
  -t "$LIVE_DURATION_SECONDS" -shortest \
  -c:v libx264 -preset ultrafast -crf 28 -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 96k -movflags +faststart \
  "$fixture_tmp/subtitles/base.mp4"

python3 - "$fixture_tmp/subtitles" "$LIVE_DURATION_SECONDS" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
duration = int(sys.argv[2])

def stamp(seconds: int, separator: str = ",") -> str:
    hours, remainder = divmod(seconds, 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}{separator}000"

cues = []
events = []
for index, start in enumerate(range(0, duration, 8), 1):
    end = min(duration, start + 6)
    cues.append(
        f'{index}\n{stamp(start)} --> {stamp(end)}\n'
        f'<font color="#FFFFFF">SWIFTVLC TEXT {index:02d}</font>\n'
    )
    events.append(
        f'Dialogue: 0,{stamp(start, ".")[:-1]},{stamp(end, ".")[:-1]},Matrix,,0,0,0,,'
        f'{{\\an2\\bord3\\c&H0000FFFF&}}STYLED MATRIX {index:02d}'
    )
(root / "text.srt").write_text("\n".join(cues))
(root / "forced.srt").write_text("\n".join(cue.replace("TEXT", "FORCED") for cue in cues))
(root / "styled.ass").write_text(
    "[Script Info]\nScriptType: v4.00+\nPlayResX: 640\nPlayResY: 360\n\n"
    "[V4+ Styles]\n"
    "Format: Name,Fontname,Fontsize,PrimaryColour,SecondaryColour,OutlineColour,BackColour,"
    "Bold,Italic,Underline,StrikeOut,ScaleX,ScaleY,Spacing,Angle,BorderStyle,Outline,Shadow,"
    "Alignment,MarginL,MarginR,MarginV,Encoding\n"
    "Style: Matrix,Helvetica,38,&H0000FFFF,&H000000FF,&H00000000,&H80000000,"
    "-1,0,0,0,100,100,0,0,1,3,1,2,20,20,28,1\n\n"
    "[Events]\n"
    "Format: Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect,Text\n"
    + "\n".join(events)
    + "\n"
)
PY

for subtitle_profile in text styled forced; do
  subtitle_input="$fixture_tmp/subtitles/$subtitle_profile.srt"
  subtitle_codec="srt"
  if [[ "$subtitle_profile" == "styled" ]]; then
    subtitle_input="$fixture_tmp/subtitles/styled.ass"
    subtitle_codec="ass"
  fi
  subtitle_disposition="default"
  if [[ "$subtitle_profile" == "forced" ]]; then
    subtitle_disposition="forced+default"
  fi
  "${ffmpeg_quiet[@]}" \
    -i "$fixture_tmp/subtitles/base.mp4" -i "$subtitle_input" \
    -map 0:v -map 0:a -map 1:0 -c:v copy -c:a copy -c:s "$subtitle_codec" \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="$subtitle_profile" \
    -disposition:s:0 "$subtitle_disposition" \
    "$fixture_tmp/subtitles/$subtitle_profile.mkv"
done

# FFmpeg's 77 KiB FATE sample is a filtered VideoLAN DVB-subtitle stream. Pin
# the exact bytes: an upstream change, redirect, or unavailable source fails
# fixture generation instead of silently changing release evidence.
bitmap_source="$fixture_tmp/subtitles/dvbsubtest_filter.ts"
curl -fsSL https://fate-suite.ffmpeg.org/sub/dvbsubtest_filter.ts -o "$bitmap_source"
bitmap_digest=$(shasum -a 256 "$bitmap_source" | cut -d' ' -f1)
if [[ "$bitmap_digest" != "93ad6d0be649bb29697275ff522a983d475a1e58ab070271f912b86799e04a86" ]]; then
  echo "Error: pinned FFmpeg DVB-subtitle fixture digest changed: $bitmap_digest" >&2
  exit 1
fi
"${ffmpeg_quiet[@]}" -copyts -start_at_zero -i "$bitmap_source" \
  -map 0:s:0 -c copy "$fixture_tmp/subtitles/bitmap-only.mkv"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/subtitles/base.mp4" \
  -stream_loop -1 -i "$fixture_tmp/subtitles/bitmap-only.mkv" \
  -map 0:v -map 0:a -map 1:s:0 -c copy -metadata:s:s:0 title=bitmap \
  -disposition:s:0 default -t "$LIVE_DURATION_SECONDS" \
  "$fixture_tmp/subtitles/bitmap.mkv"
"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/subtitles/bitmap.mkv" \
  -t "$LIVE_DURATION_SECONDS" -map 0:v -map 0:a -map 0:s:0 -c copy -f mpegts \
  "$fixture_tmp/subtitles/live.ts"

# A real 10-bit BT.2020/PQ source measures HDR/color impact with and without
# native PiP composition. The expensive HEVC source is encoded once, then
# remuxed into a real continuous timeline long enough for the physical phase.
"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=740:sample_rate=48000" \
  -t 6 -shortest \
  -vf "hue=s=0,eq=contrast=0.55:brightness=-0.15,format=yuv420p10le" \
  -c:v libx265 -preset ultrafast \
  -x265-params "hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
  -tag:v hvc1 -c:a aac -b:a 96k -movflags +faststart \
  "$fixture_tmp/subtitles/hdr-base.mp4"
"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/subtitles/hdr-base.mp4" \
  -i "$fixture_tmp/subtitles/text.srt" \
  -map 0:v -map 0:a -map 1:0 -c:v copy -c:a copy -c:s srt \
  -metadata:s:s:0 title=hdr-text -disposition:s:0 default \
  -t "$LIVE_DURATION_SECONDS" "$fixture_tmp/subtitles/hdr-text.mkv"
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,pix_fmt,color_space,color_transfer,color_primaries \
  -of json "$fixture_tmp/subtitles/hdr-text.mkv" \
  > "$fixture_tmp/subtitles/hdr-probe.json"
python3 - "$fixture_tmp/subtitles/hdr-probe.json" <<'PY'
import json
import sys

streams = json.load(open(sys.argv[1])).get("streams", [])
expected = {
    "codec_name": "hevc",
    "pix_fmt": "yuv420p10le",
    "color_space": "bt2020nc",
    "color_transfer": "smpte2084",
    "color_primaries": "bt2020",
}
if len(streams) != 1 or any(streams[0].get(key) != value for key, value in expected.items()):
    raise SystemExit(
        f"generated HDR subtitle fixture metadata mismatch: {streams!r} != {expected!r}"
    )
PY
rm "$fixture_tmp/subtitles/bitmap-only.mkv" \
  "$fixture_tmp/subtitles/dvbsubtest_filter.ts" \
  "$fixture_tmp/subtitles/hdr-base.mp4" \
  "$fixture_tmp/subtitles/hdr-probe.json"

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000" \
  -t "$DURATION_SECONDS" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a aac -b:a 128k -movflags +faststart \
  "$fixture_tmp/vod.mp4"

# Content-coded release oracles. The seek source has six unmistakable ten-
# second color bands plus a white marker that advances across each band. Its
# only keyframes are the band boundaries, so a precise seek several seconds
# inside a band must decode forward to the requested presentation rather than
# merely reporting the preceding keyframe timestamp. Rapid targets in different
# bands also make stale predecessor presentation visible in an XCUI screenshot.
"${ffmpeg_quiet[@]}" \
  -f lavfi -i "color=c=0xC02020:s=640x360:r=30:d=10" \
  -f lavfi -i "color=c=0x20A040:s=640x360:r=30:d=10" \
  -f lavfi -i "color=c=0x2040C0:s=640x360:r=30:d=10" \
  -f lavfi -i "color=c=0xC0A020:s=640x360:r=30:d=10" \
  -f lavfi -i "color=c=0xA020A0:s=640x360:r=30:d=10" \
  -f lavfi -i "color=c=0x20A0A0:s=640x360:r=30:d=10" \
  -f lavfi -i "sine=frequency=880:sample_rate=48000:d=60" \
  -filter_complex \
    "[0:v][1:v][2:v][3:v][4:v][5:v]concat=n=6:v=1:a=0[base];\
color=c=white:s=24x200:r=30:d=60[marker];\
[base][marker]overlay=x='40+mod(t,10)*56':y=80:eval=frame:shortest=1[v]" \
  -map '[v]' -map 6:a -t 60 \
  -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
  -g 300 -keyint_min 300 -sc_threshold 0 \
  -c:a aac -b:a 96k -movflags +faststart \
  "$fixture_tmp/oracles/seek-sparse-gop.mp4"

# Every frame in this source is independently decodable and has a unique
# full-frame RGB value derived from its zero-based index. At 10 fps, a valid
# next-frame request must advance exactly 100 ms and visibly change the entire
# video surface once. This is intentionally low-rate so device screenshots
# cannot hide accidental multi-frame advancement inside capture latency.
"${ffmpeg_quiet[@]}" \
  -f lavfi -i "nullsrc=s=640x360:r=10:d=12" \
  -f lavfi -i "sine=frequency=660:sample_rate=48000:d=12" \
  -vf \
    "format=gbrp,geq=r='32+mod(N,5)*48':g='32+mod(floor(N/5),5)*48':b='32+mod(floor(N/25),5)*48',format=yuv420p" \
  -t 12 -c:v libx264 -preset veryfast -crf 12 \
  -g 1 -keyint_min 1 -sc_threshold 0 \
  -c:a aac -b:a 96k -movflags +faststart \
  "$fixture_tmp/oracles/frame-all-intra.mp4"

# A large, content-coded progressive MP4 for physical HTTP Range seeking.
# It extends the independently decoded color/marker timeline inside one filter
# graph, resetting each branch to timestamp zero before concatenation. A white
# lower-right cycle block exists only in the second half, so 43.5 and 103.5
# seconds cannot produce interchangeable pixel evidence. This avoids the
# one-frame discontinuity that demuxer-level stream looping can introduce at the
# join. It is re-encoded at a real constant 4 Mbps with HRD filler. Combined with the
# progressive endpoint's deterministic 7,520-byte/20ms throttle, the complete
# file takes well over two minutes to transfer and therefore cannot be hidden
# in a pre-seek cache during the bounded device test. Ten-second GOPs retain
# the same 43.5-second decoded landing oracle as the sparse-GOP fixture.
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/oracles/seek-sparse-gop.mp4" \
  -filter_complex \
    '[0:v]split=2[first][second];[first]setpts=PTS-STARTPTS[first0];[second]drawbox=x=480:y=300:w=120:h=40:color=white:t=fill,setpts=PTS-STARTPTS[second0];[first0][second0]concat=n=2:v=1:a=0[out]' \
  -map '[out]' -frames:v 3600 \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -b:v 4000k -minrate 4000k -maxrate 4000k -bufsize 4000k \
  -x264-params "nal-hrd=cbr:filler=1" \
  -g 300 -keyint_min 300 -sc_threshold 0 \
  -an -movflags +faststart \
  "$fixture_tmp/oracles/progressive-range.mp4"

# Decode the encoded bytes and prove the semantic oracle. Metadata alone is
# insufficient: a syntactically valid filter expression can still render no
# marker at all, creating a self-consistent but meaningless release test.
python3 "$SCRIPT_DIR/verify-fixtures.py" --media-only "$fixture_tmp" >/dev/null

"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/vod.mp4" -t "$LIVE_DURATION_SECONDS" \
  -c copy -f mpegts "$fixture_tmp/live.ts"

"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/vod.mp4" -c copy \
  -hls_time 4 -hls_playlist_type vod \
  -hls_segment_filename "$fixture_tmp/vod-%03d.ts" \
  "$fixture_tmp/vod.m3u8"

# Two real representations and both HLS segment containers back the adaptive
# soak origin. The server builds VOD, event, and sliding-live manifests from
# these deterministic files at request time, so a long run never depends on a
# third-party CDN or an expiring public stream.
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/vod.mp4" \
  -vf "scale=320:180" -c:v libx264 -preset veryfast -pix_fmt yuv420p \
  -g 60 -keyint_min 60 -sc_threshold 0 \
  -c:a copy -movflags +faststart \
  "$fixture_tmp/low.mp4"

for variant in low high; do
  source="$fixture_tmp/vod.mp4"
  if [[ "$variant" == "low" ]]; then
    source="$fixture_tmp/low.mp4"
  fi

  "${ffmpeg_quiet[@]}" \
    -i "$source" -c copy \
    -hls_time 2 -hls_playlist_type vod \
    -hls_segment_filename "$fixture_tmp/hls/soak/ts/$variant/segment-%03d.ts" \
    "$fixture_tmp/hls/soak/ts/$variant/media.m3u8"

  (
    cd "$fixture_tmp/hls/soak/fmp4/$variant"
    "${ffmpeg_quiet[@]}" \
      -i "$source" -c copy \
      -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 \
      -hls_fmp4_init_filename init.mp4 \
      -hls_segment_filename "segment-%03d.m4s" \
      media.m3u8
  )
done

# Exact rational-rate fixtures for the cadence row. Encode one short source,
# then remux it into a real continuous timeline long enough for every physical
# phase. Labels avoid punctuation so they are safe in URLs and evidence keys.
cadence_specs=(
  "23_976|24000/1001"
  "24|24"
  "25|25"
  "29_97|30000/1001"
  "30|30"
  "50|50"
  "59_94|60000/1001"
  "60|60"
)
for cadence_spec in "${cadence_specs[@]}"; do
  IFS='|' read -r cadence_name cadence_rate <<< "$cadence_spec"
  cadence_short="$fixture_tmp/cadence/$cadence_name-short.mp4"
  "${ffmpeg_quiet[@]}" \
    -f lavfi -i "testsrc2=size=640x360:rate=$cadence_rate" \
    -t 4 -an \
    -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
    -g 120 -keyint_min 1 -sc_threshold 0 \
    -movflags +faststart \
    "$cadence_short"
  "${ffmpeg_quiet[@]}" \
    -stream_loop -1 -i "$cadence_short" \
    -f lavfi -i "sine=frequency=550:sample_rate=48000" \
    -t "$LIVE_DURATION_SECONDS" -map 0:v:0 -map 1:a:0 \
    -c:v copy -c:a aac -b:a 96k -movflags +faststart \
    "$fixture_tmp/cadence/$cadence_name.mp4"
  rm "$cadence_short"
done

# A single track with 24 fps then 60 fps presentation deltas. ffprobe reports
# two distinct timestamp steps; the generator rejects any toolchain behavior
# that accidentally normalizes this back to constant rate.
"${ffmpeg_quiet[@]}" \
  -f lavfi -t 2 -i "testsrc2=size=640x360:rate=24" \
  -f lavfi -t 2 -i "testsrc2=size=640x360:rate=60" \
  -filter_complex '[0:v][1:v]concat=n=2:v=1:a=0[v]' \
  -map '[v]' -an -fps_mode vfr \
  -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
  -movflags +faststart \
  "$fixture_tmp/cadence/vfr-short.mp4"
"${ffmpeg_quiet[@]}" \
  -stream_loop -1 -i "$fixture_tmp/cadence/vfr-short.mp4" \
  -f lavfi -i "sine=frequency=550:sample_rate=48000" \
  -t "$LIVE_DURATION_SECONDS" -map 0:v:0 -map 1:a:0 \
  -c:v copy -c:a aac -b:a 96k -movflags +faststart \
  "$fixture_tmp/cadence/vfr.mp4"
rm "$fixture_tmp/cadence/vfr-short.mp4"
ffprobe -v error -select_streams v:0 \
  -show_entries frame=best_effort_timestamp_time -of csv=p=0 \
  "$fixture_tmp/cadence/vfr.mp4" \
  | python3 -c '
import sys
values = [float(line.strip().strip(",")) for line in sys.stdin if line.strip().strip(",")]
deltas = {round(second - first, 4) for first, second in zip(values, values[1:])}
if len(deltas) < 2:
    raise SystemExit("generated VFR fixture has only one presentation delta")
'

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "sine=frequency=440:sample_rate=48000" \
  -t "$DURATION_SECONDS" -c:a aac -b:a 128k \
  "$fixture_tmp/audio.m4a"

# Candidate-bound local-file coverage. These are deliberately short enough to
# run on every supported phone/tablet while spanning containers and decoder
# families that exercise materially different demux/codec paths. The device
# downloads each file from the loopback fixture server, hashes it, persists it
# under the app container, and then proves playback came from a file:// URL.
LOCAL_PLAYBACK_DURATION_SECONDS=12
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/vod.mp4" -t "$LOCAL_PLAYBACK_DURATION_SECONDS" -c copy \
  "$fixture_tmp/local-playback/video/h264-aac.mp4"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/video/h264-aac.mp4" -c copy \
  "$fixture_tmp/local-playback/video/h264-aac.mkv"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/video/h264-aac.mp4" -c copy \
  -movflags +frag_keyframe+empty_moov+default_base_moof \
  "$fixture_tmp/local-playback/video/h264-aac-fragmented.mp4"
"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=610:sample_rate=48000" \
  -t "$LOCAL_PLAYBACK_DURATION_SECONDS" -shortest \
  -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -crf 34 -b:v 0 \
  -g 60 -c:a libopus -b:a 96k \
  "$fixture_tmp/local-playback/video/vp9-opus.webm"
"${ffmpeg_quiet[@]}" \
  -f lavfi -i "testsrc2=size=640x360:rate=30" \
  -f lavfi -i "sine=frequency=720:sample_rate=48000" \
  -t "$LOCAL_PLAYBACK_DURATION_SECONDS" -shortest \
  -c:v mpeg2video -q:v 5 -g 15 -c:a mp2 -b:a 128k -f mpegts \
  "$fixture_tmp/local-playback/video/mpeg2-mp2.ts"

"${ffmpeg_quiet[@]}" \
  -f lavfi -i "sine=frequency=523.25:sample_rate=48000" \
  -t "$LOCAL_PLAYBACK_DURATION_SECONDS" -c:a pcm_s16le \
  "$fixture_tmp/local-playback/audio/pcm-s16le.wav"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/audio/pcm-s16le.wav" -c:a aac -b:a 128k \
  "$fixture_tmp/local-playback/audio/aac.m4a"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/audio/pcm-s16le.wav" -c:a alac \
  "$fixture_tmp/local-playback/audio/alac.m4a"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/audio/pcm-s16le.wav" -c:a libmp3lame -b:a 160k \
  "$fixture_tmp/local-playback/audio/mp3.mp3"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/audio/pcm-s16le.wav" -c:a flac \
  "$fixture_tmp/local-playback/audio/flac.flac"
"${ffmpeg_quiet[@]}" \
  -i "$fixture_tmp/local-playback/audio/pcm-s16le.wav" -c:a libopus -b:a 96k \
  "$fixture_tmp/local-playback/audio/opus.ogg"

# Short, highly compressible 60 fps sources are looped by libVLC during the
# 15-minute physical rows. They exercise the real 1080p/4K decode and BGRA
# conversion geometry without checking hundreds of megabytes into the repo or
# requiring a public CDN during qualification.
for performance_profile in 1080p60 4k60; do
  performance_size="1920x1080"
  if [[ "$performance_profile" == "4k60" ]]; then
    performance_size="3840x2160"
  fi
  "${ffmpeg_quiet[@]}" \
    -f lavfi -i "testsrc2=size=$performance_size:rate=60" \
    -f lavfi -i "sine=frequency=660:sample_rate=48000" \
    -t 6 -shortest \
    -c:v libx264 -preset ultrafast -crf 30 -pix_fmt yuv420p \
    -profile:v high -level:v 5.2 -g 60 -keyint_min 60 -sc_threshold 0 \
    -c:a aac -b:a 96k -movflags +faststart \
    "$fixture_tmp/performance/$performance_profile.mp4"
  expected_probe="${performance_size/x/,},60/1"
  actual_probe=$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width,height,r_frame_rate \
    -of csv=p=0 "$fixture_tmp/performance/$performance_profile.mp4")
  if [[ "$actual_probe" != "$expected_probe" ]]; then
    echo "Error: $performance_profile fixture probe was $actual_probe, expected $expected_probe." >&2
    exit 1
  fi
done

mv "$fixture_tmp/vod.mp4" "$OUTPUT_DIR/vod.mp4"
mv "$fixture_tmp/live.ts" "$OUTPUT_DIR/live.ts"
mv "$fixture_tmp/audio.m4a" "$OUTPUT_DIR/audio.m4a"
rm -rf "$OUTPUT_DIR/performance"
mv "$fixture_tmp/performance" "$OUTPUT_DIR/performance"
rm -rf "$OUTPUT_DIR/oracles"
mv "$fixture_tmp/oracles" "$OUTPUT_DIR/oracles"
rm -rf "$OUTPUT_DIR/local-playback"
mv "$fixture_tmp/local-playback" "$OUTPUT_DIR/local-playback"
rm -rf "$OUTPUT_DIR/cadence"
mv "$fixture_tmp/cadence" "$OUTPUT_DIR/cadence"
rm -rf "$OUTPUT_DIR/subtitles"
mv "$fixture_tmp/subtitles" "$OUTPUT_DIR/subtitles"
mv "$fixture_tmp/vod.m3u8" "$OUTPUT_DIR/hls/vod.m3u8"
for segment in "$fixture_tmp"/vod-*.ts; do
  mv "$segment" "$OUTPUT_DIR/hls/$(basename "$segment")"
done
rm -rf "$OUTPUT_DIR/hls/soak"
mv "$fixture_tmp/hls/soak" "$OUTPUT_DIR/hls/soak"

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
    "performance": {
        "1080p60": {"width": 1920, "height": 1080, "framesPerSecond": 60},
        "4k60": {"width": 3840, "height": 2160, "framesPerSecond": 60},
    },
    "localPlayback": {
        "durationSeconds": 12,
        "video": [
            {
                "id": "h264-aac-mp4",
                "path": "local-playback/video/h264-aac.mp4",
                "container": "mp4",
                "videoCodec": "h264",
                "audioCodec": "aac",
                "width": 640,
                "height": 360,
                "framesPerSecond": 30,
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "h264-aac-matroska",
                "path": "local-playback/video/h264-aac.mkv",
                "container": "matroska",
                "videoCodec": "h264",
                "audioCodec": "aac",
                "width": 640,
                "height": 360,
                "framesPerSecond": 30,
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "h264-aac-fragmented-mp4",
                "path": "local-playback/video/h264-aac-fragmented.mp4",
                "container": "mp4",
                "videoCodec": "h264",
                "audioCodec": "aac",
                "width": 640,
                "height": 360,
                "framesPerSecond": 30,
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "vp9-opus-webm",
                "path": "local-playback/video/vp9-opus.webm",
                "container": "webm",
                "videoCodec": "vp9",
                "audioCodec": "opus",
                "width": 640,
                "height": 360,
                "framesPerSecond": 30,
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "mpeg2-mp2-ts",
                "path": "local-playback/video/mpeg2-mp2.ts",
                "container": "mpegts",
                "videoCodec": "mpeg2video",
                "audioCodec": "mp2",
                "width": 640,
                "height": 360,
                "framesPerSecond": 30,
                "sampleRate": 48000,
                "channels": 1,
            },
        ],
        "audio": [
            {"id": "aac-m4a", "path": "local-playback/audio/aac.m4a", "container": "mp4", "audioCodec": "aac", "sampleRate": 48000, "channels": 1},
            {"id": "alac-m4a", "path": "local-playback/audio/alac.m4a", "container": "mp4", "audioCodec": "alac", "sampleRate": 48000, "channels": 1},
            {"id": "mp3", "path": "local-playback/audio/mp3.mp3", "container": "mp3", "audioCodec": "mp3", "sampleRate": 48000, "channels": 1},
            {"id": "flac", "path": "local-playback/audio/flac.flac", "container": "flac", "audioCodec": "flac", "sampleRate": 48000, "channels": 1},
            {"id": "opus-ogg", "path": "local-playback/audio/opus.ogg", "container": "ogg", "audioCodec": "opus", "sampleRate": 48000, "channels": 1},
            {"id": "pcm-wav", "path": "local-playback/audio/pcm-s16le.wav", "container": "wav", "audioCodec": "pcm_s16le", "sampleRate": 48000, "channels": 1},
        ],
    },
    "oracles": {
        "seekSparseGOP": {
            "path": "oracles/seek-sparse-gop.mp4",
            "durationSeconds": 60,
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "keyframeTimesSeconds": [0, 10, 20, 30, 40, 50],
            "bandDurationSeconds": 10,
            "bandRGB": [
                "C02020", "20A040", "2040C0",
                "C0A020", "A020A0", "20A0A0",
            ],
            "marker": {
                "color": "FFFFFF",
                "xAtBandStart": 40,
                "horizontalPixelsPerSecond": 56,
                "width": 24,
                "y": 80,
                "height": 200,
            },
        },
        "frameAllIntra": {
            "path": "oracles/frame-all-intra.mp4",
            "durationSeconds": 12,
            "width": 640,
            "height": 360,
            "framesPerSecond": 10,
            "frameCount": 120,
            "allIntra": True,
            "rgbFormula": {
                "red": "32 + ((frameIndex mod 5) * 48)",
                "green": "32 + (((frameIndex div 5) mod 5) * 48)",
                "blue": "32 + (((frameIndex div 25) mod 5) * 48)",
            },
        },
        "progressiveHTTPRange": {
            "path": "oracles/progressive-range.mp4",
            "durationSeconds": 120,
            "minimumBytes": 50000000,
            "width": 640,
            "height": 360,
            "framesPerSecond": 30,
            "keyframeIntervalSeconds": 10,
            "seekTargetMilliseconds": 43500,
            "landingBoundaryMilliseconds": 40000,
            "seekToleranceMilliseconds": 750,
            "bandDurationSeconds": 10,
            "targetBandIndex": 4,
            "targetBandRGB": "A020A0",
            "timelineCycleIndicator": {
                "secondHalfStartSeconds": 60,
                "rgb": "FFFFFF",
                "x": 480,
                "y": 300,
                "width": 120,
                "height": 40,
            },
            "serverChunkBytes": 7520,
            "serverChunkDelayMilliseconds": 20,
        },
    },
    "cadence": {
        "rates": [23.976, 24, 25, 29.97, 30, 50, 59.94, 60],
        "vfr": True,
        "durationSeconds": live_duration,
    },
    "subtitles": {
        "profiles": ["text", "styled", "bitmap", "forced", "live", "adaptive", "hdr", "osd"],
        "bitmapSource": {
            "origin": "FFmpeg FATE filtered VideoLAN DVB subtitle sample",
            "sha256": "93ad6d0be649bb29697275ff522a983d475a1e58ab070271f912b86799e04a86",
        },
        "hdr": {
            "codec": "hevc",
            "pixelFormat": "yuv420p10le",
            "colorPrimaries": "bt2020",
            "transfer": "smpte2084",
            "colorSpace": "bt2020nc",
            "durationSeconds": live_duration,
        },
    },
    "files": files,
}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
PY

echo "Generated deterministic qualification fixtures in $OUTPUT_DIR"
