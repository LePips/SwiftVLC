#!/usr/bin/env bash
#
# check-qualification.sh — refuse to release an xcframework whose physical-device
# qualification is missing, stale, or incomplete.
#
# Issue 88: simulator and wrapper-only coverage cannot validate system PiP,
# native video output, audio teardown, or real libVLC playback. CI compiles the
# iOS tests but never executes system PiP on hardware, and the sanitizer job
# links a released xcframework rather than the engine under test. So the device
# matrix is the acceptance gate, and nothing enforced it.
#
# This does not run the tests — a person does, on hardware. What it enforces is
# that the results exist, that every required row was executed and passed, and
# that they describe *this* artifact rather than an earlier one.
#
# The artifact is identified by a digest over the complete XCFramework tree,
# including libraries, headers, metadata, paths, and modes. Header/ABI drift is
# release-significant even when the static archive bytes are unchanged.
#
# Usage:
#   ./scripts/check-qualification.sh <version> [xcframework-path]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

VERSION="${1:-}"
XCFW="${2:-Vendor/libvlc.xcframework}"
MATRIX="${SWIFTVLC_QUALIFICATION_MATRIX:-$SCRIPT_DIR/qualification/matrix.json}"
RECORD="${SWIFTVLC_QUALIFICATION_RECORD:-$SCRIPT_DIR/qualification/${VERSION}.json}"

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version> [xcframework-path]" >&2
  exit 2
fi

if [[ ! -d "$XCFW" ]]; then
  echo "Error: $XCFW not found." >&2
  exit 1
fi

if [[ ! -f "$MATRIX" ]]; then
  echo "Error: $MATRIX not found; the required rows are undefined." >&2
  exit 1
fi

artifact_digest() {
  python3 "$SCRIPT_DIR/artifact-tree-digest.py" "$XCFW"
}

# An xcframework with no static libraries would still produce a stable digest —
# shasum of empty input — so a record could be written that "qualifies" an
# artifact containing nothing. Refuse before computing anything.
SLICE_COUNT=$(find "$XCFW" -name '*.a' -type f | grep -c . || true)
if [[ "$SLICE_COUNT" -eq 0 ]]; then
  echo "Error: $XCFW contains no static libraries." >&2
  echo "  Nothing to qualify. Rebuild with ./scripts/build-libvlc.sh --all." >&2
  exit 1
fi

DIGEST="$(artifact_digest)"

if [[ ! -f "$RECORD" ]]; then
  echo "Error: no device qualification record for $VERSION." >&2
  echo "  Expected: $RECORD" >&2
  echo "  Artifact digest: $DIGEST" >&2
  echo "" >&2
  echo "  The device matrix is the acceptance gate for system PiP; CI cannot" >&2
  echo "  stand in for it. Run the matrix on hardware and record the results," >&2
  echo "  then release. See scripts/qualification/README.md." >&2
  exit 1
fi

python3 - "$MATRIX" "$RECORD" "$DIGEST" "$VERSION" <<'PY'
import json
import math
import sys
from pathlib import Path

matrix_path, record_path, digest, version = sys.argv[1:5]

try:
    matrix = json.load(open(matrix_path))
    record = json.load(open(record_path))
except (OSError, ValueError) as error:
    sys.exit(f"Error: cannot read qualification input: {error}")

problems = []

recorded = record.get("artifactDigest")
if recorded != digest:
    problems.append(
        "the record describes a different artifact\n"
        f"    recorded:   {recorded}\n"
        f"    on disk:    {digest}\n"
        "    A device run only qualifies the binary it was run against. Rebuild\n"
        "    or re-run the matrix, whichever is actually stale."
    )

if record.get("version") != version:
    problems.append(
        f"the record is for version {record.get('version')!r}, not {version!r}"
    )

if record.get("artifactDigestAlgorithm") != "swiftvlc-tree-v1":
    problems.append(
        "the record does not declare artifactDigestAlgorithm "
        "'swiftvlc-tree-v1'"
    )

scenarios = matrix.get("scenarios")
hardware_rows = matrix.get("hardware")
if not isinstance(scenarios, list) or not isinstance(hardware_rows, list):
    sys.exit("Error: qualification matrix needs 'scenarios' and 'hardware' arrays.")

if any(
    not isinstance(scenario, dict) or not isinstance(scenario.get("id"), str)
    for scenario in scenarios
):
    sys.exit("Error: every qualification scenario needs a string 'id'.")
if any(
    not isinstance(hardware, dict) or not isinstance(hardware.get("id"), str)
    for hardware in hardware_rows
):
    sys.exit("Error: every qualification hardware row needs a string 'id'.")

scenario_by_id = {scenario["id"]: scenario for scenario in scenarios}
hardware_by_id = {hardware["id"]: hardware for hardware in hardware_rows}
if len(scenario_by_id) != len(scenarios):
    sys.exit("Error: qualification matrix contains duplicate scenario ids.")
