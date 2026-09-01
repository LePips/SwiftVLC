#!/usr/bin/env python3
"""Compare the feature manifest's upstream risk snapshot with VideoLAN.

This is a release-review aid, not candidate evidence. It deliberately uses the
official GitLab API and fails on state or identity drift so a reviewer must
read the changed issue before refreshing the manifest's review date.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

sys.path.insert(0, str(Path(__file__).resolve().parent))
import qualification_policy as policy

API_ROOT = "https://code.videolan.org/api/v4/projects"
PROJECT_PATHS = {
    "VLC": "videolan/vlc",
    "VLCKit": "videolan/VLCKit",
}
STATE_FROM_API = {
    "opened": "open",
    "closed": "closed",
}


class AuditError(ValueError):
    pass


def issue_endpoint(project: str, issue: int) -> str:
    try:
        project_path = PROJECT_PATHS[project]
    except KeyError as error:
        raise AuditError(f"unsupported VideoLAN project {project!r}") from error
    if isinstance(issue, bool) or not isinstance(issue, int) or issue <= 0:
        raise AuditError("issue must be a positive integer")
    return f"{API_ROOT}/{quote(project_path, safe='')}/issues/{issue}"


def fetch_issue(project: str, issue: int, timeout: float) -> dict:
    request = Request(
        issue_endpoint(project, issue),
        headers={"User-Agent": "SwiftVLC-upstream-risk-audit/1"},
    )
    try:
        with urlopen(request, timeout=timeout) as response:
            payload = json.load(response)
    except (HTTPError, URLError, TimeoutError, ValueError) as error:
        raise AuditError(f"cannot fetch {project} #{issue}: {error}") from error
    if not isinstance(payload, dict):
        raise AuditError(f"{project} #{issue} returned a non-object response")
    return payload


def compare_risk(risk: dict, payload: dict) -> tuple[dict, list[str]]:
    risk_id = risk.get("id", "<missing-id>")
    project = risk.get("sourceProject")
    issue = risk.get("sourceIssue")
    problems: list[str] = []

    if payload.get("iid") != issue:
        problems.append(
            f"{risk_id}: API iid is {payload.get('iid')!r}, expected {issue!r}"
        )
    api_state = STATE_FROM_API.get(payload.get("state"))
    if api_state is None:
        problems.append(
            f"{risk_id}: API returned unsupported state {payload.get('state')!r}"
        )
    elif api_state != risk.get("sourceStateAtReview"):
        problems.append(
            f"{risk_id}: state changed from {risk.get('sourceStateAtReview')!r} "
            f"to {api_state!r}"
        )
    if payload.get("web_url") != risk.get("sourceURL"):
        problems.append(
            f"{risk_id}: URL changed from {risk.get('sourceURL')!r} "
            f"to {payload.get('web_url')!r}"
        )
    title = payload.get("title")
    if not isinstance(title, str) or not title.strip():
        problems.append(f"{risk_id}: API returned no issue title")

    return (
        {
            "id": risk_id,
            "sourceProject": project,
            "sourceIssue": issue,
            "recordedState": risk.get("sourceStateAtReview"),
            "currentState": api_state,
            "currentTitle": title,
            "currentURL": payload.get("web_url"),
            "result": "pass" if not problems else "drift",
        },
        problems,
    )


def audit_manifest(
    manifest: dict,
    *,
    timeout: float,
    fetcher: Callable[[str, int, float], dict] = fetch_issue,
) -> tuple[list[dict], list[str]]:
    review = manifest.get("upstreamRiskReview")
    if not isinstance(review, dict):
        raise AuditError("manifest has no upstreamRiskReview object")
    risks = review.get("risks")
    if not isinstance(risks, list) or not risks:
        raise AuditError("upstreamRiskReview has no risks")

    results: list[dict] = []
    problems: list[str] = []
    for risk in risks:
        if not isinstance(risk, dict):
            raise AuditError("upstream risk rows must be objects")
        project = risk.get("sourceProject")
        issue = risk.get("sourceIssue")
        payload = fetcher(project, issue, timeout)
        result, row_problems = compare_risk(risk, payload)
        results.append(result)
        problems.extend(row_problems)
    return results, problems


def main() -> int:
    script_directory = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Audit the recorded upstream risk snapshot against VideoLAN."
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=script_directory / "feature-manifest-v1.json",
    )
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--json", action="store_true", dest="as_json")
    arguments = parser.parse_args()

    if not 0 < arguments.timeout <= 120:
        print(
            "Error: --timeout must be greater than 0 and at most 120", file=sys.stderr
        )
        return 2
    try:
        manifest = policy.load_json(arguments.manifest, "feature manifest")
        results, problems = audit_manifest(manifest, timeout=arguments.timeout)
    except (OSError, ValueError, AuditError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2

    if arguments.as_json:
        print(
            json.dumps(
                {
                    "reviewedOn": manifest["upstreamRiskReview"].get("reviewedOn"),
                    "results": results,
                    "problems": problems,
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        for result in results:
            print(
                f"{result['result'].upper():5} "
                f"{result['sourceProject']} #{result['sourceIssue']}: "
                f"{result['currentState']} — {result['currentTitle']}"
            )
        for problem in problems:
            print(f"DRIFT {problem}", file=sys.stderr)

    if problems:
        return 1
    if not arguments.as_json:
        print(f"Upstream risk snapshot matches {len(results)} official issue records.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
