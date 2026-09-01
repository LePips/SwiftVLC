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

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy


class TraceEvidenceError(ValueError):
    pass


SHA256 = re.compile(r"[0-9a-f]{64}")


def augment(evidence_path: Path, trace: Path, toc: Path, digest_script: Path) -> dict:
    try:
        payload = policy.load_json(evidence_path, "adaptive evidence")
    except (OSError, policy.QualificationPolicyError) as error:
        raise TraceEvidenceError(f"cannot read adaptive evidence: {error}") from error
    if not isinstance(payload, dict) or payload.get("scenario") != "adaptive-hls-soak":
        raise TraceEvidenceError(
            "allocation trace belongs only to adaptive-hls-soak evidence"
        )
    provenance = payload.get("allocationProvenance")
    if not isinstance(provenance, dict):
        raise TraceEvidenceError(
            "adaptive evidence has no allocation provenance object"
        )
    try:
        producer_fields = policy.host_artifact_producer_fields(
            payload, evidence_path.stem
        )
    except policy.QualificationPolicyError as error:
        raise TraceEvidenceError(str(error)) from error
    if not trace.is_dir() or not any(trace.rglob("*")):
        raise TraceEvidenceError("allocation trace is missing or empty")
    try:
        toc_text = toc.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise TraceEvidenceError(
            f"cannot read allocation trace table of contents: {error}"
        ) from error
    if not re.search(r"allocation|vm-tracker", toc_text, re.IGNORECASE):
        raise TraceEvidenceError(
            "trace table of contents has no allocation instrument data"
        )

    artifact_directory = evidence_path.parent / "artifacts" / evidence_path.stem
    staged_trace = artifact_directory / trace.name
    staged_toc = artifact_directory / toc.name
    staged_summary = artifact_directory / f"{trace.stem}-summary.json"
    try:
        artifact_directory.mkdir(parents=True, exist_ok=False)
        shutil.copytree(trace, staged_trace)
        shutil.copy2(toc, staged_toc)
    except OSError as error:
        raise TraceEvidenceError(
            f"cannot retain allocation trace artifacts: {error}"
        ) from error

    result = subprocess.run(
        [sys.executable, str(digest_script), str(staged_trace)],
        check=False,
        capture_output=True,
        text=True,
    )
    digest = result.stdout.strip()
    if result.returncode != 0 or not SHA256.fullmatch(digest):
        raise TraceEvidenceError("could not compute the allocation trace tree digest")
    try:
        summary = policy.capture_xctrace_export_summary(
            staged_trace,
            staged_toc,
            scenario_id="adaptive-hls-soak",
            role="allocation",
            template="Allocations",
            target_device_identifier=payload["deviceIdentifier"],
            producer_fields=producer_fields,
        )
        staged_summary.write_text(
            json.dumps(summary, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (KeyError, OSError, policy.QualificationPolicyError) as error:
        raise TraceEvidenceError(
            f"cannot retain allocation xctrace export summary: {error}"
        ) from error

    provenance["instrumentsTrace"] = {
        "status": "captured",
        "artifactRole": "allocation",
        "format": "com.apple.instruments.trace",
        "treeDigestAlgorithm": "swiftvlc-tree-v1",
        "treeDigest": digest,
        "treeSizeBytes": policy.tree_size_bytes(staged_trace),
        "treeEntryCount": policy.tree_entry_count(staged_trace),
        "runArtifact": staged_trace.relative_to(evidence_path.parent).as_posix(),
        "tableOfContents": staged_toc.relative_to(evidence_path.parent).as_posix(),
        "tableOfContentsDigestAlgorithm": "sha256",
        "tableOfContentsDigest": policy.sha256_file(staged_toc),
        "tableOfContentsSizeBytes": staged_toc.stat().st_size,
        "template": "Allocations",
        "rollingWindow": "15m",
        "targetProcess": "iOS",
        "exportSummary": staged_summary.relative_to(evidence_path.parent).as_posix(),
        "exportSummaryDigestAlgorithm": "sha256",
        "exportSummaryDigest": policy.sha256_file(staged_summary),
        "exportSummarySizeBytes": staged_summary.stat().st_size,
        **producer_fields,
    }
    try:
        policy.validate_host_augmented_artifacts(
            payload,
            "adaptive-hls-soak",
            evidence_path.parent,
            evidence_path.stem,
        )
    except policy.QualificationPolicyError as error:
        raise TraceEvidenceError(
            f"retained allocation trace failed semantic validation: {error}"
        ) from error
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