if len(hardware_by_id) != len(hardware_rows):
    sys.exit("Error: qualification matrix contains duplicate hardware ids.")

required = set()
for scenario in scenarios:
    required_evidence = scenario.get("requiredEvidenceFields", [])
    if (
        not isinstance(required_evidence, list)
        or any(not isinstance(field, str) or not field for field in required_evidence)
    ):
        sys.exit(
            f"Error: scenario {scenario['id']!r} has invalid required evidence fields."
        )
    expected_evidence = scenario.get("expectedEvidenceValues", {})
    if not isinstance(expected_evidence, dict):
        sys.exit(
            f"Error: scenario {scenario['id']!r} has invalid expected evidence values."
        )
    allowed_evidence = scenario.get("allowedEvidenceValues", {})
    if (
        not isinstance(allowed_evidence, dict)
        or any(
            not isinstance(field, str)
            or not field
            or not isinstance(allowed, list)
            or not allowed
            for field, allowed in allowed_evidence.items()
        )
    ):
        sys.exit(
            f"Error: scenario {scenario['id']!r} has invalid allowed evidence values."
        )
    selected_hardware = scenario.get("hardware", list(hardware_by_id))
    if not isinstance(selected_hardware, list) or not selected_hardware:
        sys.exit(
            f"Error: scenario {scenario['id']!r} has an empty or invalid hardware list."
        )
    unknown = sorted(set(selected_hardware) - set(hardware_by_id))
    if unknown:
        sys.exit(
            f"Error: scenario {scenario['id']!r} names unknown hardware: "
            + ", ".join(unknown)
        )
    required.update((scenario["id"], hardware_id) for hardware_id in selected_hardware)

rows = record.get("rows")
if not isinstance(rows, list):
    sys.exit(f"Error: {record_path} has no 'rows' array.")

executed = {}
duplicates = []
for index, row in enumerate(rows):
    if not isinstance(row, dict):
        problems.append(f"row {index} is not an object")
        continue
    key = (row.get("scenario"), row.get("hardware"))
    if key in executed:
        # Last-wins would let a failing row be masked by appending a passing
        # duplicate, which defeats the point of the gate.
        duplicates.append(key)
    executed[key] = row

if duplicates:
    listed = "\n".join(f"      {s} on {h}" for s, h in sorted(set(duplicates)))
    problems.append(
        f"{len(set(duplicates))} row(s) appear more than once:\n{listed}\n"
        "    A duplicate can hide an earlier failure behind a later pass."
    )

missing = sorted(required - set(executed))
if missing:
    listed = "\n".join(f"      {s} on {h}" for s, h in missing)
    problems.append(f"{len(missing)} required row(s) were never executed:\n{listed}")

failed = sorted(
    key for key, row in executed.items()
    if key in required and row.get("result") != "pass"
)
if failed:
    listed = "\n".join(
        f"      {s} on {h}: {executed[(s, h)].get('result')!r}" for s, h in failed
    )
    problems.append(f"{len(failed)} required row(s) did not pass:\n{listed}")

