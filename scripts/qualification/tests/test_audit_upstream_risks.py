from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest

QUALIFICATION = Path(__file__).resolve().parents[1]
SCRIPT = QUALIFICATION / "audit-upstream-risks.py"
SPEC = importlib.util.spec_from_file_location("audit_upstream_risks", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class UpstreamRiskAuditTests(unittest.TestCase):
    @staticmethod
    def risk() -> dict:
        return {
            "id": "vlckit-749-fixture",
            "sourceProject": "VLCKit",
            "sourceIssue": 749,
            "sourceStateAtReview": "open",
            "sourceURL": "https://code.videolan.org/videolan/VLCKit/-/work_items/749",
        }

    @staticmethod
    def response() -> dict:
        return {
            "iid": 749,
            "state": "opened",
            "title": "Fixture upstream issue",
            "web_url": "https://code.videolan.org/videolan/VLCKit/-/work_items/749",
        }

    def test_endpoint_uses_the_official_encoded_project_path(self) -> None:
        self.assertEqual(
            AUDIT.issue_endpoint("VLCKit", 749),
            "https://code.videolan.org/api/v4/projects/videolan%2FVLCKit/issues/749",
        )

    def test_matching_snapshot_passes(self) -> None:
        result, problems = AUDIT.compare_risk(self.risk(), self.response())
        self.assertEqual(problems, [])
        self.assertEqual(result["result"], "pass")
        self.assertEqual(result["currentState"], "open")

    def test_state_and_identity_drift_are_fail_closed(self) -> None:
        response = self.response()
        response.update(
            iid=750,
            state="closed",
            web_url="https://code.videolan.org/videolan/VLCKit/-/work_items/750",
        )
        result, problems = AUDIT.compare_risk(self.risk(), response)
        self.assertEqual(result["result"], "drift")
        self.assertEqual(len(problems), 3)

    def test_manifest_audit_uses_every_risk(self) -> None:
        second = {
            **self.risk(),
            "id": "vlc-29487-fixture",
            "sourceProject": "VLC",
            "sourceIssue": 29487,
            "sourceStateAtReview": "closed",
            "sourceURL": "https://code.videolan.org/videolan/vlc/-/work_items/29487",
        }
        calls: list[tuple[str, int, float]] = []

        def fetcher(project: str, issue: int, timeout: float) -> dict:
            calls.append((project, issue, timeout))
            project_path = "vlc" if project == "VLC" else "VLCKit"
            return {
                "iid": issue,
                "state": "closed" if project == "VLC" else "opened",
                "title": "Fixture upstream issue",
                "web_url": (
                    f"https://code.videolan.org/videolan/{project_path}/-/work_items/{issue}"
                ),
            }

        manifest = {"upstreamRiskReview": {"risks": [self.risk(), second]}}
        results, problems = AUDIT.audit_manifest(manifest, timeout=3.0, fetcher=fetcher)

        self.assertEqual(problems, [])
        self.assertEqual(len(results), 2)
        self.assertEqual(
            calls,
            [("VLCKit", 749, 3.0), ("VLC", 29487, 3.0)],
        )


if __name__ == "__main__":
    unittest.main()
