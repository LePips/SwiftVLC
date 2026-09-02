#!/usr/bin/env python3
"""Create a compact, privacy-scrubbed device-validation report ZIP."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import report_validation  # noqa: E402

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
    report_validation.EVIDENCE_MANIFEST_FILENAME,
)
TEXT_LOG_PATTERNS = (
    "*.log",
    "scenario-results.tsv",
    "qualification-rows.jsonl",
    "fixture-requests.jsonl",
)
MAX_LOG_BYTES = 256 * 1024
MAX_ARCHIVE_BYTES = 24 * 1024 * 1024

URL_AUTHORITY = re.compile(
    r"https?://(?P<host>\[[^\]\s/]+\]|[^:/\s]+)(?::\d+)?",
    flags=re.IGNORECASE,
)
IPV4_TOKEN = re.compile(r"(?<![0-9A-Za-z])(?:\d{1,3}\.){3}\d{1,3}(?![0-9A-Za-z])")
MAC_EUI_TOKEN = re.compile(
    r"(?<![0-9A-Fa-f])(?:"
    r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}"
    r"|(?:[0-9A-Fa-f]{2}:){7}[0-9A-Fa-f]{2}"
    r"|(?:[0-9A-Fa-f]{2}-){5}[0-9A-Fa-f]{2}"
    r"|(?:[0-9A-Fa-f]{2}-){7}[0-9A-Fa-f]{2}"
    r"|(?:[0-9A-Fa-f]{4}\.){2}[0-9A-Fa-f]{4}"
    r"|(?:[0-9A-Fa-f]{4}\.){3}[0-9A-Fa-f]{4}"
    r")(?![0-9A-Fa-f])"
)
IPV6_TOKEN = re.compile(
    r"(?<![0-9A-Za-z])"
    r"(?P<address>[0-9A-Fa-f:.]*:[0-9A-Fa-f:.]*"
    r"(?:%(?:25)?[A-Za-z0-9_.-]+)?)"
    r"(?![0-9A-Za-z])"
)


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
            value = re.sub(re.escape(secret), "<redacted>", value, flags=re.IGNORECASE)
    value = re.sub(r"/Users/[^/\s]+", "/Users/<redacted>", value)
    value = re.sub(r"file:///Users/[^/\s]+", "file:///Users/<redacted>", value)
    value = re.sub(r"/Volumes/[^/\s]+", "/Volumes/<redacted>", value)
    value = re.sub(
        r'((?:Apple Development|Apple Distribution): )[^"\n(]+',
        r"\1<redacted> ",
        value,
    )

    def scrub_url(match: re.Match[str]) -> str:
        host = match.group("host")
        if host.startswith("[") and host.endswith("]"):
            host = host[1:-1]
        try:
            is_private_host = host.lower() == "localhost" or bool(
                ipaddress.ip_address(host)
            )
        except ValueError:
            is_private_host = False
        return "http://<fixture-server>" if is_private_host else match.group(0)

    def scrub_ipv4(match: re.Match[str]) -> str:
        components = match.group(0).split(".")
        if any(int(component) > 255 for component in components):
            return match.group(0)
        return "<redacted-ip>"

    def scrub_ipv6(match: re.Match[str]) -> str:
        candidate = match.group("address")
        # Do not make a timestamp redaction rule: recognize an actual address.
        # Punctuation can be adjacent to an address in prose but is not secret.
        address = candidate.rstrip(".,;")
        suffix = candidate[len(address) :]
        candidates = [(address, suffix)]
        # CoreDevice and server logs sometimes render an unbracketed address
        # followed by a decimal port, or append a prose colon. Try those
        # unambiguous splits only when the complete token is not an address.
        if address.endswith(":"):
            candidates.append((address[:-1], f":{suffix}"))
        if ":" in address:
            prefix, final = address.rsplit(":", 1)
            if final.isdecimal() and 0 <= int(final) <= 65535:
                candidates.append((prefix, f":{final}{suffix}"))
        for possible_address, possible_suffix in candidates:
            try:
                ipaddress.IPv6Address(possible_address)
            except ipaddress.AddressValueError:
                continue
            return f"<redacted-ip>{possible_suffix}"
        return candidate

    value = URL_AUTHORITY.sub(scrub_url, value)
    value = MAC_EUI_TOKEN.sub("<redacted-mac>", value)
    value = IPV6_TOKEN.sub(scrub_ipv6, value)
    value = IPV4_TOKEN.sub(scrub_ipv4, value)
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


def bundle_identifier_values(value: Any) -> set[str]:
    values: set[str] = set()
    if isinstance(value, dict):
        for key, child in value.items():
            if key.lower().endswith("bundleidentifier") and isinstance(child, str):
                values.add(child)
            values.update(bundle_identifier_values(child))
    elif isinstance(value, list):
        for child in value:
            values.update(bundle_identifier_values(child))
    return values


def expand_signing_values(values: set[str]) -> set[str]:
    expanded = set(values)
    for value in values:
        if value.endswith(".xctrunner"):
            expanded.add(value.removesuffix(".xctrunner"))
        match = re.match(
            r"^com\.swiftvlc\.validation\.([A-Za-z0-9]{10})(?:\.|$)",
            value,
        )
        if match:
            expanded.add(match.group(1))
    return expanded


def signing_values(
    run_dir: Path,
    structured_values: dict[str, Any] | None = None,
    captured_logs: dict[str, bytes] | None = None,
) -> set[str]:
    """Collect signing identities from logs and structured retained evidence."""
    values: set[str] = set()
    for name in ("configure-signing.log", "build.log"):
        if captured_logs is not None:
            raw = captured_logs.get(name)
            if raw is None:
                continue
            text = raw.decode("utf-8", errors="replace")
        else:
            path = run_dir / name
            if not regular_file(path):
                continue
            try:
                text = path.read_text(errors="replace")
            except OSError:
                continue
        values.update(
            re.findall(r"DEVELOPMENT_TEAM(?:\s*=|=)\s*([A-Za-z0-9]{10})", text)
        )
        for identifier in re.findall(
            r"^(?:appBundleIdentifier|uiTestBundleIdentifier)=([^\s]+)$",
            text,
            flags=re.MULTILINE,
        ):
            values.add(identifier)

    if structured_values is not None:
        for value in structured_values.values():
            values.update(bundle_identifier_values(value))
    else:
        structured_paths = [run_dir / name for name in JSON_FILES]
        structured_paths.extend(sorted((run_dir / "evidence").glob("*.json")))
        for path in structured_paths:
            if not regular_file(path):
                continue
            try:
                values.update(bundle_identifier_values(json.loads(path.read_bytes())))
            except (OSError, UnicodeError, json.JSONDecodeError):
                # Secret discovery is best-effort. The collection pass decides
                # whether malformed evidence can be included.
                continue
    return expand_signing_values(values)


class RunSnapshot:
    def __init__(
        self,
        *,
        scenarios: list[dict[str, Any]],
        complete: bool,
        report_bytes: bytes | None,
        plan_bytes: bytes | None,
        report: dict[str, Any] | None,
        plan: dict[str, Any] | None,
        warnings: tuple[str, ...],
    ) -> None:
        self.scenarios = scenarios
        self.complete = complete
        self.report_bytes = report_bytes
        self.plan_bytes = plan_bytes
        self.report = report
        self.plan = plan
        self.warnings = warnings


def regular_file(path: Path) -> bool:
    return not path.is_symlink() and path.is_file()


def retained_json_object(
    path: Path, description: str
) -> tuple[dict[str, Any] | None, bytes | None, str | None]:
    if path.is_symlink():
        return None, None, f"{description} is a symbolic link and was ignored"
    if not path.is_file():
        return None, None, f"{description} is missing"
    try:
        raw = path.read_bytes()
        value = report_validation.json_object(raw, description)
    except (
        OSError,
        UnicodeError,
        json.JSONDecodeError,
        report_validation.ReportValidationError,
    ) as error:
        return None, None, f"{description} is malformed or unreadable ({error})"
    return value, raw, None


def progress_scenarios(run_dir: Path) -> list[dict[str, Any]]:
    scenarios: list[dict[str, Any]] = []
    progress = run_dir / "scenario-results.tsv"
    if regular_file(progress):
        progress_text = progress.read_text(errors="replace")
        progress_lines = progress_text.splitlines()
        if progress_text and not progress_text.endswith(("\n", "\r")):
            # append(2) is not atomic across a killed writer. Never promote an
            # unterminated final row, even when it happens to have seven tabs.
            progress_lines = progress_lines[:-1]
        for line in progress_lines:
            fields = line.split("\t")
            if len(fields) not in {7, 11}:
                continue
            scenario, result, exit_code, errors, app_log, evidence, duration = fields[
                :7
            ]
            try:
                parsed_exit_code = int(exit_code)
                parsed_errors = int(errors)
                parsed_duration = int(duration)
            except ValueError:
                # A terminated writer can leave an incomplete final line. Keep
                # all earlier completed scenarios useful instead of rejecting
                # the entire interrupted-run package.
                continue
            scenarios.append(
                {
                    "scenario": scenario,
                    "result": result,
                    "xcodebuildExitCode": parsed_exit_code,
                    "libraryErrorCount": parsed_errors,
                    "appLog": app_log,
                    "qualificationEvidence": evidence,
                    "durationSeconds": parsed_duration,
                }
            )
    return scenarios


def capture_run_snapshot(run_dir: Path) -> RunSnapshot:
    warnings: list[str] = []
    report, report_bytes, report_error = retained_json_object(
        run_dir / report_validation.REPORT_FILENAME, "validated report"
    )
    plan, plan_bytes, plan_error = retained_json_object(
        run_dir / report_validation.PLAN_FILENAME, "validation plan"
    )
    if report_error:
        warnings.append(report_error)
    if plan_error:
        warnings.append(plan_error)

    scenarios: list[dict[str, Any]]
    if report is not None and isinstance(report.get("scenarios"), list):
        scenarios = [row for row in report["scenarios"] if isinstance(row, dict)]
    else:
        scenarios = progress_scenarios(run_dir)

    contract_valid = False
    if report is not None and plan is not None:
        try:
            report_validation.validate_plan_report_contract(report, plan)
            contract_valid = True
        except report_validation.ReportValidationError as error:
            warnings.append(f"report/plan contract mismatch ({error})")

    complete = bool(
        contract_valid
        and report_bytes is not None
        and plan_bytes is not None
        and report_validation.is_valid(run_dir, report_bytes, plan_bytes)
    )
    if contract_valid and not complete:
        warnings.append(
            "the report and validation plan have no matching successful-validation receipt"
        )
    return RunSnapshot(
        scenarios=scenarios,
        complete=complete,
        report_bytes=report_bytes if report is not None else None,
        plan_bytes=plan_bytes if plan is not None else None,
        report=report,
        plan=plan,
        warnings=tuple(warnings),
    )


def scenario_snapshot(
    run_dir: Path,
) -> tuple[list[dict[str, Any]], bool, bytes | None]:
    snapshot = capture_run_snapshot(run_dir)
    return snapshot.scenarios, snapshot.complete, snapshot.report_bytes


def read_scenarios(run_dir: Path) -> tuple[list[dict[str, Any]], bool]:
    snapshot = capture_run_snapshot(run_dir)
    return snapshot.scenarios, snapshot.complete


def device_summary(run_dir: Path) -> dict[str, Any]:
    path = run_dir / "device.json"
    if not regular_file(path):
        return {}
    try:
        root = json.loads(path.read_bytes())
    except (OSError, UnicodeError, json.JSONDecodeError):
        return {}
    value = root.get("selected") or {} if isinstance(root, dict) else {}
    if not isinstance(value, dict):
        return {}
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


def failure_reasons(
    run_dir: Path,
    scenarios: list[dict[str, Any]],
    captured_logs: dict[str, bytes] | None = None,
) -> list[dict[str, Any]]:
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
        if captured_logs is not None:
            raw = captured_logs.get(log_path.name)
            lines = (
                raw.decode("utf-8", errors="replace").splitlines()
                if raw is not None
                else []
            )
        elif regular_file(log_path):
            try:
                lines = log_path.read_text(errors="replace").splitlines()
            except OSError:
                lines = []
        else:
            lines = []
        for line in lines:
            candidate = line.strip()
            if pattern.search(candidate) and candidate not in reasons:
                reasons.append(candidate[:500])
        reasons = reasons[-3:]
        results.append(
            {
                "scenario": scenario,
                "reasons": reasons
                or ["No concise failure line was found; see the included log."],
            }
        )
    return results


def summary_markdown(
    run_dir: Path,
    scenarios: list[dict[str, Any]],
    complete: bool,
    *,
    plan: dict[str, Any] | None = None,
    report: dict[str, Any] | None = None,
    device: dict[str, Any] | None = None,
    warnings: tuple[str, ...] = (),
    failures: list[dict[str, Any]] | None = None,
) -> str:
    device = device if device is not None else device_summary(run_dir)
    plan = plan or {}
    report = report or {}
    passed = sum(row.get("result") == "pass" for row in scenarios)
    failed = sum(row.get("result") != "pass" for row in scenarios)
    planned = len(plan.get("selectedScenarioDrivers", []))
    selection_scope = plan.get("selectionScope")
    report_only = plan.get("reportOnly", report.get("reportOnly")) is True
    mode = plan.get("mode", report.get("mode"))
    qualification_eligible = (
        plan.get(
            "qualificationEligibleEnvironment",
            report.get("qualificationEligibleEnvironment"),
        )
        is True
    )

    if selection_scope == "full":
        scope_label = "FULL APPLICABLE DEVICE SUITE"
    elif selection_scope == "partial":
        scope_label = "PARTIAL / TARGETED — NOT A COMPLETE RELEASE CHECKLIST"
    else:
        scope_label = "UNKNOWN — NOT A COMPLETE RELEASE CHECKLIST"

    if report_only:
        evidence_label = "REPORT-ONLY — NOT RELEASE-QUALIFYING"
        release_qualifying = False
    elif mode != "qualification" or not qualification_eligible:
        evidence_label = "EXPLORATORY — NOT RELEASE-QUALIFYING"
        release_qualifying = False
    else:
        evidence_label = "QUALIFYING DEVICE ENVIRONMENT"
        release_qualifying = True

    state = "COMPLETE" if complete else "INCOMPLETE / INTERRUPTED"
    overall = "PASS" if complete and scenarios and failed == 0 else "FAIL"
    if not complete:
        overall = "INCOMPLETE"
    elif not release_qualifying:
        overall = f"{overall} — NOT RELEASE-QUALIFYING"
    elif selection_scope != "full":
        overall = f"{overall} — PARTIAL SCOPE"
    lines = [
        "# SwiftVLC physical-device validation",
        "",
        f"- Report state: **{state}**",
        f"- Result: **{overall}**",
        f"- Device checklist scope: **{scope_label}**",
        f"- Evidence class: **{evidence_label}**",
        f"- Completed scenarios: **{len(scenarios)}** ({passed} passed, {failed} failed)",
    ]
    if planned:
        lines.append(f"- Planned scenario drivers: **{planned}**")
        if len(scenarios) < planned:
            lines.append(
                f"- Unfinished scenario drivers: **{planned - len(scenarios)}**"
            )
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
    if selection_scope == "full" and release_qualifying:
        lines.append(
            "- Release meaning: **ONE FULL DEVICE CHECKLIST; THE MULTI-DEVICE MATRIX IS STILL REQUIRED**"
        )
    if warnings:
        lines.extend(["", "## Integrity warnings", ""])
        for warning in warnings:
            lines.append(f"- {warning}")
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
    failures = failure_reasons(run_dir, scenarios) if failures is None else failures
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


def capture_structured_values(
    run_dir: Path, snapshot: RunSnapshot
) -> tuple[dict[str, Any], list[str], bool]:
    """Capture each structured file once before deriving completion or secrets."""

    values: dict[str, Any] = {}
    raw_digests: dict[str, str] = {}
    warnings: list[str] = []
    if snapshot.report is not None:
        values[report_validation.REPORT_FILENAME] = snapshot.report
    if snapshot.plan is not None:
        values[report_validation.PLAN_FILENAME] = snapshot.plan
    required_names = {"device.json"}
    if snapshot.complete:
        required_names.update(
            {
                "candidate-metadata.json",
                "fixture-manifest.json",
                report_validation.EVIDENCE_MANIFEST_FILENAME,
            }
        )

    for name in JSON_FILES:
        if name in values or name in {
            report_validation.REPORT_FILENAME,
            report_validation.PLAN_FILENAME,
        }:
            continue
        source = run_dir / name
        if source.is_symlink():
            warnings.append(f"{name} is a symbolic link and was omitted")
            continue
        if not source.is_file():
            if name in required_names:
                warnings.append(f"{name} is missing")
            continue
        try:
            raw = source.read_bytes()
            value = report_validation.json_object(raw, name)
        except (
            OSError,
            UnicodeError,
            json.JSONDecodeError,
            report_validation.ReportValidationError,
        ) as error:
            warnings.append(f"{name} is malformed or unreadable ({error})")
            continue
        values[name] = value
        raw_digests[name] = hashlib.sha256(raw).hexdigest()

    if snapshot.report is not None:
        candidate = values.get("candidate-metadata.json")
        if isinstance(candidate, dict) and any(
            key not in snapshot.report or snapshot.report[key] != value
            for key, value in candidate.items()
        ):
            warnings.append(
                "candidate-metadata.json no longer matches the validated report identity"
            )
        device = values.get("device.json")
        if (
            isinstance(device, dict)
            and "device" in snapshot.report
            and device.get("selected") != snapshot.report.get("device")
        ):
            warnings.append(
                "device.json no longer matches the validated report device snapshot"
            )
        expected_fixture_digest = snapshot.report.get("fixtureManifestChecksum")
        if (
            isinstance(expected_fixture_digest, str)
            and raw_digests.get("fixture-manifest.json") != expected_fixture_digest
        ):
            warnings.append(
                "fixture-manifest.json no longer matches the validated report checksum"
            )

    device = values.get("device.json")
    diagnostics_safe = bool(
        isinstance(device, dict) and isinstance(device.get("selected"), dict)
    )
    if isinstance(device, dict) and not isinstance(device.get("selected"), dict):
        warnings.append("device.json has no usable selected-device object")
    if not diagnostics_safe:
        warnings.append(
            "diagnostic logs and evidence were omitted because device identity metadata could not be safely decoded"
        )
    return values, warnings, diagnostics_safe


def capture_evidence_values(
    run_dir: Path, *, include_diagnostics: bool
) -> tuple[dict[str, dict[str, Any]], list[str]]:
    values: dict[str, dict[str, Any]] = {}
    warnings: list[str] = []
    if not include_diagnostics:
        return values, warnings
    evidence_root = run_dir / "evidence"
    if evidence_root.is_symlink():
        return values, ["evidence directory is a symbolic link and was omitted"]
    for source in sorted(evidence_root.glob("*.json")):
        if source.is_symlink():
            warnings.append(f"evidence/{source.name} is a symbolic link and was omitted")
            continue
        if not source.is_file():
            continue
        try:
            description = f"evidence/{source.name}"
            value = report_validation.json_object(source.read_bytes(), description)
        except (
            OSError,
            UnicodeError,
            json.JSONDecodeError,
            report_validation.ReportValidationError,
        ) as error:
            warnings.append(
                f"evidence/{source.name} is malformed or unreadable ({error})"
            )
            continue
        values[source.name] = value
    return values, warnings


def capture_text_logs(
    run_dir: Path, *, include_diagnostics: bool
) -> tuple[dict[str, bytes], list[str]]:
    values: dict[str, bytes] = {}
    warnings: list[str] = []
    seen: set[Path] = set()
    patterns = TEXT_LOG_PATTERNS if include_diagnostics else ("scenario-results.tsv",)
    for pattern in patterns:
        for source in sorted(run_dir.glob(pattern)):
            if source in seen:
                continue
            seen.add(source)
            if source.is_symlink():
                warnings.append(f"{source.name} is a symbolic link and was omitted")
                continue
            if not source.is_file():
                continue
            try:
                values[source.name] = source.read_bytes()
            except OSError as error:
                warnings.append(f"{source.name} is unreadable ({error})")
    return values, warnings


def collect_files(
    run_dir: Path,
    staging: Path,
    secrets: set[str],
    structured_values: dict[str, Any],
    *,
    evidence_values: dict[str, dict[str, Any]],
    captured_logs: dict[str, bytes],
) -> list[str]:
    for name in JSON_FILES:
        if name not in structured_values:
            continue
        report_validation.atomic_write_json(
            staging / name, sanitize_json(structured_values[name], secrets)
        )

    if evidence_values:
        evidence_destination = staging / "evidence"
        evidence_destination.mkdir(exist_ok=True)
        for name, value in sorted(evidence_values.items()):
            report_validation.atomic_write_json(
                evidence_destination / name,
                sanitize_json(value, secrets),
            )

    logs_destination = staging / "logs"
    if captured_logs:
        logs_destination.mkdir(exist_ok=True)
    for name, raw in sorted(captured_logs.items()):
        suffix = ""
        if len(raw) > MAX_LOG_BYTES:
            raw = raw[-MAX_LOG_BYTES:]
            suffix = "[Earlier log content omitted from share report.]\n"
        text = suffix + raw.decode("utf-8", errors="replace")
        (logs_destination / name).write_text(scrub_text(text, secrets))
    return []


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
    snapshot = capture_run_snapshot(run_dir)
    structured_values, structured_warnings, diagnostics_safe = (
        capture_structured_values(run_dir, snapshot)
    )
    evidence_values, evidence_warnings = capture_evidence_values(
        run_dir, include_diagnostics=diagnostics_safe
    )
    captured_logs, log_warnings = capture_text_logs(
        run_dir, include_diagnostics=diagnostics_safe
    )
    device_value = structured_values.get("device.json", {})
    signing_structured_values = {
        **structured_values,
        **{f"evidence/{name}": value for name, value in evidence_values.items()},
    }
    secrets = sensitive_values(device_value) | signing_values(
        run_dir, signing_structured_values, captured_logs
    )

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="swiftvlc-share-report.") as temporary:
        staging = Path(temporary) / "SwiftVLC-Device-Report"
        staging.mkdir()
        collection_warnings = collect_files(
            run_dir,
            staging,
            secrets,
            structured_values,
            evidence_values=evidence_values,
            captured_logs=captured_logs,
        )
        warnings = tuple(
            dict.fromkeys(
                (
                    *snapshot.warnings,
                    *structured_warnings,
                    *evidence_warnings,
                    *log_warnings,
                    *collection_warnings,
                )
            )
        )
        complete = snapshot.complete and not warnings
        failures = sanitize_json(
            (
                failure_reasons(run_dir, snapshot.scenarios, captured_logs)
                if diagnostics_safe
                else []
            ),
            secrets,
        )
        report_validation.atomic_write_json(staging / "failure-reasons.json", failures)
        selected_device = (
            device_value.get("selected", {})
            if isinstance(device_value, dict)
            else {}
        )
        device = {
            key: selected_device[key]
            for key in (
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
            if isinstance(selected_device, dict) and key in selected_device
        }
        (staging / "SUMMARY.md").write_text(
            scrub_text(
                summary_markdown(
                    run_dir,
                    snapshot.scenarios,
                    complete,
                    plan=snapshot.plan,
                    report=snapshot.report,
                    device=device,
                    warnings=warnings,
                    failures=failures,
                ),
                secrets,
            )
        )
        write_manifest(staging)
        descriptor, staged_output_name = tempfile.mkstemp(
            prefix=f".{output.name}.", suffix=".tmp", dir=output.parent
        )
        os.close(descriptor)
        staged_output = Path(staged_output_name)
        try:
            with zipfile.ZipFile(
                staged_output, "w", compression=zipfile.ZIP_DEFLATED
            ) as archive:
                for path in sorted(staging.rglob("*")):
                    if path.is_file():
                        archive.write(path, path.relative_to(staging.parent))
            if staged_output.stat().st_size > MAX_ARCHIVE_BYTES:
                raise ValueError("share report exceeded the 24 MiB GitHub upload budget")
            os.replace(staged_output, output)
        finally:
            staged_output.unlink(missing_ok=True)
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
