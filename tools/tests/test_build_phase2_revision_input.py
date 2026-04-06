import json
import tempfile
import unittest
from pathlib import Path

from tools.bin.build_phase2_revision_input import build_revision_input


class BuildPhase2RevisionInputTests(unittest.TestCase):
    def test_groups_review_packets_by_parent_finding(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports" / "phase2"
            reports.mkdir(parents=True)

            worker = reports / "demo-phase2.worker.r1.json"
            review = reports / "demo-phase2.review.r1.json"
            out = reports / "demo-phase2.worker.r2.revision.input.json"

            worker.write_text(
                json.dumps(
                    {
                        "plugin_slug": "demo",
                        "analysis_summary": "summary",
                        "overall_risk": "low",
                        "total_findings_analyzed": 2,
                        "true_positives": 1,
                        "false_positives": 1,
                        "needs_review": 0,
                        "findings": [
                            {
                                "finding_id": "F-1",
                                "verdict": "TP",
                                "vuln_type": "BAC",
                                "source_file_path": "a.php",
                                "source_line_number": 10,
                                "sink_file_path": "a.php",
                                "sink_line_number": 20,
                                "file_path": "a.php",
                                "line_number": 20,
                                "reasoning": {
                                    "hypothesis": "h1",
                                    "trace": "t1",
                                    "conclusion": "c1",
                                },
                            },
                            {
                                "finding_id": "F-2",
                                "verdict": "FP",
                                "vuln_type": "XSS",
                                "source_file_path": "b.php",
                                "source_line_number": 30,
                                "sink_file_path": "b.php",
                                "sink_line_number": 40,
                                "reasoning": {"hypothesis": "h2"},
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )

            review.write_text(
                json.dumps(
                    {
                        "plugin_slug": "demo",
                        "review_status": "needs_revision",
                        "summary": {"notes": "revise"},
                        "finding_reviews": [
                            {
                                "finding_id": "F-1",
                                "packet_id": "F-1__p01",
                                "parent_finding_id": "F-1",
                                "assessment": "field_fix",
                                "reason": "adjust entry point",
                                "required_changes": ["change anchor"],
                                "counter_evidence": [
                                    {"type": "scope", "file": "a.php", "line": 12, "detail": "scope"}
                                ],
                                "missing_evidence": [],
                                "expansion_attempts": [],
                                "suggested_field_corrections": {"sink_anchor": "a.php:22"},
                            },
                            {
                                "finding_id": "F-1",
                                "packet_id": "F-1__p02",
                                "parent_finding_id": "F-1",
                                "assessment": "needs_more_evidence",
                                "reason": "need terminal sink",
                                "required_changes": ["find sink"],
                                "counter_evidence": [],
                                "missing_evidence": ["terminal sink"],
                                "expansion_attempts": [],
                                "suggested_field_corrections": {},
                            },
                        ],
                        "missed_findings": [],
                    }
                ),
                encoding="utf-8",
            )

            payload = build_revision_input(
                root=root,
                slug="demo",
                review_round=1,
                worker_mode="revision",
                previous_worker_output_path=worker,
                review_output_path=review,
                output_path=out,
            )

            self.assertEqual(payload["plugin_slug"], "demo")
            self.assertEqual(payload["worker_round"], 2)
            self.assertEqual(len(payload["revision_targets"]), 1)
            target = payload["revision_targets"][0]
            self.assertEqual(target["finding_id"], "F-1")
            self.assertEqual(target["review_feedback"]["packet_count"], 2)
            self.assertEqual(target["review_feedback"]["aggregate_assessment"], "needs_more_evidence")
            self.assertIn("a.php", target["source_scope_files"])
            self.assertEqual(payload["untouched_finding_ids"], ["F-2"])
            self.assertTrue(out.exists())


if __name__ == "__main__":
    unittest.main()
