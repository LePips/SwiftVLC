#!/usr/bin/env python3
"""Bind a host-captured Instruments allocation trace to soak evidence."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path


class TraceEvidenceError(ValueError):
    pass


SHA256 = re.compile(r"[0-9a-f]{64}")


def augment(evidence_path: Path, trace: Path, toc: Path, digest_script: Path) -> dict:
    try:
        payload = json.loads(evidence_path.read_text())
    except (OSError, ValueError) as error:
        raise TraceEvidenceError(f"cannot read adaptive evidence: {error}") from error
    if not isinstance(payload, dict) or payload.get("scenario") != "adaptive-hls-soak":
        raise TraceEvidenceError("allocation trace belongs only to adaptive-hls-soak evidence")
    provenance = payload.get("allocationProvenance")
    if not isinstance(provenance, dict):
        raise TraceEvidenceError("adaptive evidence has no allocation provenance object")
    if not trace.is_dir() or not any(trace.rglob("*")):
        raise TraceEvidenceError("allocation trace is missing or empty")
    try:
        toc_text = toc.read_text(errors="replace")
    except OSError as error:
        raise TraceEvidenceError(f"cannot read allocation trace table of contents: {error}") from error
    if not re.search(r"allocation|vm-tracker", toc_text, re.IGNORECASE):
        raise TraceEvidenceError("trace table of contents has no allocation instrument data")

    artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
    staged_trace = artifact_directory / trace.name
    staged_toc = artifact_directory / toc.name
    try:
        artifact_directory.mkdir(parents=True, exist_ok=False)
        shutil.copytree(trace, staged_trace)
        shutil.copy2(toc, staged_toc)
    except OSError as error:
        raise TraceEvidenceError(f"cannot retain allocation trace artifacts: {error}") from error

    result = subprocess.run(
        [sys.executable, str(digest_script), str(staged_trace)],
        check=False,
        capture_output=True,
        text=True,
    )
    digest = result.stdout.strip()
    if result.returncode != 0 or not SHA256.fullmatch(digest):
        raise TraceEvidenceError("could not compute the allocation trace tree digest")

    provenance["instrumentsTrace"] = {
        "format": "com.apple.instruments.trace",
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "treeDigest": digest,
        "runArtifact": staged_trace.relative_to(evidence_path.parent).as_posix(),
        "tableOfContents": staged_toc.relative_to(evidence_path.parent).as_posix(),
        "template": "Allocations",
        "rollingWindow": "15m",
        "targetProcess": "iOS",
    }
    evidence_path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--toc", type=Path, required=True)
    parser.add_argument("--digest-script", type=Path, required=True)
    args = parser.parse_args()
    try:
        augment(args.evidence, args.trace, args.toc, args.digest_script)
    except TraceEvidenceError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
