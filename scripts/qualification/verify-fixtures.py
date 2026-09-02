#!/usr/bin/env python3
"""Verify cached qualification media exactly matches its manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy


class FixtureVerificationError(ValueError):
    pass


EXPECTED_RELEASE_ORACLES = {
    "seekSparseGOP": {
        "path": "oracles/seek-sparse-gop.mp4",
        "durationSeconds": 60,
        "width": 640,
        "height": 360,
        "framesPerSecond": 30,
        "keyframeTimesSeconds": [0, 10, 20, 30, 40, 50],
        "bandDurationSeconds": 10,
        "bandRGB": [
            "C02020",
            "20A040",
            "2040C0",
            "C0A020",
            "A020A0",
            "20A0A0",
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
        "minimumBytes": 50_000_000,
        "width": 640,
        "height": 360,
        "framesPerSecond": 30,
        "keyframeIntervalSeconds": 10,
        "seekTargetMilliseconds": 43_500,
        "landingBoundaryMilliseconds": 40_000,
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
        "serverChunkBytes": 7_520,
        "serverChunkDelayMilliseconds": 20,
    },
}

EXPECTED_RELEASE_FIXTURE_METADATA = {
    "durationSeconds": 60,
    "liveDurationSeconds": 120,
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
            {
                "id": "aac-m4a",
                "path": "local-playback/audio/aac.m4a",
                "container": "mp4",
                "audioCodec": "aac",
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "alac-m4a",
                "path": "local-playback/audio/alac.m4a",
                "container": "mp4",
                "audioCodec": "alac",
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "mp3",
                "path": "local-playback/audio/mp3.mp3",
                "container": "mp3",
                "audioCodec": "mp3",
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "flac",
                "path": "local-playback/audio/flac.flac",
                "container": "flac",
                "audioCodec": "flac",
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "opus-ogg",
                "path": "local-playback/audio/opus.ogg",
                "container": "ogg",
                "audioCodec": "opus",
                "sampleRate": 48000,
                "channels": 1,
            },
            {
                "id": "pcm-wav",
                "path": "local-playback/audio/pcm-s16le.wav",
                "container": "wav",
                "audioCodec": "pcm_s16le",
                "sampleRate": 48000,
                "channels": 1,
            },
        ],
    },
    "cadence": {
        "rates": [23.976, 24, 25, 29.97, 30, 50, 59.94, 60],
        "vfr": True,
        "durationSeconds": 120,
    },
    "subtitles": {
        "profiles": [
            "text",
            "styled",
            "bitmap",
            "forced",
            "live",
            "adaptive",
            "hdr",
            "osd",
        ],
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
            "durationSeconds": 120,
        },
    },
}

CADENCE_FIXTURES = {
    "cadence/23_976.mp4": 24000 / 1001,
    "cadence/24.mp4": 24,
    "cadence/25.mp4": 25,
    "cadence/29_97.mp4": 30000 / 1001,
    "cadence/30.mp4": 30,
    "cadence/50.mp4": 50,
    "cadence/59_94.mp4": 60000 / 1001,
    "cadence/60.mp4": 60,
}

SUBTITLE_FIXTURES = {
    "subtitles/text.mkv": ("subrip", "eng", "text", 1, 0),
    "subtitles/styled.mkv": ("ass", "eng", "styled", 1, 0),
    "subtitles/bitmap.mkv": ("dvb_subtitle", "eng", "bitmap", 1, 0),
    "subtitles/forced.mkv": ("subrip", "eng", "forced", 1, 1),
    "subtitles/live.ts": ("dvb_subtitle", "eng", None, 0, 0),
    "subtitles/hdr-text.mkv": ("subrip", None, "hdr-text", 1, 0),
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify(root: Path) -> dict:
    root = root.resolve()
    manifest_path = root / "manifest.json"
    try:
        manifest = policy.load_json(manifest_path, "fixture manifest")
    except (OSError, policy.QualificationPolicyError) as error:
        raise FixtureVerificationError(
            f"cannot read fixture manifest: {error}"
        ) from error

    if manifest.get("formatVersion") != 1 or not isinstance(
        manifest.get("files"), dict
    ):
        raise FixtureVerificationError("unsupported or malformed fixture manifest")

    expected = set(manifest["files"])
    actual = {
        str(path.relative_to(root))
        for path in root.rglob("*")
        if path.is_file() and path != manifest_path
    }
    missing = sorted(expected - actual)
    extra = sorted(actual - expected)
    if missing or extra:
        raise FixtureVerificationError(
            f"fixture file set mismatch; missing={missing}, extra={extra}"
        )

    for relative, record in sorted(manifest["files"].items()):
        path = root / relative
        if path.is_symlink() or root not in path.resolve().parents:
            raise FixtureVerificationError(f"unsafe fixture path: {relative}")
        if not isinstance(record, dict):
            raise FixtureVerificationError(f"malformed manifest entry: {relative}")
        size = path.stat().st_size
        if record.get("bytes") != size:
            raise FixtureVerificationError(
                f"fixture size mismatch for {relative}: {size} != {record.get('bytes')}"
            )
        digest = sha256(path)
        if record.get("sha256") != digest:
            raise FixtureVerificationError(f"fixture checksum mismatch for {relative}")

    return manifest


def verify_release_oracles(manifest: dict) -> None:
    """Reject an old or weakened cache even when its self-declared hashes match."""
    if manifest.get("oracles") != EXPECTED_RELEASE_ORACLES:
        raise FixtureVerificationError(
            "release seek/frame oracle contract is missing or changed"
        )
    files = manifest.get("files", {})
    for oracle in EXPECTED_RELEASE_ORACLES.values():
        path = oracle["path"]
        if path not in files:
            raise FixtureVerificationError(
                f"release oracle is absent from fixture manifest: {path}"
            )


def verify_release_fixture_metadata(manifest: dict) -> None:
    for field, expected in EXPECTED_RELEASE_FIXTURE_METADATA.items():
        if manifest.get(field) != expected:
            raise FixtureVerificationError(
                f"release fixture metadata {field!r} is missing or changed"
            )


def _run_media_command(arguments: list[str]) -> bytes:
    try:
        result = subprocess.run(
            arguments,
            check=True,
            capture_output=True,
        )
    except FileNotFoundError as error:
        raise FixtureVerificationError(
            f"release oracle verifier requires {arguments[0]}"
        ) from error
    except subprocess.CalledProcessError as error:
        detail = error.stderr.decode("utf-8", errors="replace").strip()
        raise FixtureVerificationError(
            f"release oracle decoder failed: {detail or arguments!r}"
        ) from error
    return result.stdout


def _probe_video(path: Path) -> dict:
    payload = _run_media_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "v:0",
            "-show_entries",
            "stream=width,height,r_frame_rate,nb_frames",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(path),
        ]
    )
    try:
        return json.loads(payload)
    except json.JSONDecodeError as error:
        raise FixtureVerificationError(
            f"release oracle probe returned malformed JSON for {path}"
        ) from error


def _probe_media(path: Path) -> dict:
    payload = _run_media_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-count_packets",
            "-show_entries",
            (
                "stream=index,codec_type,codec_name,width,height,r_frame_rate,"
                "avg_frame_rate,sample_rate,channels,pix_fmt,color_space,color_transfer,color_primaries,"
                "nb_read_packets:stream_tags=language,title:"
                "stream_disposition=default,forced"
            ),
            "-show_entries",
            "format=duration,format_name",
            "-of",
            "json",
            str(path),
        ]
    )
    try:
        value = policy.loads_json(payload.decode("utf-8"), f"media probe {path}")
    except (UnicodeDecodeError, policy.QualificationPolicyError) as error:
        raise FixtureVerificationError(
            f"release fixture probe returned malformed JSON for {path}"
        ) from error
    if not isinstance(value, dict):
        raise FixtureVerificationError(
            f"release fixture probe is not an object: {path}"
        )
    return value


def _rate(value: object) -> float:
    if not isinstance(value, str) or "/" not in value:
        return 0.0
    numerator, denominator = value.split("/", 1)
    try:
        return float(numerator) / float(denominator)
    except (ValueError, ZeroDivisionError):
        return 0.0


def _duration(probe: dict) -> float:
    try:
        return float(probe["format"]["duration"])
    except (KeyError, TypeError, ValueError) as error:
        raise FixtureVerificationError("media probe has no finite duration") from error


def _stream(probe: dict, stream_type: str, path: Path) -> dict:
    values = [
        value
        for value in probe.get("streams", [])
        if isinstance(value, dict) and value.get("codec_type") == stream_type
    ]
    if len(values) != 1:
        raise FixtureVerificationError(
            f"{path} needs exactly one {stream_type} stream, found {len(values)}"
        )
    return values[0]


def _validate_stream_types(probe: dict, expected: list[str], path: Path) -> None:
    streams = probe.get("streams")
    if not isinstance(streams, list) or any(
        not isinstance(stream, dict) for stream in streams
    ):
        raise FixtureVerificationError(f"{path} has malformed stream metadata")
    actual = [stream.get("codec_type") for stream in streams]
    if any(not isinstance(kind, str) for kind in actual) or sorted(actual) != sorted(
        expected
    ):
        raise FixtureVerificationError(
            f"{path} stream contract mismatch: {actual!r} != {expected!r}"
        )


def _validate_av_contract(
    root: Path,
    relative: str,
    *,
    width: int,
    height: int,
    fps: float,
    duration: float,
    container: str,
    video_codec: str = "h264",
    audio_codec: str = "aac",
    audio: bool = True,
    tolerance_seconds: float = 0.25,
) -> dict:
    path = root / relative
    probe = _probe_media(path)
    _validate_stream_types(
        probe,
        ["video", "audio"] if audio else ["video"],
        path,
    )
    video = _stream(probe, "video", path)
    if (
        video.get("codec_name") != video_codec
        or video.get("width") != width
        or video.get("height") != height
        or abs(_rate(video.get("avg_frame_rate")) - fps) > max(0.05, fps * 0.02)
        or video.get("pix_fmt") not in {"yuv420p", "yuv420p10le"}
    ):
        raise FixtureVerificationError(f"{relative} video contract mismatch: {video!r}")
    if audio:
        audio_stream = _stream(probe, "audio", path)
        if audio_stream.get("codec_name") != audio_codec:
            raise FixtureVerificationError(
                f"{relative} audio codec is not {audio_codec}: {audio_stream!r}"
            )
    format_name = str(probe.get("format", {}).get("format_name", ""))
    if container not in format_name:
        raise FixtureVerificationError(
            f"{relative} container contract mismatch: {format_name!r}"
        )
    if abs(_duration(probe) - duration) > tolerance_seconds:
        raise FixtureVerificationError(
            f"{relative} duration contract mismatch: {_duration(probe):.6f}"
        )
    _decode_fixture(path, audio=audio)
    return probe


def _decode_fixture(path: Path, *, audio: bool) -> None:
    command = [
        "ffmpeg",
        "-v",
        "error",
        "-nostdin",
        "-ss",
        "1",
        "-i",
        str(path),
        "-map",
        "0:v:0",
        "-frames:v",
        "1",
    ]
    if audio:
        command += ["-map", "0:a:0", "-frames:a", "1"]
    command += ["-f", "null", "-"]
    _run_media_command(command)


def _validate_local_video_motion(path: Path) -> None:
    payload = _run_media_command(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-ss",
            "1",
            "-i",
            str(path),
            "-map",
            "0:v:0",
            "-vf",
            "fps=1",
            "-frames:v",
            "3",
            "-f",
            "framemd5",
            "-",
        ]
    ).decode("utf-8", errors="strict")
    hashes = [
        line.rsplit(",", 1)[-1].strip()
        for line in payload.splitlines()
        if line and not line.startswith("#")
    ]
    if len(hashes) != 3 or len(set(hashes)) != 3:
        raise FixtureVerificationError(
            f"local video fixture has no three-frame motion oracle: {path}"
        )


def _validate_local_audio_signal(path: Path) -> None:
    pcm = _run_media_command(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-ss",
            "1",
            "-i",
            str(path),
            "-map",
            "0:a:0",
            "-t",
            "1",
            "-f",
            "s16le",
            "-acodec",
            "pcm_s16le",
            "-",
        ]
    )
    if len(pcm) < 48_000 or not any(pcm):
        raise FixtureVerificationError(
            f"local audio fixture has no decoded non-silent signal: {path}"
        )


def _frame_timestamps(
    path: Path, *, read_duration_seconds: int | None = 12
) -> list[float]:
    command = [
        "ffprobe",
        "-v",
        "error",
    ]
    if read_duration_seconds is not None:
        command += ["-read_intervals", f"0%+{read_duration_seconds}"]
    command += [
        "-select_streams",
        "v:0",
        "-show_entries",
        "frame=best_effort_timestamp_time",
        "-of",
        "csv=p=0",
        str(path),
    ]
    payload = _run_media_command(command).decode("utf-8", errors="strict")
    try:
        return [float(line.split(",", 1)[0]) for line in payload.splitlines() if line]
    except ValueError as error:
        raise FixtureVerificationError(
            f"malformed frame timestamps for {path}"
        ) from error


def _frame_intervals(path: Path) -> list[float]:
    timestamps = _frame_timestamps(path)
    return [round(right - left, 6) for left, right in zip(timestamps, timestamps[1:])]


def _validate_cfr_intervals(
    relative: str, expected_rate: float, intervals: list[float]
) -> None:
    expected_interval = 1 / expected_rate
    if not intervals or any(
        abs(interval - expected_interval) > 0.000002 for interval in intervals
    ):
        raise FixtureVerificationError(
            f"{relative} contains non-CFR presentation intervals"
        )


def _validate_vfr_intervals(intervals: list[float]) -> None:
    short_interval = 1 / 60
    long_interval = 1 / 24
    short_count = sum(
        abs(interval - short_interval) <= 0.000002 for interval in intervals
    )
    long_count = sum(
        abs(interval - long_interval) <= 0.000002 for interval in intervals
    )
    if (
        short_count < 100
        or long_count < 40
        or short_count + long_count != len(intervals)
    ):
        raise FixtureVerificationError(
            "cadence/vfr.mp4 is not a continuous 24/60 fps variable-rate timeline"
        )


def _validate_vfr_timeline(timestamps: list[float]) -> None:
    """Prove the canonical absolute 2s@24/2s@60 repeated timeline contract."""

    tolerance_seconds = 0.000002
    cycle_seconds = 4.0
    transition_seconds = 2.0
    if not timestamps or abs(timestamps[0]) > tolerance_seconds:
        raise FixtureVerificationError(
            "cadence/vfr.mp4 must begin at absolute presentation timestamp zero"
        )
    if len(timestamps) < (48 + 120) * 3:
        raise FixtureVerificationError(
            "cadence/vfr.mp4 does not contain three complete 24/60 cadence cycles"
        )

    for left, right in zip(timestamps, timestamps[1:]):
        delta = right - left
        phase = math.fmod(left, cycle_seconds)
        if phase < 0:
            phase += cycle_seconds
        if min(abs(phase), abs(phase - cycle_seconds)) <= tolerance_seconds:
            phase = 0.0
        elif abs(phase - transition_seconds) <= tolerance_seconds:
            phase = transition_seconds
        expected_delta = 1 / (24 if phase < transition_seconds else 60)
        if delta <= 0 or abs(delta - expected_delta) > tolerance_seconds:
            raise FixtureVerificationError(
                "cadence/vfr.mp4 does not follow the absolute repeated "
                "2s@24 then 2s@60 presentation timeline"
            )


def _verify_playlist(path: Path, *, fmp4: bool, segment_count: int) -> None:
    try:
        text = path.read_text()
    except OSError as error:
        raise FixtureVerificationError(
            f"cannot read playlist {path}: {error}"
        ) from error
    if not text.startswith("#EXTM3U\n") or "#EXT-X-ENDLIST" not in text:
        raise FixtureVerificationError(
            f"playlist is not a finite canonical HLS list: {path}"
        )
    media_lines = [
        line.strip()
        for line in text.splitlines()
        if line.strip() and not line.startswith("#")
    ]
    suffix = ".m4s" if fmp4 else ".ts"
    if len(media_lines) != segment_count or any(
        not line.endswith(suffix) for line in media_lines
    ):
        raise FixtureVerificationError(f"playlist segment contract mismatch: {path}")
    has_map = "#EXT-X-MAP:" in text
    if has_map != fmp4:
        raise FixtureVerificationError(f"playlist init-map contract mismatch: {path}")


def verify_release_fixture_media(root: Path) -> dict:
    """Probe and decode every media class used for a release-significant row."""

    root = root.resolve()
    observations: dict[str, object] = {}
    observations["vod"] = _validate_av_contract(
        root,
        "vod.mp4",
        width=640,
        height=360,
        fps=30,
        duration=60,
        container="mov",
    )
    observations["live"] = _validate_av_contract(
        root,
        "live.ts",
        width=640,
        height=360,
        fps=30,
        duration=120.042689,
        container="mpegts",
    )

    audio_probe = _probe_media(root / "audio.m4a")
    _validate_stream_types(audio_probe, ["audio"], root / "audio.m4a")
    if _stream(audio_probe, "audio", root / "audio.m4a").get("codec_name") != "aac":
        raise FixtureVerificationError("audio.m4a is not AAC")
    if abs(_duration(audio_probe) - 60) > 0.01:
        raise FixtureVerificationError("audio.m4a duration is not 60 seconds")
    _run_media_command(
        [
            "ffmpeg",
            "-v",
            "error",
            "-nostdin",
            "-ss",
            "1",
            "-i",
            str(root / "audio.m4a"),
            "-map",
            "0:a:0",
            "-frames:a",
            "1",
            "-f",
            "null",
            "-",
        ]
    )
    observations["audio"] = audio_probe

    local_contract = EXPECTED_RELEASE_FIXTURE_METADATA["localPlayback"]
    local_video = {}
    for fixture in local_contract["video"]:
        relative = fixture["path"]
        path = root / relative
        local_video[fixture["id"]] = _validate_av_contract(
            root,
            relative,
            width=fixture["width"],
            height=fixture["height"],
            fps=fixture["framesPerSecond"],
            duration=local_contract["durationSeconds"],
            container=fixture["container"],
            video_codec=fixture["videoCodec"],
            audio_codec=fixture["audioCodec"],
            tolerance_seconds=0.30,
        )
        audio_stream = _stream(local_video[fixture["id"]], "audio", path)
        if (
            int(str(audio_stream.get("sample_rate", "0"))) != fixture["sampleRate"]
            or audio_stream.get("channels") != fixture["channels"]
        ):
            raise FixtureVerificationError(
                f"{relative} local video audio contract mismatch: {audio_stream!r}"
            )
        _validate_local_video_motion(path)
        if fixture["id"] == "h264-aac-fragmented-mp4":
            payload = path.read_bytes()
            if b"moof" not in payload or b"mvex" not in payload:
                raise FixtureVerificationError(
                    f"{relative} is not a fragmented MP4 byte stream"
                )

    local_audio = {}
    for fixture in local_contract["audio"]:
        relative = fixture["path"]
        path = root / relative
        probe = _probe_media(path)
        _validate_stream_types(probe, ["audio"], path)
        stream = _stream(probe, "audio", path)
        format_name = str(probe.get("format", {}).get("format_name", ""))
        if (
            stream.get("codec_name") != fixture["audioCodec"]
            or int(str(stream.get("sample_rate", "0"))) != fixture["sampleRate"]
            or stream.get("channels") != fixture["channels"]
            or fixture["container"] not in format_name
            or abs(_duration(probe) - local_contract["durationSeconds"]) > 0.30
        ):
            raise FixtureVerificationError(
                f"{relative} local audio contract mismatch: {probe!r}"
            )
        _validate_local_audio_signal(path)
        local_audio[fixture["id"]] = probe
    observations["localPlayback"] = {
        "video": local_video,
        "audio": local_audio,
    }

    for name, width, height in (("1080p60", 1920, 1080), ("4k60", 3840, 2160)):
        observations[f"performance/{name}"] = _validate_av_contract(
            root,
            f"performance/{name}.mp4",
            width=width,
            height=height,
            fps=60,
            duration=6,
            container="mov",
            tolerance_seconds=0.01,
        )

    cadence = {}
    for relative, expected_rate in CADENCE_FIXTURES.items():
        cadence[relative] = _validate_av_contract(
            root,
            relative,
            width=640,
            height=360,
            fps=expected_rate,
            duration=120,
            container="mov",
        )
        _validate_cfr_intervals(
            relative,
            expected_rate,
            _frame_intervals(root / relative),
        )
    vfr_probe = _validate_av_contract(
        root,
        "cadence/vfr.mp4",
        width=640,
        height=360,
        fps=42,
        duration=120,
        container="mov",
    )
    vfr_timestamps = _frame_timestamps(
        root / "cadence/vfr.mp4", read_duration_seconds=None
    )
    intervals = [
        round(right - left, 6)
        for left, right in zip(vfr_timestamps, vfr_timestamps[1:])
    ]
    _validate_vfr_intervals(intervals)
    _validate_vfr_timeline(vfr_timestamps)
    cadence["cadence/vfr.mp4"] = vfr_probe
    observations["cadence"] = cadence

    subtitle_observations = {}
    for relative, subtitle_contract in SUBTITLE_FIXTURES.items():
        subtitle_codec, language, title, default, forced = subtitle_contract
        path = root / relative
        probe = _probe_media(path)
        _validate_stream_types(probe, ["video", "audio", "subtitle"], path)
        video = _stream(probe, "video", path)
        audio = _stream(probe, "audio", path)
        subtitle = _stream(probe, "subtitle", path)
        tags = subtitle.get("tags", {})
        disposition = subtitle.get("disposition", {})
        if (
            video.get("width") != 640
            or video.get("height") != 360
            or audio.get("codec_name") != "aac"
            or subtitle.get("codec_name") != subtitle_codec
            or not isinstance(tags, dict)
            or tags.get("language") != language
            or tags.get("title") != title
            or not isinstance(disposition, dict)
            or disposition.get("default", 0) != default
            or disposition.get("forced", 0) != forced
            or int(str(subtitle.get("nb_read_packets", "0"))) <= 0
            or abs(_duration(probe) - 120) > 0.25
        ):
            raise FixtureVerificationError(
                f"{relative} subtitle contract mismatch: {probe!r}"
            )
        _decode_fixture(path, audio=True)
        subtitle_observations[relative] = probe
    hdr_video = _stream(
        subtitle_observations["subtitles/hdr-text.mkv"],
        "video",
        root / "subtitles/hdr-text.mkv",
    )
    if {
        "codec_name": hdr_video.get("codec_name"),
        "pix_fmt": hdr_video.get("pix_fmt"),
        "color_primaries": hdr_video.get("color_primaries"),
        "color_transfer": hdr_video.get("color_transfer"),
        "color_space": hdr_video.get("color_space"),
    } != {
        "codec_name": "hevc",
        "pix_fmt": "yuv420p10le",
        "color_primaries": "bt2020",
        "color_transfer": "smpte2084",
        "color_space": "bt2020nc",
    }:
        raise FixtureVerificationError("HDR subtitle fixture lost its HDR signal")
    observations["subtitles"] = subtitle_observations

    hls_contracts = (
        ("hls/vod.m3u8", False, 15, 640, 360),
        ("hls/soak/ts/low/media.m3u8", False, 30, 320, 180),
        ("hls/soak/ts/high/media.m3u8", False, 30, 640, 360),
        ("hls/soak/fmp4/low/media.m3u8", True, 30, 320, 180),
        ("hls/soak/fmp4/high/media.m3u8", True, 30, 640, 360),
    )
    hls_observations = {}
    for relative, fmp4, segment_count, width, height in hls_contracts:
        _verify_playlist(root / relative, fmp4=fmp4, segment_count=segment_count)
        hls_observations[relative] = _validate_av_contract(
            root,
            relative,
            width=width,
            height=height,
            fps=30,
            duration=60,
            container="hls",
            tolerance_seconds=0.01,
        )
    observations["hls"] = hls_observations
    return observations


def _keyframe_times(path: Path) -> list[float]:
    payload = _run_media_command(
        [
            "ffprobe",
            "-v",
            "error",
            "-skip_frame",
            "nokey",
            "-select_streams",
            "v:0",
            "-show_entries",
            "frame=best_effort_timestamp_time",
            "-of",
            "csv=p=0",
            str(path),
        ]
    ).decode("utf-8", errors="strict")
    try:
        return [
            float(line.split(",", maxsplit=1)[0])
            for line in payload.splitlines()
            if line
        ]
    except ValueError as error:
        raise FixtureVerificationError(
            f"release oracle keyframe probe was malformed for {path}"
        ) from error


def _decode_rgb_frame(
    path: Path, *, seconds: float | None = None, index: int | None = None
) -> bytes:
    if (seconds is None) == (index is None):
        raise ValueError("select exactly one frame timestamp or index")
    arguments = ["ffmpeg", "-v", "error", "-nostdin"]
    if seconds is not None:
        arguments += ["-ss", f"{seconds:.6f}"]
    arguments += ["-i", str(path), "-map", "0:v:0"]
    if index is not None:
        arguments += ["-vf", f"select=eq(n\\,{index})"]
    arguments += [
        "-frames:v",
        "1",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "pipe:1",
    ]
    frame = _run_media_command(arguments)
    expected_bytes = 640 * 360 * 3
    if len(frame) != expected_bytes:
        selector = f"time {seconds}" if seconds is not None else f"index {index}"
        raise FixtureVerificationError(
            f"release oracle decoded {len(frame)} bytes at {selector}; expected {expected_bytes}"
        )
    return frame


def _rgb(frame: bytes, x: int, y: int) -> tuple[float, float, float]:
    offset = (y * 640 + x) * 3
    return frame[offset], frame[offset + 1], frame[offset + 2]


def _mean_rgb(
    frame: bytes,
    x_range: range,
    y_range: range,
    *,
    stride: int = 4,
) -> tuple[float, float, float]:
    red = green = blue = 0.0
    count = 0
    for y in y_range[::stride]:
        for x in x_range[::stride]:
            sample = _rgb(frame, x, y)
            red += sample[0]
            green += sample[1]
            blue += sample[2]
            count += 1
    return red / count, green / count, blue / count


def _rgb_distance(
    first: tuple[float, float, float],
    second: tuple[float, float, float],
) -> float:
    return math.sqrt(sum((left - right) ** 2 for left, right in zip(first, second)))


def _seek_pixel_observation(frame: bytes) -> tuple[int, int, float, float]:
    colors = [
        (0xC0, 0x20, 0x20),
        (0x20, 0xA0, 0x40),
        (0x20, 0x40, 0xC0),
        (0xC0, 0xA0, 0x20),
        (0xA0, 0x20, 0xA0),
        (0x20, 0xA0, 0xA0),
    ]
    background = _mean_rgb(frame, range(32, 608), range(18, 65))
    matches = sorted(
        (_rgb_distance(background, color), index) for index, color in enumerate(colors)
    )
    color_distance, band = matches[0]
    if color_distance > 35:
        raise FixtureVerificationError(
            f"seek oracle background is not a declared band: {background!r}"
        )

    column_scores = []
    for x in range(640):
        scores = [
            _rgb_distance(_rgb(frame, x, y), background) for y in range(100, 260, 4)
        ]
        column_scores.append(sum(scores) / len(scores))
    marker_width = 24
    window_score = sum(column_scores[:marker_width])
    best_start = 0
    best_score = window_score
    for start in range(1, len(column_scores) - marker_width + 1):
        window_score += column_scores[start + marker_width - 1]
        window_score -= column_scores[start - 1]
        if window_score > best_score:
            best_start = start
            best_score = window_score
    marker_contrast = best_score / marker_width
    if marker_contrast < 100:
        raise FixtureVerificationError(
            f"seek oracle moving marker is absent or indistinguishable: {marker_contrast:.2f}"
        )
    return band, best_start, color_distance, marker_contrast


def _progressive_cycle_index(frame: bytes) -> int:
    background = _mean_rgb(frame, range(32, 608), range(18, 65))
    indicator = _mean_rgb(frame, range(500, 580), range(310, 330))
    white_distance = _rgb_distance(indicator, (255, 255, 255))
    background_distance = _rgb_distance(indicator, background)
    if white_distance <= 60 and background_distance > 80:
        return 1
    if background_distance <= 35 and white_distance > 80:
        return 0
    raise FixtureVerificationError(
        "progressive Range oracle has an ambiguous timeline cycle indicator: "
        f"background={background!r}, indicator={indicator!r}"
    )


def _frame_color(index: int) -> tuple[float, float, float]:
    return (
        32 + (index % 5) * 48,
        32 + ((index // 5) % 5) * 48,
        32 + ((index // 25) % 5) * 48,
    )


def _all_intra_pixel_observation(frame: bytes) -> tuple[int, float, float]:
    observed = _mean_rgb(frame, range(64, 576), range(29, 72))
    matches = sorted(
        (_rgb_distance(observed, _frame_color(index)), index) for index in range(120)
    )
    distance, index = matches[0]
    margin = matches[1][0] - distance
    if distance > 60 or margin < 8:
        raise FixtureVerificationError(
            f"all-intra oracle frame color is invalid or ambiguous: {observed!r}"
        )
    return index, distance, margin


def verify_release_oracle_media(root: Path) -> dict:
    """Decode the media so a truthful manifest cannot bless meaningless bytes."""
    root = root.resolve()
    seek_path = root / EXPECTED_RELEASE_ORACLES["seekSparseGOP"]["path"]
    frame_path = root / EXPECTED_RELEASE_ORACLES["frameAllIntra"]["path"]
    progressive_contract = EXPECTED_RELEASE_ORACLES["progressiveHTTPRange"]
    progressive_path = root / progressive_contract["path"]
    if (
        not seek_path.is_file()
        or not frame_path.is_file()
        or not progressive_path.is_file()
    ):
        raise FixtureVerificationError("release seek/frame oracle media is missing")

    seek_probe = _probe_video(seek_path)
    seek_streams = seek_probe.get("streams", [])
    seek_keyframes = _keyframe_times(seek_path)
    if len(seek_streams) != 1:
        raise FixtureVerificationError(
            "seek oracle does not have exactly one video stream"
        )
    seek_stream = seek_streams[0]
    if (
        seek_stream.get("width") != 640
        or seek_stream.get("height") != 360
        or seek_stream.get("r_frame_rate") != "30/1"
        or seek_stream.get("nb_frames") != "1800"
        or abs(float(seek_probe.get("format", {}).get("duration", 0)) - 60.0) > 0.001
        or len(seek_keyframes) != 6
        or any(
            abs(actual - expected) > 0.0001
            for actual, expected in zip(seek_keyframes, [0, 10, 20, 30, 40, 50])
        )
    ):
        raise FixtureVerificationError(
            f"encoded seek oracle metadata/GOP contract mismatch: {seek_probe!r}, "
            f"keyframes={seek_keyframes!r}"
        )

    seek_samples = []
    for band in range(6):
        marker_positions = []
        for seconds_into_band in (1.0, 8.0):
            observation = _seek_pixel_observation(
                _decode_rgb_frame(
                    seek_path,
                    seconds=band * 10 + seconds_into_band,
                )
            )
            observed_band, marker_x, color_distance, marker_contrast = observation
            expected_x = int(40 + seconds_into_band * 56)
            if observed_band != band or abs(marker_x - expected_x) > 4:
                raise FixtureVerificationError(
                    "encoded seek oracle semantic mismatch: "
                    f"band={band}, time={seconds_into_band}, observedBand={observed_band}, "
                    f"markerX={marker_x}, expectedX={expected_x}"
                )
            marker_positions.append(marker_x)
            seek_samples.append(
                {
                    "band": band,
                    "secondsIntoBand": seconds_into_band,
                    "markerX": marker_x,
                    "colorDistance": color_distance,
                    "markerContrast": marker_contrast,
                }
            )
        if marker_positions[1] - marker_positions[0] < 380:
            raise FixtureVerificationError(
                f"seek oracle marker did not move across band {band}: {marker_positions!r}"
            )

    progressive_probe = _probe_video(progressive_path)
    progressive_streams = progressive_probe.get("streams", [])
    progressive_keyframes = _keyframe_times(progressive_path)
    expected_progressive_keyframes = list(range(0, 120, 10))
    if len(progressive_streams) != 1:
        raise FixtureVerificationError(
            "progressive Range oracle does not have exactly one video stream"
        )
    progressive_stream = progressive_streams[0]
    if (
        progressive_path.stat().st_size < progressive_contract["minimumBytes"]
        or progressive_stream.get("width") != 640
        or progressive_stream.get("height") != 360
        or progressive_stream.get("r_frame_rate") != "30/1"
        or progressive_stream.get("nb_frames") != "3600"
        or abs(float(progressive_probe.get("format", {}).get("duration", 0)) - 120.0)
        > 0.001
        or len(progressive_keyframes) != len(expected_progressive_keyframes)
        or any(
            abs(actual - expected) > 0.0001
            for actual, expected in zip(
                progressive_keyframes, expected_progressive_keyframes
            )
        )
    ):
        raise FixtureVerificationError(
            "encoded progressive Range oracle size/metadata/GOP contract mismatch: "
            f"size={progressive_path.stat().st_size}, probe={progressive_probe!r}, "
            f"keyframes={progressive_keyframes!r}"
        )
    progressive_samples = []
    for seconds in (43.5, 103.5):
        frame = _decode_rgb_frame(progressive_path, seconds=seconds)
        band, marker_x, color_distance, marker_contrast = _seek_pixel_observation(frame)
        cycle = _progressive_cycle_index(frame)
        expected_marker_x = int(40 + 3.5 * 56)
        expected_cycle = int(seconds // 60)
        if (
            band != 4
            or cycle != expected_cycle
            or abs(marker_x - expected_marker_x) > 4
        ):
            raise FixtureVerificationError(
                "progressive Range decoded landing oracle changed: "
                f"seconds={seconds}, cycle={cycle}, band={band}, markerX={marker_x}"
            )
        progressive_samples.append(
            {
                "seconds": seconds,
                "cycle": cycle,
                "band": band,
                "markerX": marker_x,
                "colorDistance": color_distance,
                "markerContrast": marker_contrast,
            }
        )

    frame_probe = _probe_video(frame_path)
    frame_streams = frame_probe.get("streams", [])
    frame_keyframes = _keyframe_times(frame_path)
    if len(frame_streams) != 1:
        raise FixtureVerificationError(
            "frame oracle does not have exactly one video stream"
        )
    frame_stream = frame_streams[0]
    if (
        frame_stream.get("width") != 640
        or frame_stream.get("height") != 360
        or frame_stream.get("r_frame_rate") != "10/1"
        or frame_stream.get("nb_frames") != "120"
        or abs(float(frame_probe.get("format", {}).get("duration", 0)) - 12.0) > 0.001
        or len(frame_keyframes) != 120
        or any(
            abs(actual - index / 10) > 0.0001
            for index, actual in enumerate(frame_keyframes)
        )
    ):
        raise FixtureVerificationError(
            f"encoded frame oracle metadata/all-intra contract mismatch: {frame_probe!r}"
        )

    frame_samples = []
    for expected_index in (0, 1, 4, 5, 42, 73, 119):
        observed_index, distance, margin = _all_intra_pixel_observation(
            _decode_rgb_frame(frame_path, index=expected_index)
        )
        if observed_index != expected_index:
            raise FixtureVerificationError(
                f"encoded all-intra frame {expected_index} decoded as {observed_index}"
            )
        frame_samples.append(
            {
                "frameIndex": expected_index,
                "colorDistance": distance,
                "nearestCodeMargin": margin,
            }
        )
    return {
        "seekSamples": seek_samples,
        "progressiveSamples": progressive_samples,
        "frameSamples": frame_samples,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument(
        "--media-only",
        action="store_true",
        help="decode and verify only the release seek/frame oracle media",
    )
    args = parser.parse_args()
    try:
        if args.media_only:
            report = verify_release_oracle_media(args.root)
        else:
            manifest = verify(args.root)
            verify_release_fixture_metadata(manifest)
            verify_release_oracles(manifest)
            verify_release_fixture_media(args.root)
            verify_release_oracle_media(args.root)
            report = manifest
    except FixtureVerificationError as error:
        parser.error(str(error))
    print(json.dumps(report, sort_keys=True))


if __name__ == "__main__":
    main()
