import json
import tempfile
import unittest
from pathlib import Path

from tools.bin.build_phase2_reviewer_input import build_reviewer_input
from tools.bin.build_phase2_reviewer_batches import build_reviewer_batches
from tools.bin.merge_phase2_reviewer_batches import merge_reviewer_batches


class Phase2ReviewerBatchTests(unittest.TestCase):
    def test_build_and_merge_reviewer_core_batches(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "contracts").mkdir(parents=True)
            plugin_dir = root / "plugins" / "demo"
            plugin_dir.mkdir(parents=True)
            repo_root = Path(__file__).resolve().parents[2]
            for name in (
                "phase2-reviewer-input.schema.json",
                "phase2-reviewer-packet.schema.json",
                "phase2-review-core-output.schema.json",
                "phase2-review-explore-output.schema.json",
                "phase2-review-batch-plan.schema.json",
            ):
                src = repo_root / "contracts" / name
                (root / "contracts" / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

            for rel_path in (
                "routes.php",
                "handler.php",
                "webhook.php",
                "survey.php",
                "wc.php",
            ):
                file_path = plugin_dir / rel_path
                file_path.write_text(
                    "\n".join(f"<?php // {rel_path} line {line}" for line in range(1, 121)) + "\n",
                    encoding="utf-8",
                )

            reports = root / "reports"
            phase1 = reports / "phase1"
            phase2 = reports / "phase2"
            phase1.mkdir(parents=True)
            phase2.mkdir(parents=True)

            (phase1 / "demo-ir.json").write_text(
                json.dumps(
                    {
                        "entry_points": [
                            {"id": "ep_integrations", "type": "rest", "hook_name": "/integrations", "auth_level": "admin", "file": "routes.php", "line": 11, "callback": {"name": "integrations", "class": None}},
                            {"id": "ep_contact", "type": "rest", "hook_name": "/contact", "auth_level": "none", "file": "handler.php", "line": 21, "callback": {"name": "contact", "class": None}},
                            {"id": "ep_init", "type": "init", "hook_name": "init", "auth_level": "none", "file": "survey.php", "line": 31, "callback": {"name": "survey", "class": None}},
                            {"id": "ep_import", "type": "rest", "hook_name": "/import", "auth_level": "admin", "file": "wc.php", "line": 41, "callback": {"name": "import", "class": None}},
                        ],
                        "anomalies": [
                            {"id": "anom_1", "type": "rest_return_true", "severity": "high", "entry_point_id": "ep_contact", "description": "contact anomaly", "evidence": {"file": "handler.php", "line": 22}}
                        ],
                        "unresolved_hooks": [{"file": "webhook.php", "line": 19, "function": "add_action", "hook_arg_type": "concatenation"}],
                    }
                ),
                encoding="utf-8",
            )

            worker_output = phase2 / "demo-phase2.worker.r1.json"
            worker_output.write_text(
                json.dumps(
                    {
                        "plugin_slug": "demo",
                        "overall_risk": "medium",
                        "analysis_summary": "demo summary",
                        "findings": [
                            {
                                "finding_id": "F-001",
                                "verdict": "REVIEW",
                                "vuln_type": "REST integrations route issue",
                                "severity": "medium",
                                "auth_required": "admin",
                                "confidence": 0.71,
                                "entry_point_id": "ep_integrations",
                                "source_file_path": "routes.php",
                                "source_line_number": 11,
                                "sink_file_path": "handler.php",
                                "sink_line_number": 60,
                            },
                            {
                                "finding_id": "F-002",
                                "verdict": "FP",
                                "vuln_type": "Integrations option update false positive",
                                "severity": "info",
                                "auth_required": "admin",
                                "confidence": 0.81,
                                "entry_point_id": "ep_integrations",
                                "source_file_path": "routes.php",
                                "source_line_number": 11,
                                "sink_file_path": "handler.php",
                                "sink_line_number": 75,
                            },
                            {
                                "finding_id": "F-003",
                                "verdict": "FP",
                                "vuln_type": "Contact endpoint false positive",
                                "severity": "info",
                                "auth_required": "none",
                                "confidence": 0.78,
                                "entry_point_id": "ep_contact",
                                "source_file_path": "handler.php",
                                "source_line_number": 21,
                                "sink_file_path": "handler.php",
                                "sink_line_number": 90,
                            },
                            {
                                "finding_id": "F-004",
                                "verdict": "FP",
                                "vuln_type": "Survey false positive",
                                "severity": "info",
                                "auth_required": "none",
                                "confidence": 0.77,
                                "entry_point_id": "ep_init",
                                "source_file_path": "survey.php",
                                "source_line_number": 31,
                                "sink_file_path": "webhook.php",
                                "sink_line_number": 19,
                            },
                        ],
                    }
                ),
                encoding="utf-8",
            )

            review_output = phase2 / "demo-phase2.review.r1.json"
            reviewer_input = phase2 / "demo-phase2.review.r1.core.input.json"
            build_reviewer_input(
                root=root,
                slug="demo",
                review_round=1,
                review_mode="core",
                worker_output_path=worker_output,
                review_output_path=review_output,
                input_output_path=reviewer_input,
            )

            plan_path = phase2 / "demo-phase2.review.r1.core.batch-plan.json"
            plan = build_reviewer_batches(root=root, input_path=reviewer_input, output_plan=plan_path)
            self.assertEqual(plan["plugin_slug"], "demo")
            self.assertEqual(plan["review_mode"], "core")
            self.assertEqual(plan["total_packet_count"], 4)
            self.assertGreaterEqual(len(plan["batches"]), 2)
            self.assertLessEqual(len(plan["batches"]), 4)

            seen = []
            for index, batch in enumerate(plan["batches"], start=1):
                batch_input = root / batch["input_path"]
                batch_output = root / batch["output_path"]
                self.assertTrue(batch_input.exists())
                batch_payload = json.loads(batch_input.read_text(encoding="utf-8"))
                self.assertEqual(batch_payload["task"]["output_schema"], "contracts/phase2-review-core-output.schema.json")
                self.assertFalse(batch_payload["task"]["allow_missed_findings"])
                self.assertIsNone(batch_payload["artifacts"]["worker_output_path"])
                self.assertIsNone(batch_payload["artifacts"]["ir_path"])
                self.assertEqual(set(packet["packet_id"] for packet in batch_payload["finding_packets"]), set(batch["packet_ids"]))
                seen.extend(batch["packet_ids"])
                batch_doc = {
                    "plugin_slug": "demo",
                    "review_round": 1,
                    "review_mode": "core",
                    "review_status": "needs_revision" if index == 1 else "stable",
                    "summary": {
                        "worker_findings_reviewed": len(batch["finding_ids"]),
                        "material_issues_found": index == 1,
                        "new_candidate_count": 0,
                        "notes": f"batch {index}",
                    },
                    "finding_reviews": [
                        {
                            "finding_id": packet["parent_finding_id"],
                            "packet_id": packet["packet_id"],
                            "parent_finding_id": packet["parent_finding_id"],
                            "assessment": "downgrade" if index == 1 and idx == 0 else "keep",
                            "reason": "demo review",
                            "required_changes": ["check guard"] if index == 1 and idx == 0 else [],
                            "counter_evidence": [],
                            "missing_evidence": [],
                            "expansion_attempts": [],
                            "suggested_field_corrections": None,
                        }
                        for idx, packet in enumerate(batch_payload["finding_packets"])
                    ],
                }
                batch_output.write_text(json.dumps(batch_doc, indent=2) + "\n", encoding="utf-8")

            self.assertEqual(len(seen), 4)

            merged = merge_reviewer_batches(root=root, plan_path=plan_path, output_path=review_output)
            self.assertEqual(merged["plugin_slug"], "demo")
            self.assertEqual(merged["review_mode"], "core")
            self.assertEqual(merged["review_status"], "needs_revision")
            self.assertEqual(len(merged["finding_reviews"]), 4)
            self.assertTrue(all("packet_id" in item for item in merged["finding_reviews"]))
            self.assertNotIn("missed_findings", merged)
            self.assertTrue(review_output.exists())


if __name__ == "__main__":
    unittest.main()
