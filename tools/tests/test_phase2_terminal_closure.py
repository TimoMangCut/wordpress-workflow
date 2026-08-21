import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]


class Phase2TerminalClosureTests(unittest.TestCase):
    def test_terminal_core_review_applies_explicit_tp_fp_closures(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            worker_input = root / "worker.json"
            review_input = root / "review.json"
            output_path = root / "closed.json"

            worker_input.write_text(
                json.dumps(
                    {
                        "plugin_slug": "sample-plugin",
                        "analysis_summary": "stub worker output",
                        "overall_risk": "review",
                        "true_positives": 0,
                        "false_positives": 0,
                        "needs_review": 2,
                        "total_findings_analyzed": 2,
                        "findings": [
                            {
                                "finding_id": "finding-1",
                                "verdict": "REVIEW",
                                "vuln_type": "xss",
                                "severity": "medium",
                                "auth_required": "none",
                                "source_file_path": "src/a.php",
                                "source_line_number": 11,
                                "sink_file_path": "src/a.php",
                                "sink_line_number": 29,
                                "review_reason": "needs concrete output sink",
                            },
                            {
                                "finding_id": "finding-2",
                                "verdict": "REVIEW",
                                "vuln_type": "sql_injection",
                                "severity": "high",
                                "auth_required": "subscriber",
                                "source_file_path": "src/b.php",
                                "source_line_number": 7,
                                "sink_file_path": "src/b.php",
                                "sink_line_number": 41,
                                "review_reason": "needs trace",
                            },
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            review_input.write_text(
                json.dumps(
                    {
                        "plugin_slug": "sample-plugin",
                        "review_round": 3,
                        "review_mode": "terminal_core",
                        "review_status": "stable",
                        "finding_reviews": [
                            {
                                "finding_id": "finding-1",
                                "packet_id": "finding-1",
                                "parent_finding_id": "finding-1",
                                "assessment": "keep",
                                "closure_verdict": "TP",
                                "reason": "Packet-local trace reaches the executable sink with no effective guard.",
                                "required_changes": [],
                                "counter_evidence": [],
                                "missing_evidence": [],
                                "expansion_attempts": [],
                            },
                            {
                                "finding_id": "finding-2",
                                "packet_id": "finding-2",
                                "parent_finding_id": "finding-2",
                                "assessment": "retract",
                                "closure_verdict": "FP",
                                "reason": "Exploit path remains unproven after bounded packet-local review.",
                                "required_changes": [],
                                "counter_evidence": [
                                    {
                                        "type": "impact",
                                        "file": "src/b.php",
                                        "line": 41,
                                        "detail": "Reviewed branch stops before a concrete SQL sink.",
                                    }
                                ],
                                "missing_evidence": ["Concrete request-to-query trace showing attacker control at the SQL call."],
                                "expansion_attempts": [],
                            },
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools" / "bin" / "phase2_terminal_closure.py"),
                    "--slug",
                    "sample-plugin",
                    "--worker-input",
                    str(worker_input),
                    "--review-input",
                    str(review_input),
                    "--output",
                    str(output_path),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            closed = json.loads(output_path.read_text(encoding="utf-8"))
            finding_one = next(item for item in closed["findings"] if item["finding_id"] == "finding-1")
            finding_two = next(item for item in closed["findings"] if item["finding_id"] == "finding-2")
            self.assertEqual(finding_one["verdict"], "TP")
            self.assertIn("Terminal core review confirmed the packet", finding_one["review_reason"])
            self.assertEqual(finding_two["verdict"], "FP")
            self.assertIn("Exploit path remains unproven", finding_two["fp_reason"])
            self.assertEqual(finding_two["fp_evidence"]["file"], "src/b.php")
            self.assertEqual(closed["true_positives"], 1)
            self.assertEqual(closed["false_positives"], 1)
            self.assertEqual(closed["needs_review"], 0)
            self.assertEqual(closed["phase2_terminal_closure"]["confirmed_finding_ids"], ["finding-1"])
            self.assertEqual(closed["phase2_terminal_closure"]["closed_finding_ids"], ["finding-2"])

    def test_legacy_core_review_still_closes_unresolved_as_controlled_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            worker_input = root / "worker.json"
            review_input = root / "review.json"
            output_path = root / "closed.json"

            worker_input.write_text(
                json.dumps(
                    {
                        "plugin_slug": "sample-plugin",
                        "analysis_summary": "stub worker output",
                        "overall_risk": "review",
                        "true_positives": 0,
                        "false_positives": 0,
                        "needs_review": 1,
                        "total_findings_analyzed": 1,
                        "findings": [
                            {
                                "finding_id": "finding-1",
                                "verdict": "REVIEW",
                                "vuln_type": "xss",
                                "severity": "medium",
                                "auth_required": "none",
                                "source_file_path": "src/a.php",
                                "source_line_number": 11,
                                "sink_file_path": "src/a.php",
                                "sink_line_number": 29,
                                "review_reason": "needs concrete output sink",
                            }
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            review_input.write_text(
                json.dumps(
                    {
                        "plugin_slug": "sample-plugin",
                        "review_round": 2,
                        "review_mode": "core",
                        "review_status": "needs_revision",
                        "finding_reviews": [
                            {
                                "finding_id": "finding-1",
                                "packet_id": "finding-1",
                                "parent_finding_id": "finding-1",
                                "assessment": "needs_more_evidence",
                                "reason": "Trace stops at helper wrapper; exploit sink is still unproven.",
                                "counter_evidence": [
                                    {
                                        "detail": "The reviewed branch only reaches a wrapper helper, not a browser-executable sink.",
                                        "file": "src/a.php",
                                        "line": 29,
                                    }
                                ],
                                "missing_evidence": [
                                    "A concrete payload that survives filtering and reaches executable output."
                                ],
                            }
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools" / "bin" / "phase2_terminal_closure.py"),
                    "--slug",
                    "sample-plugin",
                    "--worker-input",
                    str(worker_input),
                    "--review-input",
                    str(review_input),
                    "--output",
                    str(output_path),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
            )

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            closed = json.loads(output_path.read_text(encoding="utf-8"))
            finding = closed["findings"][0]
            self.assertEqual(finding["verdict"], "FP")
            self.assertIn("Terminal closure applied after bounded core-review exhaustion.", finding["fp_reason"])
            self.assertEqual(closed["phase2_terminal_closure"]["closed_finding_ids"], ["finding-1"])

    def test_terminal_core_review_fails_if_current_review_findings_are_not_covered(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            root = pathlib.Path(tempdir)
            worker_input = root / "worker.json"
            review_input = root / "review.json"
            output_path = root / "closed.json"

            worker_input.write_text(
                json.dumps(
                    {
                        "plugin_slug": "sample-plugin",
                        "analysis_summary": "stub worker output",
                        "overall_risk": "review",
                        "true_positives": 0,
                        "false_positives": 0,
                        "needs_review": 1,
                        "total_findings_analyzed": 1,
                        "findings": [
                            {
                                "finding_id": "finding-live",
                                "verdict": "REVIEW",
                                "vuln_type": "broken_access_control",
                                "severity": "medium",
                                "auth_required": "subscriber",
                                "source_file_path": "src/a.php",
                                "source_line_number": 10,
                                "sink_file_path": "src/a.php",
                                "sink_line_number": 25,
                            }
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )
            review_input.write_text(
                json.dumps(
                    {
                        "plugin_slug": "sample-plugin",
                        "review_round": 3,
                        "review_mode": "terminal_core",
                        "review_status": "stable",
                        "finding_reviews": [
                            {
                                "finding_id": "finding-stale",
                                "packet_id": "finding-stale",
                                "parent_finding_id": "finding-stale",
                                "assessment": "retract",
                                "closure_verdict": "FP",
                                "reason": "This stale packet should not be accepted.",
                                "required_changes": [],
                                "counter_evidence": [],
                                "missing_evidence": [],
                                "expansion_attempts": [],
                            }
                        ],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "tools" / "bin" / "phase2_terminal_closure.py"),
                    "--slug",
                    "sample-plugin",
                    "--worker-input",
                    str(worker_input),
                    "--review-input",
                    str(review_input),
                    "--output",
                    str(output_path),
                ],
                cwd=ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=30,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not a current REVIEW finding", result.stderr)
            self.assertFalse(output_path.exists())


if __name__ == "__main__":
    unittest.main()
