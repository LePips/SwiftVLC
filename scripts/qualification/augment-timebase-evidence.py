#!/usr/bin/env python3
"""Bind the full clock JSONL and Audio System Trace to timebase evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy


class TimebaseEvidenceError(ValueError):
    pass


SHA256 = re.compile(r"[0-9a-f]{64}")
SCENARIOS = {"timebase-vod-soak", "timebase-live-soak"}


def trace_record(
    trace: Path,
    toc: Path,
    digest_script: Path,
    producer_fields: dict,
    scenario: str,
    target_device_identifier: str,
    artifact_directory: Path,
    evidence_directory: Path,
) -> dict:
    if not trace.is_dir() or not any(trace.rglob("*")):
        raise TimebaseEvidenceError("Audio System Trace is missing or empty")
    try:
        text = toc.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise TimebaseEvidenceError(
            f"cannot read Audio System Trace TOC: {error}"
        ) from error
    if "audio" not in text.lower():
        raise TimebaseEvidenceError("Audio System Trace TOC has no audio tables")
    staged_trace = artifact_directory / trace.name
    staged_toc = artifact_directory / toc.name
    staged_summary = artifact_directory / f"{trace.stem}-summary.json"
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
    try:
        summary = policy.capture_xctrace_export_summary(
            staged_trace,
            staged_toc,
            scenario_id=scenario,
            role="audioPresentationSeries",
            template="Audio System Trace",
            target_device_identifier=target_device_identifier,
            producer_fields=producer_fields,
        )
        staged_summary.write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (OSError, policy.QualificationPolicyError) as error:
        raise TimebaseEvidenceError(
            f"cannot retain Audio System Trace export summary: {error}"
        ) from error
    return {
        "status": "captured",
        "artifactRole": "audioPresentationSeries",
        "template": "Audio System Trace",
        "format": "com.apple.instruments.trace",
        "runArtifact": staged_trace.relative_to(evidence_directory).as_posix(),
        "tableOfContents": staged_toc.relative_to(evidence_directory).as_posix(),
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "treeDigest": digest,
        "treeSizeBytes": policy.tree_size_bytes(staged_trace),
        "treeEntryCount": policy.tree_entry_count(staged_trace),
        "tableOfContentsDigestAlgorithm": "sha256",
        "tableOfContentsDigest": policy.sha256_file(staged_toc),
        "tableOfContentsSizeBytes": staged_toc.stat().st_size,
        "targetProcess": "iOS",
        "exportSummary": staged_summary.relative_to(evidence_directory).as_posix(),
        "exportSummaryDigestAlgorithm": "sha256",
        "exportSummaryDigest": policy.sha256_file(staged_summary),
        "exportSummarySizeBytes": staged_summary.stat().st_size,
        **producer_fields,
    }


def raw_record(root: Path, reference: dict, duration: int) -> dict:
    name = reference.get("fileName")
    if not isinstance(name, str) or Path(name).name != name:
        raise TimebaseEvidenceError("raw capture reference is unsafe")
    matches = [path for path in root.rglob(name) if path.is_file()]
    if len(matches) != 1:
        raise TimebaseEvidenceError(f"expected one raw capture named {name}")
    path = matches[0]
    try:
        record = policy.inspect_timebase_raw_capture(
            path, reference.get("sampleIntervalSeconds")
        )
    except policy.QualificationPolicyError as error:
        raise TimebaseEvidenceError(str(error)) from error
    if record["sampleCount"] < max(1, duration - 120):
        raise TimebaseEvidenceError(
            f"raw capture has {record['sampleCount']} samples for a "
            f"{duration}-second run"
        )
    if record["driftSampleCount"] < max(1, record["sampleCount"] - 120):
        raise TimebaseEvidenceError("raw capture is missing clock-drift samples")
    if record["timelineStartSeconds"] > 5 or record["timelineEndSeconds"] < max(
        0, duration - 5
    ):
        raise TimebaseEvidenceError(
            "raw sample timeline does not cover the soak duration"
        )
    if record["maximumSampleGapSeconds"] > 5 or record["missingTimelineSeconds"] > 120:
        raise TimebaseEvidenceError("raw sample timeline has excessive gaps")
    record["runArtifact"] = name
    return record


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
        payload = policy.load_json(evidence_path, "timebase evidence")
    except (OSError, policy.QualificationPolicyError) as error:
        raise TimebaseEvidenceError(
            f"cannot read timebase evidence: {error}"
        ) from error
    if not isinstance(payload, dict) or payload.get("scenario") not in SCENARIOS:
        raise TimebaseEvidenceError(
            "timebase artifacts belong only to timebase soak rows"
        )
    duration = payload.get("durationSeconds")
    if not isinstance(duration, int) or duration < 7200:
        raise TimebaseEvidenceError("timebase evidence is shorter than 7,200 seconds")
    audio = payload.get("audioPresentationSeries")
    reference = payload.get("rawCapture")
    if not isinstance(audio, dict) or not isinstance(reference, dict):
        raise TimebaseEvidenceError("timebase audio/raw evidence is malformed")
    try:
        producer_fields = policy.host_artifact_producer_fields(
            payload, evidence_path.stem
        )
    except policy.QualificationPolicyError as error:
        raise TimebaseEvidenceError(str(error)) from error
    raw = raw_record(raw_root, reference, duration)
    corrections = payload.get("corrections")
    require_matching_correction_sequences(corrections, raw.pop("_correctionSequences"))
    drift_budget = payload.get("driftBudget")
    correction_budget = payload.get("correctionBudget")
    if not isinstance(drift_budget, dict) or not isinstance(correction_budget, dict):
        raise TimebaseEvidenceError("timebase budgets are malformed")
    if raw["maximumObservedDriftSeconds"] > drift_budget.get("maximumSeconds", -1):
        raise TimebaseEvidenceError("raw clock series exceeds the drift budget")
    if raw["maximumSteadyCorrectionSeconds"] > correction_budget.get(
        "maximumSeconds", -1
    ):
        raise TimebaseEvidenceError(
            "raw correction series exceeds the correction budget"
        )
    if raw["monotonicityViolations"] != 0:
        raise TimebaseEvidenceError("raw presented-frame series moved backwards")
    if not raw["audioBuffersAdvanced"]:
        raise TimebaseEvidenceError("raw audio output counters did not advance")
    if raw["decodedFrameMediaClockSampleCount"] < raw["sampleCount"] // 2:
        raise TimebaseEvidenceError("decoded-frame media clock was not captured")
    if any(
        not any(abs(rate - expected) < 0.01 for rate in raw["observedRates"])
        for expected in (0.5, 1.0, 2.0)
    ):
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
        raw.update(producer_fields)
        host_trace = trace_record(
            trace,
            toc,
            digest_script,
            producer_fields,
            payload["scenario"],
            payload["deviceIdentifier"],
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
    try:
        policy.validate_host_augmented_artifacts(
            payload,
            payload["scenario"],
            evidence_path.parent,
            evidence_path.stem,
        )
    except policy.QualificationPolicyError as error:
        shutil.rmtree(artifact_directory, ignore_errors=True)
        raise TimebaseEvidenceError(
            f"retained timebase artifacts failed semantic validation: {error}"
        ) from error
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
