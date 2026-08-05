#!/usr/bin/env python3
"""Bind the full clock JSONL and Audio System Trace to timebase evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import subprocess
import sys
from pathlib import Path


class TimebaseEvidenceError(ValueError):
    pass


SHA256 = re.compile(r"[0-9a-f]{64}")
SCENARIOS = {"timebase-vod-soak", "timebase-live-soak"}


def trace_record(
    trace: Path,
    toc: Path,
    digest_script: Path,
    artifact_directory: Path,
    evidence_directory: Path,
) -> dict:
    if not trace.is_dir() or not any(trace.rglob("*")):
        raise TimebaseEvidenceError("Audio System Trace is missing or empty")
    text = toc.read_text(errors="replace")
    if "audio" not in text.lower():
        raise TimebaseEvidenceError("Audio System Trace TOC has no audio tables")
    staged_trace = artifact_directory / trace.name
    staged_toc = artifact_directory / toc.name
    try:
        shutil.copytree(trace, staged_trace)
        shutil.copy2(toc, staged_toc)
    except OSError as error:
        raise TimebaseEvidenceError(
            f"cannot retain Audio System Trace artifacts: {error}"
        ) from error
    result = subprocess.run(
        [sys.executable, str(digest_script), str(staged_trace)],
        check=False,
        capture_output=True,
        text=True,
    )
    digest = result.stdout.strip()
    if result.returncode != 0 or not SHA256.fullmatch(digest):
        raise TimebaseEvidenceError("could not digest Audio System Trace")
    return {
        "status": "captured",
        "template": "Audio System Trace",
        "format": "com.apple.instruments.trace",
        "runArtifact": staged_trace.relative_to(evidence_directory).as_posix(),
        "tableOfContents": staged_toc.relative_to(evidence_directory).as_posix(),
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "treeDigest": digest,
        "targetProcess": "iOS",
    }


def raw_record(root: Path, reference: dict, duration: int) -> dict:
    name = reference.get("fileName")
    if not isinstance(name, str) or Path(name).name != name:
        raise TimebaseEvidenceError("raw capture reference is unsafe")
    matches = [path for path in root.rglob(name) if path.is_file()]
    if len(matches) != 1:
        raise TimebaseEvidenceError(f"expected one raw capture named {name}")
    path = matches[0]
    samples = 0
    correction_sequences: list[int] = []
    elapsed_seconds: list[int] = []
    maximum_drift = 0.0
    drift_samples = 0
    maximum_correction = 0.0
    observed_rates: set[float] = set()
    monotonicity_violations = 0
    previous_presented: dict[int, float] = {}
    decoded_media_samples = 0
    first_played_buffers: int | None = None
    last_played_buffers: int | None = None
    for number, line in enumerate(path.read_text(errors="strict").splitlines(), 1):
        try:
            value = json.loads(line)
        except json.JSONDecodeError as error:
            raise TimebaseEvidenceError(f"invalid raw JSONL line {number}") from error
        if value.get("kind") == "sample":
            if not all(isinstance(value.get(key), dict) for key in ("clock", "audio", "frame")):
                raise TimebaseEvidenceError(f"incomplete raw sample line {number}")
            clock, audio, frame = value["clock"], value["audio"], value["frame"]
            drift = clock.get("driftSeconds")
            rate = clock.get("requestedRate")
            elapsed = clock.get("elapsedSeconds")
            generation = frame.get("playbackGeneration")
            presented = frame.get("presentedSeconds")
            played = audio.get("playedBuffers")
            decoded_media = frame.get("decodedFrameMediaTimeSeconds")
            if type(drift) in (int, float) and math.isfinite(float(drift)):
                maximum_drift = max(maximum_drift, abs(float(drift)))
                drift_samples += 1
            if type(elapsed) is not int:
                raise TimebaseEvidenceError(
                    f"raw sample line {number} has no integer elapsedSeconds"
                )
            elapsed_seconds.append(elapsed)
            if type(rate) in (int, float) and math.isfinite(float(rate)):
                observed_rates.add(float(rate))
            if isinstance(generation, int) and isinstance(presented, (int, float)):
                previous = previous_presented.get(generation)
                if previous is not None and float(presented) + 0.001 < previous:
                    monotonicity_violations += 1
                previous_presented[generation] = float(presented)
            if isinstance(played, int):
                first_played_buffers = played if first_played_buffers is None else first_played_buffers
                last_played_buffers = played
            if isinstance(decoded_media, (int, float)):
                decoded_media_samples += 1
            samples += 1
        elif value.get("kind") == "correction":
            correction = value.get("correction")
            if not isinstance(correction, dict) or not isinstance(correction.get("sequence"), int):
                raise TimebaseEvidenceError(f"invalid correction line {number}")
            correction_sequences.append(correction["sequence"])
            drift = correction.get("driftSeconds")
            if correction.get("reason") == "steadyStateDrift" and isinstance(drift, (int, float)):
                maximum_correction = max(maximum_correction, abs(float(drift)))
        else:
            raise TimebaseEvidenceError(f"unknown raw capture line {number}")
    if samples < max(1, duration - 120):
        raise TimebaseEvidenceError(
            f"raw capture has {samples} samples for a {duration}-second run"
        )
    if drift_samples < max(1, samples - 120):
        raise TimebaseEvidenceError("raw capture is missing clock-drift samples")
    if any(current <= previous for previous, current in zip(elapsed_seconds, elapsed_seconds[1:])):
        raise TimebaseEvidenceError("raw sample timeline is not strictly increasing")
    if elapsed_seconds[0] > 5 or elapsed_seconds[-1] < max(0, duration - 5):
        raise TimebaseEvidenceError("raw sample timeline does not cover the soak duration")
    maximum_sample_gap = max(
        (current - previous for previous, current in zip(elapsed_seconds, elapsed_seconds[1:])),
        default=1,
    )
    missing_timeline_seconds = (
        elapsed_seconds[-1] - elapsed_seconds[0] + 1 - len(elapsed_seconds)
    )
    if maximum_sample_gap > 5 or missing_timeline_seconds > 120:
        raise TimebaseEvidenceError("raw sample timeline has excessive gaps")
    if any(
        current != previous + 1
        for previous, current in zip(correction_sequences, correction_sequences[1:])
    ):
        raise TimebaseEvidenceError("raw correction sequence has a gap")
    return {
        "status": "captured",
        "format": "application/x-ndjson",
        "runArtifact": name,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "sampleIntervalSeconds": reference.get("sampleIntervalSeconds"),
        "sampleCount": samples,
        "correctionCount": len(correction_sequences),
        "firstCorrectionSequence": correction_sequences[0] if correction_sequences else None,
        "lastCorrectionSequence": correction_sequences[-1] if correction_sequences else None,
        "maximumObservedDriftSeconds": maximum_drift,
        "driftSampleCount": drift_samples,
        "timelineStartSeconds": elapsed_seconds[0],
        "timelineEndSeconds": elapsed_seconds[-1],
        "maximumSampleGapSeconds": maximum_sample_gap,
        "missingTimelineSeconds": missing_timeline_seconds,
        "maximumSteadyCorrectionSeconds": maximum_correction,
        "observedRates": sorted(observed_rates),
        "monotonicityViolations": monotonicity_violations,
        "audioBuffersAdvanced": (
            first_played_buffers is not None
            and last_played_buffers is not None
            and last_played_buffers > first_played_buffers
        ),
        "decodedFrameMediaClockSampleCount": decoded_media_samples,
        "_correctionSequences": correction_sequences,
    }


def require_matching_correction_sequences(
    corrections: object, raw_sequences: list[int]
) -> None:
    if not isinstance(corrections, list):
        raise TimebaseEvidenceError("compact timebase corrections are malformed")
    compact_sequences: list[int] = []
    for correction in corrections:
        if (
            not isinstance(correction, dict)
            or type(correction.get("sequence")) is not int
        ):
            raise TimebaseEvidenceError("compact timebase correction has no sequence")
        compact_sequences.append(correction["sequence"])
    if compact_sequences != raw_sequences:
        raise TimebaseEvidenceError("compact and raw correction sequences differ")


def augment(
    evidence_path: Path,
    raw_root: Path,
    trace: Path,
    toc: Path,
    digest_script: Path,
) -> dict:
    try:
        payload = json.loads(evidence_path.read_text())
    except (OSError, ValueError) as error:
        raise TimebaseEvidenceError(f"cannot read timebase evidence: {error}") from error
    if not isinstance(payload, dict) or payload.get("scenario") not in SCENARIOS:
        raise TimebaseEvidenceError("timebase artifacts belong only to timebase soak rows")
    duration = payload.get("durationSeconds")
    if not isinstance(duration, int) or duration < 7200:
        raise TimebaseEvidenceError("timebase evidence is shorter than 7,200 seconds")
    audio = payload.get("audioPresentationSeries")
    reference = payload.get("rawCapture")
    if not isinstance(audio, dict) or not isinstance(reference, dict):
        raise TimebaseEvidenceError("timebase audio/raw evidence is malformed")
    raw = raw_record(raw_root, reference, duration)
    corrections = payload.get("corrections")
    require_matching_correction_sequences(
        corrections, raw.pop("_correctionSequences")
    )
    drift_budget = payload.get("driftBudget")
    correction_budget = payload.get("correctionBudget")
    if not isinstance(drift_budget, dict) or not isinstance(correction_budget, dict):
        raise TimebaseEvidenceError("timebase budgets are malformed")
    if raw["maximumObservedDriftSeconds"] > drift_budget.get("maximumSeconds", -1):
        raise TimebaseEvidenceError("raw clock series exceeds the drift budget")
    if raw["maximumSteadyCorrectionSeconds"] > correction_budget.get("maximumSeconds", -1):
        raise TimebaseEvidenceError("raw correction series exceeds the correction budget")
    if raw["monotonicityViolations"] != 0:
        raise TimebaseEvidenceError("raw presented-frame series moved backwards")
    if not raw["audioBuffersAdvanced"]:
        raise TimebaseEvidenceError("raw audio output counters did not advance")
    if raw["decodedFrameMediaClockSampleCount"] < raw["sampleCount"] // 2:
        raise TimebaseEvidenceError("decoded-frame media clock was not captured")
    if any(not any(abs(rate - expected) < 0.01 for rate in raw["observedRates"]) for expected in (0.5, 1.0, 2.0)):
        raise TimebaseEvidenceError("raw clock series did not cover all required rates")
    raw_name = reference["fileName"]
    raw_matches = [path for path in raw_root.rglob(raw_name) if path.is_file()]
    if len(raw_matches) != 1:
        raise TimebaseEvidenceError(f"expected one raw capture named {raw_name}")
    artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
    try:
        artifact_directory.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        raise TimebaseEvidenceError(
            f"cannot create timebase artifact directory: {error}"
        ) from error
    try:
        staged_raw = artifact_directory / raw_name
        shutil.copy2(raw_matches[0], staged_raw)
        if hashlib.sha256(staged_raw.read_bytes()).hexdigest() != raw["sha256"]:
            raise TimebaseEvidenceError("retained raw capture digest mismatch")
        raw["runArtifact"] = staged_raw.relative_to(evidence_path.parent).as_posix()
        raw["digestAlgorithm"] = "sha256"
        host_trace = trace_record(
            trace,
            toc,
            digest_script,
            artifact_directory,
            evidence_path.parent,
        )
    except (OSError, TimebaseEvidenceError):
        shutil.rmtree(artifact_directory, ignore_errors=True)
        raise
    audio.pop("hostTraceStatus", None)
    audio["hostTrace"] = host_trace
    payload["rawCapture"] = raw
    payload.pop("hostTraceRequirements", None)
    evidence_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--raw-root", type=Path, required=True)
    parser.add_argument("--audio-trace", type=Path, required=True)
    parser.add_argument("--audio-toc", type=Path, required=True)
    parser.add_argument("--digest-script", type=Path, required=True)
    args = parser.parse_args()
    try:
        augment(
            args.evidence,
            args.raw_root,
            args.audio_trace,
            args.audio_toc,
            args.digest_script,
        )
    except (OSError, TimebaseEvidenceError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