# Fields the criteria call for on every row. A row missing them is not a record
# of anything reproducible.
for key in sorted(executed):
    if key not in required:
        continue
    row = executed[key]
    for field in (
        "device",
        "deviceFamily",
        "productType",
        "osVersion",
        "osBuild",
        "osReleaseType",
        "fixture",
        "duration",
        "durationSeconds",
        "evidence",
        "result",
    ):
        if not row.get(field):
            problems.append(f"row {key[0]} on {key[1]} is missing {field!r}")

    hardware = hardware_by_id[key[1]]
    if row.get("deviceFamily") != hardware["deviceFamily"]:
        problems.append(
            f"row {key[0]} on {key[1]} records deviceFamily "
            f"{row.get('deviceFamily')!r}, expected {hardware['deviceFamily']!r}"
        )
    try:
        os_major = int(str(row.get("osVersion", "")).split(".", 1)[0])
    except ValueError:
        os_major = None
    if os_major != hardware["osMajor"]:
        problems.append(
            f"row {key[0]} on {key[1]} records OS {row.get('osVersion')!r}, "
            f"expected major version {hardware['osMajor']}"
        )
    if row.get("osReleaseType") != "stable":
        problems.append(
            f"row {key[0]} on {key[1]} uses {row.get('osReleaseType')!r} OS "
            "software; release qualification requires a stable OS build"
        )

    duration_seconds = row.get("durationSeconds")
    if (
        not isinstance(duration_seconds, (int, float))
        or isinstance(duration_seconds, bool)
    ):
        problems.append(
            f"row {key[0]} on {key[1]} durationSeconds must be a number"
        )
    elif not math.isfinite(duration_seconds):
        problems.append(
            f"row {key[0]} on {key[1]} durationSeconds must be finite"
        )
    elif duration_seconds <= 0:
        problems.append(
            f"row {key[0]} on {key[1]} durationSeconds must be positive"
        )
    else:
        minimum = scenario_by_id[key[0]].get("minimumDurationSeconds", 0)
        if duration_seconds < minimum:
            problems.append(
                f"row {key[0]} on {key[1]} ran for {duration_seconds:g}s, "
                f"below the required {minimum:g}s"
            )

    evidence = row.get("evidence")
    if evidence:
        evidence_path = Path(evidence)
        if evidence_path.is_absolute() or ".." in evidence_path.parts:
            problems.append(
                f"row {key[0]} on {key[1]} evidence must be a safe path "
                "relative to the qualification record"
            )
        elif not (Path(record_path).parent / evidence_path).is_file():
            problems.append(
                f"row {key[0]} on {key[1]} evidence file does not exist: "
                f"{evidence}"
            )
        else:
            resolved_evidence = Path(record_path).parent / evidence_path
            try:
                evidence_document = json.load(open(resolved_evidence))
            except (OSError, ValueError) as error:
                problems.append(
                    f"row {key[0]} on {key[1]} evidence is not valid JSON: {error}"
                )
                continue
            if not isinstance(evidence_document, dict):
                problems.append(
                    f"row {key[0]} on {key[1]} evidence must be a JSON object"
                )
                continue
            for field, expected in (
                ("artifactDigest", digest),
                ("scenario", key[0]),
                ("hardware", key[1]),
            ):
                if evidence_document.get(field) != expected:
                    problems.append(
                        f"row {key[0]} on {key[1]} evidence {field!r} is "
                        f"{evidence_document.get(field)!r}, expected {expected!r}"
                    )

            missing_marker = object()

            def nested_value(document, dotted_path):
                value = document
                for component in dotted_path.split("."):
                    if not isinstance(value, dict) or component not in value:
                        return missing_marker
                    value = value[component]
                return value

            def same_json_value(actual, expected):
                # Python's bool subclasses int, but JSON booleans and numbers
                # are different types. Compare recursively using JSON's type
                # model so false cannot satisfy 0, including inside arrays or
                # objects. Integers and floats remain one JSON number type.
                if isinstance(expected, bool):
                    return isinstance(actual, bool) and actual == expected
                if isinstance(expected, (int, float)):
                    return (
                        isinstance(actual, (int, float))
                        and not isinstance(actual, bool)
                        and actual == expected
                    )
                if expected is None:
                    return actual is None
                if isinstance(expected, str):
                    return isinstance(actual, str) and actual == expected
                if isinstance(expected, list):
                    return (
                        isinstance(actual, list)
                        and len(actual) == len(expected)
                        and all(
                            same_json_value(a, e)
                            for a, e in zip(actual, expected)
                        )
                    )
                if isinstance(expected, dict):
                    return (
                        isinstance(actual, dict)
                        and actual.keys() == expected.keys()
                        and all(
                            same_json_value(actual[field], expected[field])
                            for field in expected
                        )
                    )
                return type(actual) is type(expected) and actual == expected

            required_evidence = scenario_by_id[key[0]].get(
                "requiredEvidenceFields", []
            )
            for field in required_evidence:
                value = nested_value(evidence_document, field)
                if (
                    value is missing_marker
                    or value is None
                    or value == ""
                    or value == []
                    or value == {}
                ):
                    problems.append(
                        f"row {key[0]} on {key[1]} evidence is missing "
                        f"non-empty field {field!r}"
                    )

            expected_evidence = scenario_by_id[key[0]].get(
                "expectedEvidenceValues", {}
            )
            for field, expected in expected_evidence.items():
                value = nested_value(evidence_document, field)
                if value is missing_marker or not same_json_value(value, expected):
                    rendered = None if value is missing_marker else value
                    problems.append(
                        f"row {key[0]} on {key[1]} evidence field {field!r} "
                        f"is {rendered!r}, "
                        f"expected {expected!r}"
                    )

            allowed_evidence = scenario_by_id[key[0]].get(
                "allowedEvidenceValues", {}
            )
            for field, allowed in allowed_evidence.items():
                value = nested_value(evidence_document, field)
                if value is missing_marker or not any(
                    same_json_value(value, candidate) for candidate in allowed
                ):
                    rendered = None if value is missing_marker else value
                    problems.append(
                        f"row {key[0]} on {key[1]} evidence field {field!r} "
                        f"is {rendered!r}, "
                        f"expected one of {allowed!r}"
                    )

if problems:
    print(f"Error: {version} is not qualified for release.", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    sys.exit(1)

print(
    f"Device qualification verified: {len(required)} rows executed and passing "
    f"for artifact {digest[:12]}…"
)
PY
