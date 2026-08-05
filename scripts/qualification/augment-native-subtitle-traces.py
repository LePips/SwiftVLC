#!/usr/bin/env python3
"""Bind CPU, GPU, and Metal/color traces to native subtitle evidence."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


class NativeSubtitleTraceError(ValueError):
    pass


SHA256 = re.compile(r"[0-9a-f]{64}")
TRACE_FIELDS = {
    "time": ("cpu", "Time Profiler"),
    "game": ("gpu", "Game Performance"),
    "metal": ("colorHDRImpact", "Metal System Trace"),
}


def trace_record(
    trace: Path,
    toc: Path,
    digest_script: Path,
    template: str,
    artifact_directory: Path,
    evidence_directory: Path,
) -> dict:
    if not trace.is_dir() or not any(trace.rglob("*")):
        raise NativeSubtitleTraceError(f"{template} trace is missing or empty")
    try:
        toc_text = toc.read_text(errors="replace")
    except OSError as error:
        raise NativeSubtitleTraceError(
            f"cannot read {template} trace TOC: {error}"
        ) from error
    if "schema" not in toc_text.lower() and "table" not in toc_text.lower():
        raise NativeSubtitleTraceError(f"{template} trace TOC has no recorded tables")
    staged_trace = artifact_directory / trace.name
    staged_toc = artifact_directory / toc.name
    try:
        shutil.copytree(trace, staged_trace)
        shutil.copy2(toc, staged_toc)
    except OSError as error:
        raise NativeSubtitleTraceError(
            f"cannot retain {template} trace artifacts: {error}"
        ) from error
    result = subprocess.run(
        [sys.executable, str(digest_script), str(staged_trace)],
        check=False,
        capture_output=True,
        text=True,
    )
    digest = result.stdout.strip()
    if result.returncode != 0 or not SHA256.fullmatch(digest):
        raise NativeSubtitleTraceError(f"could not digest {template} trace")
    return {
        "status": "captured",
        "template": template,
        "format": "com.apple.instruments.trace",
        "runArtifact": staged_trace.relative_to(evidence_directory).as_posix(),
        "tableOfContents": staged_toc.relative_to(evidence_directory).as_posix(),
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "treeDigest": digest,
        "targetProcess": "iOS",
    }


def augment(
    evidence_path: Path,
    traces: dict[str, tuple[Path, Path]],
    digest_script: Path,
) -> dict:
    try:
        payload = json.loads(evidence_path.read_text())
    except (OSError, ValueError) as error:
        raise NativeSubtitleTraceError(
            f"cannot read native subtitle evidence: {error}"
        ) from error
    if not isinstance(payload, dict) or payload.get("scenario") != "native-subtitle-matrix":
        raise NativeSubtitleTraceError(
            "native subtitle traces belong only to native-subtitle-matrix"
        )
    metrics = payload.get("metrics")
    if not isinstance(metrics, dict):
        raise NativeSubtitleTraceError("native subtitle evidence has no metrics object")

    artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
    try:
        artifact_directory.mkdir(parents=True, exist_ok=False)
    except OSError as error:
        raise NativeSubtitleTraceError(
            f"cannot create native subtitle trace artifact directory: {error}"
        ) from error
    try:
        for key, (field, template) in TRACE_FIELDS.items():
            trace, toc = traces[key]
            record = trace_record(
                trace,
                toc,
                digest_script,
                template,
                artifact_directory,
                evidence_path.parent,
            )
            metric = metrics.get(field)
            if not isinstance(metric, dict):
                raise NativeSubtitleTraceError(f"{field} evidence is malformed")
            metric.pop("hostTraceStatus", None)
            if field == "gpu":
                metrics[field] = record
            else:
                metric["hostTrace"] = record
    except (OSError, NativeSubtitleTraceError):
        shutil.rmtree(artifact_directory, ignore_errors=True)
        raise
    payload.pop("hostTraceRequirements", None)
    evidence_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--time-trace", type=Path, required=True)
    parser.add_argument("--time-toc", type=Path, required=True)
    parser.add_argument("--game-trace", type=Path, required=True)
    parser.add_argument("--game-toc", type=Path, required=True)
    parser.add_argument("--metal-trace", type=Path, required=True)
    parser.add_argument("--metal-toc", type=Path, required=True)
    parser.add_argument("--digest-script", type=Path, required=True)
    args = parser.parse_args()
    try:
        augment(
            args.evidence,
            {
                "time": (args.time_trace, args.time_toc),
                "game": (args.game_trace, args.game_toc),
                "metal": (args.metal_trace, args.metal_toc),
            },
            args.digest_script,
        )
    except NativeSubtitleTraceError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
