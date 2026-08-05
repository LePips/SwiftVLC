#!/usr/bin/env python3
"""Create a compact, privacy-scrubbed device-validation report ZIP."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tempfile
import zipfile
from pathlib import Path
from typing import Any


SENSITIVE_VALUE_KEYS = {
    "coredeviceidentifier",
    "ecid",
    "ecidhex",
    "id",
    "identifier",
    "name",
    "serialnumber",
    "udid",
    "tunnelipaddress",
}
REMOVED_KEYS = {
    "coredeviceidentifier",
    "ecid",
    "ecidhex",
    "serialnumber",
    "udid",
    "tunnelipaddress",
}
JSON_FILES = (
    "report.json",
    "device.json",
    "candidate-metadata.json",
    "fixture-manifest.json",
    "host-info.json",
    "validation-plan.json",
)
TEXT_LOG_PATTERNS = (
    "*.log",
    "scenario-results.tsv",
    "qualification-rows.jsonl",
    "fixture-requests.jsonl",
)
MAX_LOG_BYTES = 256 * 1024
MAX_ARCHIVE_BYTES = 24 * 1024 * 1024


def sanitize_json(value: Any, secrets: set[str] | None = None) -> Any:
    if isinstance(value, dict):
        return {
            key: sanitize_json(child, secrets)
            for key, child in value.items()
            if key.lower() not in REMOVED_KEYS
        }
    if isinstance(value, list):
        return [sanitize_json(child, secrets) for child in value]
    if isinstance(value, str):
        return scrub_text(value, secrets)
    return value


def scrub_text(value: str, secrets: set[str] | None = None) -> str:
    for secret in sorted(secrets or set(), key=len, reverse=True):
        if secret:
            value = value.replace(secret, "<redacted>")
    value = re.sub(r"/Users/[^/\s]+", "/Users/<redacted>", value)
    value = re.sub(r"file:///Users/[^/\s]+", "file:///Users/<redacted>", value)
    value = re.sub(r"/Volumes/[^/\s]+", "/Volumes/<redacted>", value)
    value = re.sub(
        r'((?:Apple Development|Apple Distribution): )[^"\n(]+',
        r"\1<redacted> ",
        value,
    )
    value = re.sub(
        r"https?://(?:\[[0-9A-Fa-f:]+\]|127\.0\.0\.1|localhost|(?:\d{1,3}\.){3}\d{1,3})(?::\d+)?",
        "http://<fixture-server>",
        value,
    )
    value = re.sub(r"\b(?:\d{1,3}\.){3}\d{1,3}\b", "<redacted-ip>", value)
    value = re.sub(
        r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){2,}[0-9A-Fa-f:]{0,4}(?![0-9A-Fa-f:])",
        "<redacted-ip>",
        value,
    )
    return value


def sensitive_values(device: Any) -> set[str]:
    values: set[str] = set()
    if isinstance(device, dict):
        for key, value in device.items():
            if key.lower() in SENSITIVE_VALUE_KEYS and isinstance(value, (str, int)):
                values.add(str(value))
            values.update(sensitive_values(value))
    elif isinstance(device, list):
        for value in device:
            values.update(sensitive_values(value))
    return values


def read_scenarios(run_dir: Path) -> tuple[list[dict[str, Any]], bool]:
    report_path = run_dir / "report.json"
    if report_path.is_file():
        report = json.loads(report_path.read_text())
        return report.get("scenarios", []), True

    scenarios = []
    progress = run_dir / "scenario-results.tsv"
    if progress.is_file():
        for line in progress.read_text(errors="replace").splitlines():
            fields = line.split("\t")
            if len(fields) != 7:
                continue
            scenario, result, exit_code, errors, app_log, evidence, duration = fields
            scenarios.append(
                {
                    "scenario": scenario,
                    "result": result,
                    "xcodebuildExitCode": int(exit_code),
                    "libraryErrorCount": int(errors),
                    "appLog": app_log,
                    "qualificationEvidence": evidence,
                    "durationSeconds": int(duration),
                }
            )
    return scenarios, False


def device_summary(run_dir: Path) -> dict[str, Any]:
    path = run_dir / "device.json"
    if not path.is_file():
        return {}
    value = json.loads(path.read_text()).get("selected") or {}
    allowed = (
        "marketingName",
        "deviceFamily",
        "productType",
        "osVersion",
        "osBuild",
        "osReleaseType",
        "developerModeStatus",
        "transport",
        "matchingHardwareRows",
    )
    return {key: value[key] for key in allowed if key in value}


def failure_reasons(run_dir: Path, scenarios: list[dict[str, Any]]) -> list[dict[str, Any]]:
    results = []
    pattern = re.compile(
        r"(?:error:|failed -|encountered an error|Testing failed:|TEST EXECUTE FAILED)",
        re.IGNORECASE,
    )
    for row in scenarios:
        if row.get("result") == "pass":
            continue
        scenario = str(row.get("scenario", "unknown"))
        log_path = run_dir / f"{scenario}-xcodebuild.log"
        reasons = []
        if log_path.is_file():
            for line in log_path.read_text(errors="replace").splitlines():
                candidate = line.strip()
                if pattern.search(candidate) and candidate not in reasons:
                    reasons.append(candidate[:500])
            reasons = reasons[-3:]
        results.append(
            {
                "scenario": scenario,
                "reasons": reasons or ["No concise failure line was found; see the included log."],
            }
        )
    return results


def summary_markdown(
    run_dir: Path, scenarios: list[dict[str, Any]], complete: bool
) -> str:
    device = device_summary(run_dir)
    passed = sum(row.get("result") == "pass" for row in scenarios)
    failed = sum(row.get("result") != "pass" for row in scenarios)
    plan_path = run_dir / "validation-plan.json"
    plan = json.loads(plan_path.read_text()) if plan_path.is_file() else {}
    planned = len(plan.get("selectedScenarioDrivers", []))
    state = "COMPLETE" if complete else "INCOMPLETE / INTERRUPTED"
    overall = "PASS" if complete and scenarios and failed == 0 else "FAIL"
    if not complete:
        overall = "INCOMPLETE"
    lines = [
        "# SwiftVLC physical-device validation",
        "",
        f"- Report state: **{state}**",
        f"- Result: **{overall}**",
        f"- Completed scenarios: **{len(scenarios)}** ({passed} passed, {failed} failed)",
    ]
    if planned:
        lines.append(f"- Planned scenario drivers: **{planned}**")
        if len(scenarios) < planned:
            lines.append(f"- Unfinished scenario drivers: **{planned - len(scenarios)}**")
    if device:
        model = device.get("marketingName") or device.get("productType") or "unknown"
        os_description = " ".join(
            str(device.get(key, "")) for key in ("osVersion", "osBuild")
        ).strip()
        lines.extend(
            [
                f"- Device: **{model}** ({device.get('productType', 'unknown')})",
                f"- OS: **{os_description or 'unknown'}** ({device.get('osReleaseType', 'unknown')})",
            ]
        )
    lines.extend(
        [
            "",
            "## Scenario results",
            "",
            "| Scenario | Result | Duration | Library errors | Evidence |",
            "|---|---:|---:|---:|---|",
        ]
    )
    for row in scenarios:
        lines.append(
            "| {scenario} | {result} | {duration}s | {errors} | {evidence} |".format(
                scenario=row.get("scenario", "unknown"),
                result=str(row.get("result", "unknown")).upper(),
                duration=row.get("durationSeconds", 0),
                errors=row.get("libraryErrorCount", "unknown"),
                evidence=row.get("qualificationEvidence", "unknown"),
            )
        )
    if not scenarios:
        lines.append("| _No scenario completed_ | INCOMPLETE | 0s | — | — |")
    failures = failure_reasons(run_dir, scenarios)
    if failures:
        lines.extend(["", "## Failure excerpts", ""])
        for failure in failures:
            lines.append(f"### {failure['scenario']}")
            lines.append("")
            for reason in failure["reasons"]:
                safe_reason = reason.replace("`", "'")
                lines.append(f"- `{safe_reason}`")
            lines.append("")
    lines.extend(
        [
            "",
            "## Sharing",
            "",
            "Attach this ZIP to the GitHub issue. Hardware identifiers, the device name, "
            "local usernames, and fixture-server addresses have been removed. The full "
            "raw evidence remains only in the adjacent `raw` directory on the tester's Mac.",
            "",
        ]
    )
    return "\n".join(lines)


def collect_files(run_dir: Path, staging: Path, secrets: set[str]) -> None:
    for name in JSON_FILES:
        source = run_dir / name
        if not source.is_file():
            continue
        value = sanitize_json(json.loads(source.read_text()), secrets)
        (staging / name).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")

    evidence_destination = staging / "evidence"
    for source in sorted((run_dir / "evidence").glob("*.json")):
        evidence_destination.mkdir(exist_ok=True)
        value = sanitize_json(json.loads(source.read_text()), secrets)
        (evidence_destination / source.name).write_text(
            json.dumps(value, indent=2, sort_keys=True) + "\n"
        )

    logs_destination = staging / "logs"
    seen: set[Path] = set()
    for pattern in TEXT_LOG_PATTERNS:
        for source in sorted(run_dir.glob(pattern)):
            if not source.is_file() or source in seen:
                continue
            seen.add(source)
            logs_destination.mkdir(exist_ok=True)
            raw = source.read_bytes()
            suffix = ""
            if len(raw) > MAX_LOG_BYTES:
                raw = raw[-MAX_LOG_BYTES:]
                suffix = "[Earlier log content omitted from share report.]\n"
            text = suffix + raw.decode("utf-8", errors="replace")
            (logs_destination / source.name).write_text(scrub_text(text, secrets))


def write_manifest(staging: Path) -> None:
    lines = []
    for path in sorted(staging.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS.txt":
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            lines.append(f"{digest}  {path.relative_to(staging)}")
    (staging / "SHA256SUMS.txt").write_text("\n".join(lines) + "\n")


def package(run_dir: Path, output: Path) -> Path:
    if not run_dir.is_dir():
        raise ValueError(f"run directory does not exist: {run_dir}")
    device_path = run_dir / "device.json"
    device = json.loads(device_path.read_text()) if device_path.is_file() else {}
    secrets = sensitive_values(device)
    scenarios, complete = read_scenarios(run_dir)

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="swiftvlc-share-report.") as temporary:
        staging = Path(temporary) / "SwiftVLC-Device-Report"
        staging.mkdir()
        collect_files(run_dir, staging, secrets)
        failures = sanitize_json(failure_reasons(run_dir, scenarios), secrets)
        (staging / "failure-reasons.json").write_text(
            json.dumps(failures, indent=2, sort_keys=True) + "\n"
        )
        (staging / "SUMMARY.md").write_text(
            scrub_text(summary_markdown(run_dir, scenarios, complete), secrets)
        )
        write_manifest(staging)
        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(staging.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(staging.parent))
    if output.stat().st_size > MAX_ARCHIVE_BYTES:
        output.unlink()
        raise ValueError("share report exceeded the 24 MiB GitHub upload budget")
    return output


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    output = args.output or args.run_dir.with_name(f"{args.run_dir.name}-share.zip")
    try:
        package(args.run_dir.resolve(), output.resolve())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))
    print(output.resolve())


if __name__ == "__main__":
    main()
