import json
import tempfile
import unittest
from pathlib import Path


from tools.bin.build_phase2_reviewer_input import build_reviewer_input


class BuildPhase2ReviewerInputTests(unittest.TestCase):
    def test_build_reviewer_input_emits_compact_json_first_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "contracts").mkdir(parents=True)
            plugin_dir = root / "plugins" / "demo"
            plugin_dir.mkdir(parents=True)
            repo_root = Path(__file__).resolve().parents[2]
            schema_src = repo_root / "contracts" / "phase2-reviewer-input.schema.json"
            (root / "contracts" / "phase2-reviewer-input.schema.json").write_text(schema_src.read_text(encoding="utf-8"), encoding="utf-8")
            packet_schema_src = repo_root / "contracts" / "phase2-reviewer-packet.schema.json"
            (root / "contracts" / "phase2-reviewer-packet.schema.json").write_text(packet_schema_src.read_text(encoding="utf-8"), encoding="utf-8")
            core_output_schema_src = repo_root / "contracts" / "phase2-review-core-output.schema.json"
            explore_output_schema_src = repo_root / "contracts" / "phase2-review-explore-output.schema.json"
            (root / "contracts" / "phase2-review-core-output.schema.json").write_text(core_output_schema_src.read_text(encoding="utf-8"), encoding="utf-8")
            (root / "contracts" / "phase2-review-explore-output.schema.json").write_text(explore_output_schema_src.read_text(encoding="utf-8"), encoding="utf-8")
            (plugin_dir / "demo.php").write_text(
                "\n".join(f"<?php // line {line}" for line in range(1, 81)) + "\n",
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
                            {
                                "id": "ep_demo",
                                "type": "ajax",
                                "hook_name": "wp_ajax_demo",
                                "auth_level": "none",
                                "file": "demo.php",
                                "line": 10,
                                "callback": {"name": "handle_demo", "class": None},
                            }
                        ],
                        "anomalies": [
                            {
                                "id": "anom_1",
                                "type": "missing_nonce",
                                "severity": "high",
                                "entry_point_id": "ep_demo",
                                "description": "demo anomaly",
                                "evidence": {"file": "demo.php", "line": 11},
                            }
                        ],
                        "unresolved_hooks": [{"file": "demo.php", "line": 42, "function": "add_action", "hook_arg_type": "concatenation"}],
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
                        "negative_findings": [{"file": "safe.php"}],
                        "findings": [
                            {
                                "finding_id": "demo-f1",
                                "verdict": "REVIEW",
                                "vuln_type": "broken_access_control",
                                "severity": "medium",
                                "auth_required": "none",
                                "confidence": 0.72,
                                "entry_point_id": "ep_demo",
                                "source_file_path": "demo.php",
                                "source_line_number": 10,
                                "sink_file_path": "demo.php",
                                "sink_line_number": 30,
                                "patchstack_eligible": True,
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            review_output = phase2 / "demo-phase2.review.r1.json"
            reviewer_input = phase2 / "demo-phase2.review.r1.core.input.json"

            payload = build_reviewer_input(
                root=root,
                slug="demo",
                review_round=1,
                review_mode="core",
                worker_output_path=worker_output,
                review_output_path=review_output,
                input_output_path=reviewer_input,
            )

            self.assertEqual(payload["plugin_slug"], "demo")
            self.assertEqual(payload["review_mode"], "core")
            self.assertEqual(payload["worker_summary"]["needs_review_count"], 1)
            self.assertEqual(payload["phase1_context"]["entry_point_count"], 1)
            self.assertEqual(payload["phase1_context"]["anomaly_count"], 1)
            self.assertEqual(payload["task"]["packet_schema"], "contracts/phase2-reviewer-packet.schema.json")
            self.assertEqual(payload["task"]["output_schema"], "contracts/phase2-review-core-output.schema.json")
            self.assertFalse(payload["task"]["allow_missed_findings"])
            self.assertEqual(payload["worker_findings"][0]["source_anchor"], "demo.php:10")
            self.assertTrue(payload["evidence"]["primary_anchors"])
            self.assertTrue(payload["evidence"]["primary_snippets"])
            self.assertEqual(payload["evidence"]["primary_files"], ["demo.php"])
            self.assertEqual(payload["evidence"]["optional_evidence"]["anchors"], [])
            self.assertEqual(payload["evidence"]["optional_evidence"]["files"], [])
            self.assertEqual(payload["evidence"]["optional_evidence"]["snippets"], [])
            self.assertEqual(payload["phase1_context"]["top_anomalies"], [])
            self.assertEqual(payload["phase1_context"]["unresolved_hooks"], [])
            self.assertEqual(len(payload["finding_packets"]), 1)
            packet = payload["finding_packets"][0]
            self.assertEqual(packet["packet_id"], "demo-f1")
            self.assertEqual(packet["parent_finding_id"], "demo-f1")
            self.assertEqual(packet["finding_id"], "demo-f1")
            self.assertIn("worker_context", packet)
            self.assertIn("review_focus", packet)
            self.assertIn("scope_policy", packet)
            self.assertEqual(packet["scope_policy"]["max_out_of_band_files"], 1)
            self.assertEqual(packet["review_focus"]["entry_point_anchor"], "demo.php:10")
            self.assertEqual(packet["anchors"]["entry_point_anchor"], "demo.php:10")
            self.assertEqual(packet["anchors"]["source_anchor"], "demo.php:10")
            self.assertEqual(packet["anchors"]["sink_anchor"], "demo.php:30")
            self.assertTrue(packet["primary_snippets"])
            self.assertTrue(packet["review_questions"]["authorization"])
            self.assertTrue(reviewer_input.exists())

    def test_build_reviewer_input_explore_keeps_optional_evidence_and_explore_schema(self):
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
            ):
                src = repo_root / "contracts" / name
                (root / "contracts" / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")
            (plugin_dir / "demo.php").write_text(
                "\n".join(f"<?php // line {line}" for line in range(1, 81)) + "\n",
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
                            {
                                "id": "ep_demo",
                                "type": "ajax",
                                "hook_name": "wp_ajax_demo",
                                "auth_level": "none",
                                "file": "demo.php",
                                "line": 10,
                                "callback": {"name": "handle_demo", "class": None},
                            }
                        ],
                        "anomalies": [
                            {
                                "id": "anom_1",
                                "type": "missing_nonce",
                                "severity": "high",
                                "entry_point_id": "ep_demo",
                                "description": "demo anomaly",
                                "evidence": {"file": "demo.php", "line": 11},
                            }
                        ],
                        "unresolved_hooks": [{"file": "demo.php", "line": 42, "function": "add_action", "hook_arg_type": "concatenation"}],
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
                                "finding_id": "demo-f1",
                                "verdict": "REVIEW",
                                "vuln_type": "broken_access_control",
                                "severity": "medium",
                                "auth_required": "none",
                                "confidence": 0.72,
                                "entry_point_id": "ep_demo",
                                "source_file_path": "demo.php",
                                "source_line_number": 10,
                                "sink_file_path": "demo.php",
                                "sink_line_number": 30
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            review_output = phase2 / "demo-phase2.review.r2.json"
            reviewer_input = phase2 / "demo-phase2.review.r2.explore.input.json"

            payload = build_reviewer_input(
                root=root,
                slug="demo",
                review_round=2,
                review_mode="explore",
                worker_output_path=worker_output,
                review_output_path=review_output,
                input_output_path=reviewer_input,
                max_candidates=2,
            )

            self.assertEqual(payload["review_mode"], "explore")
            self.assertEqual(payload["task"]["output_schema"], "contracts/phase2-review-explore-output.schema.json")
            self.assertTrue(payload["task"]["allow_missed_findings"])
            self.assertEqual(payload["task"]["max_candidates"], 2)
            self.assertEqual(payload["finding_packets"], [])
            self.assertIn("Treat worker_findings as the current coverage map", payload["task"]["constraints"][0])
            self.assertTrue(payload["evidence"]["optional_evidence"]["anchors"])
            self.assertLessEqual(len(payload["phase1_context"]["top_anomalies"]), 6)
            self.assertLessEqual(len(payload["phase1_context"]["unresolved_hooks"]), 6)
            self.assertTrue(payload["phase1_context"]["top_anomalies"])
            self.assertTrue(reviewer_input.exists())

    def test_build_reviewer_input_atomizes_aggregate_multi_surface_findings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "contracts").mkdir(parents=True)
            plugin_dir = root / "plugins" / "demo"
            (plugin_dir / "src" / "Api" / "Handlers").mkdir(parents=True)
            (plugin_dir / "src" / "Api" / "Routes").mkdir(parents=True)
            (plugin_dir / "src" / "Integrations").mkdir(parents=True)
            repo_root = Path(__file__).resolve().parents[2]
            for name in (
                "phase2-reviewer-input.schema.json",
                "phase2-reviewer-packet.schema.json",
                "phase2-review-core-output.schema.json",
                "phase2-review-explore-output.schema.json",
            ):
                src = repo_root / "contracts" / name
                (root / "contracts" / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

            file_map = {
                "src/Api/Handlers/ReachApiHandler.php": 220,
                "src/Api/Handlers/IntegrationsApiHandler.php": 220,
                "src/Api/Routes/Routes.php": 120,
                "src/Integrations/OptInMonsterIntegration.php": 220,
            }
            for rel_path, total_lines in file_map.items():
                target = plugin_dir / rel_path
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(
                    "\n".join(f"<?php // {rel_path} line {line}" for line in range(1, total_lines + 1)) + "\n",
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
                            {
                                "id": "ep_rest_api_init_rest_api_init",
                                "type": "rest_api_init",
                                "hook_name": "rest_api_init",
                                "auth_level": "none",
                                "file": "src/Api/Routes/Routes.php",
                                "line": 22,
                                "callback": {"name": "register_routes", "class": None},
                            }
                        ],
                        "anomalies": [],
                        "unresolved_hooks": [],
                    }
                ),
                encoding="utf-8",
            )

            worker_output = phase2 / "demo-phase2.worker.r1.json"
            worker_output.write_text(
                json.dumps(
                    {
                        "plugin_slug": "demo",
                        "overall_risk": "low",
                        "analysis_summary": "aggregate demo",
                        "findings": [
                            {
                                "finding_id": "demo-agg-1",
                                "verdict": "FP",
                                "vuln_type": "XSS — Multiple semgrep-flagged echo-without-escape in handler/integration files",
                                "severity": "info",
                                "auth_required": False,
                                "confidence": 1.0,
                                "entry_point_id": "ep_rest_api_init_rest_api_init",
                                "source_function": "Multiple (ReachApiHandler, IntegrationsApiHandler, OptInMonsterIntegration)",
                                "sink_function": "Various boolean/method returns",
                                "source_file_path": "src/Api/Handlers/ReachApiHandler.php",
                                "source_line_number": 152,
                                "sink_file_path": "src/Api/Handlers/ReachApiHandler.php",
                                "sink_line_number": 152,
                                "reasoning": {
                                    "trace": "ReachApiHandler.php line 152; IntegrationsApiHandler.php line 205; OptInMonsterIntegration.php line 255; Routes.php line 22",
                                    "conclusion": "FP batch — semgrep over-triggered on multiple surfaces.",
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            review_output = phase2 / "demo-phase2.review.r1.json"
            reviewer_input = phase2 / "demo-phase2.review.r1.core.input.json"
            payload = build_reviewer_input(
                root=root,
                slug="demo",
                review_round=1,
                review_mode="core",
                worker_output_path=worker_output,
                review_output_path=review_output,
                input_output_path=reviewer_input,
            )

            packets = payload["finding_packets"]
            self.assertGreaterEqual(len(packets), 2)
            self.assertTrue(all(packet["parent_finding_id"] == "demo-agg-1" for packet in packets))
            self.assertTrue(all(packet["packet_id"].startswith("demo-agg-1__p") for packet in packets))
            self.assertTrue(all(packet["packet_kind"] == "atomic_surface" for packet in packets))
            self.assertGreaterEqual(len({packet["focus_anchor"] for packet in packets}), 2)
            self.assertTrue(all(packet["scope_policy"]["max_out_of_band_files"] == 1 for packet in packets))
            self.assertTrue(all(packet["review_focus"]["scope_statement"] for packet in packets))
            self.assertTrue(all(packet["review_focus"]["disallowed_drift"] for packet in packets))
            self.assertTrue(all(packet["worker_context"]["source_function"] != "Multiple (ReachApiHandler, IntegrationsApiHandler, OptInMonsterIntegration)" for packet in packets))
            self.assertTrue(all(packet["focus_anchor"] in (packet["worker_context"]["reasoning_excerpt"]["trace"] or "") for packet in packets))
            self.assertTrue(
                all(
                    "reviewer_core" in ((packet["worker_context"]["fp_reason"] or "").lower())
                    for packet in packets
                )
            )

    def test_build_reviewer_input_marks_hook_dispatch_packets_with_packet_local_stop_conditions(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "contracts").mkdir(parents=True)
            plugin_dir = root / "plugins" / "demo"
            (plugin_dir / "src" / "Integrations" / "OptInMonster").mkdir(parents=True)
            repo_root = Path(__file__).resolve().parents[2]
            for name in (
                "phase2-reviewer-input.schema.json",
                "phase2-reviewer-packet.schema.json",
                "phase2-review-core-output.schema.json",
                "phase2-review-explore-output.schema.json",
            ):
                src = repo_root / "contracts" / name
                (root / "contracts" / name).write_text(src.read_text(encoding="utf-8"), encoding="utf-8")

            target = plugin_dir / "src" / "Integrations" / "OptInMonster" / "OptInMonsterIntegration.php"
            target.write_text(
                "\n".join(f"<?php // line {line}" for line in range(1, 181)) + "\n",
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
                            {
                                "id": "ep_demo_optin",
                                "type": "rest",
                                "hook_name": "rest_api_init",
                                "auth_level": "none",
                                "file": "src/Integrations/OptInMonster/OptInMonsterIntegration.php",
                                "line": 62,
                                "callback": {"name": "submit_optinmonster", "class": "OptInMonsterIntegration"},
                            }
                        ],
                        "anomalies": [],
                        "unresolved_hooks": [],
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
                        "analysis_summary": "hook dispatch test",
                        "findings": [
                            {
                                "finding_id": "demo-hook-1",
                                "verdict": "REVIEW",
                                "vuln_type": "broken_access_control",
                                "severity": "medium",
                                "auth_required": "none",
                                "confidence": 0.68,
                                "entry_point_id": "ep_demo_optin",
                                "source_function": "submit_optinmonster",
                                "sink_function": "do_action('hostinger_reach_submit', ...)",
                                "source_file_path": "src/Integrations/OptInMonster/OptInMonsterIntegration.php",
                                "source_line_number": 62,
                                "sink_file_path": "src/Integrations/OptInMonster/OptInMonsterIntegration.php",
                                "sink_line_number": 78,
                                "fp_reason": "Worker inferred impact through shared submit hook consumers.",
                                "reasoning": {
                                    "trace": "OptInMonsterIntegration.php line 62 -> line 78 -> shared hook consumers elsewhere",
                                    "conclusion": "Needs reviewer confirmation.",
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            review_output = phase2 / "demo-phase2.review.r1.json"
            reviewer_input = phase2 / "demo-phase2.review.r1.core.input.json"

            payload = build_reviewer_input(
                root=root,
                slug="demo",
                review_round=1,
                review_mode="core",
                worker_output_path=worker_output,
                review_output_path=review_output,
                input_output_path=reviewer_input,
            )

            packet = payload["finding_packets"][0]
            self.assertEqual(packet["review_focus"]["sink_semantics"], "hook_dispatch")
            self.assertEqual(packet["review_focus"]["default_resolution_on_missing_terminal_evidence"], "needs_more_evidence")
            self.assertTrue(any("hook dispatch" in item.lower() for item in packet["review_focus"]["stop_conditions"]))
            self.assertTrue(any("shared_hook_consumer_enumeration" == item for item in packet["review_focus"]["disallowed_drift"]))
            self.assertIn("Packet-local review only", packet["worker_context"]["reasoning_excerpt"]["trace"])
            self.assertEqual(packet["worker_context"]["original_fp_reason"], "Worker inferred impact through shared submit hook consumers.")


if __name__ == "__main__":
    unittest.main()
