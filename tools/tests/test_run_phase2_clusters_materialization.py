import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "run-phase2-clusters.py"
sys.path.insert(0, str(ROOT / "tools" / "bin"))

spec = importlib.util.spec_from_file_location("run_phase2_clusters", MODULE_PATH)
run_phase2_clusters = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(run_phase2_clusters)


class RunPhase2ClustersMaterializationTests(unittest.TestCase):
    def test_materialize_cluster_output_accepts_fenced_json(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = pathlib.Path(tmp)
            output_path = tmpdir / "cluster.json"
            last_message_path = tmpdir / "cluster.last.txt"
            raw_log_path = tmpdir / "cluster.raw.log"
            last_message_path.write_text(
                "```json\n{\"plugin_slug\":\"demo\",\"cluster_id\":\"cluster-c01\",\"stage\":\"synthesis\",\"status\":\"needs_followup\",\"summary\":{},\"suggested_actions\":[],\"proposed_links\":[],\"objections\":[]}\n```",
                encoding="utf-8",
            )
            raw_log_path.write_text("", encoding="utf-8")

            ok = run_phase2_clusters.materialize_cluster_output(output_path, last_message_path, raw_log_path)
            self.assertTrue(ok)
            self.assertEqual(json.loads(output_path.read_text(encoding="utf-8"))["cluster_id"], "cluster-c01")

    def test_main_fails_when_any_cluster_challenge_fails(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = pathlib.Path(tmp)
            phase2_dir = tmpdir / "phase2"
            phase2_dir.mkdir(parents=True)
            plan_path = phase2_dir / "demo-cluster-plan.json"
            plan_path.write_text(
                json.dumps(
                    {
                        "clusters": [
                            {
                                "cluster_id": "cluster-c01",
                                "path": str(phase2_dir / "demo-cluster-c01.json"),
                                "pack_path": str(phase2_dir / "demo-cluster-c01.pack.json"),
                            }
                        ]
                    }
                ),
                encoding="utf-8",
            )

            with mock.patch.object(run_phase2_clusters, "PHASE2_DIR", phase2_dir), \
                mock.patch.object(run_phase2_clusters, "cluster_run_errlog_path", return_value=tmpdir / "run.err"), \
                mock.patch.object(run_phase2_clusters, "cluster_run_live_log_path", return_value=tmpdir / "run.live.log"), \
                mock.patch.object(run_phase2_clusters, "run_cluster", return_value=(True, False)), \
                mock.patch.object(sys, "argv", ["run-phase2-clusters.py", "demo"]):
                rc = run_phase2_clusters.main()

            self.assertEqual(rc, 1)

    def test_normalize_cluster_output_maps_legacy_advisory_shapes_to_schema(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = pathlib.Path(tmp)
            output_path = tmpdir / "cluster.challenge.json"
            output_path.write_text(
                json.dumps(
                    {
                        "plugin_slug": "demo",
                        "cluster_id": "cluster-c01",
                        "stage": "challenge",
                        "status": "stable",
                        "summary": {
                            "member_findings_reviewed": 1,
                            "material_links_found": 0,
                            "objections_count": 0,
                            "notes": "ok",
                        },
                        "suggested_actions": [],
                        "proposed_links": [],
                        "objections": [],
                        "closure_packets": [],
                        "open_questions": [
                            {
                                "id": "oq-1",
                                "question": "What is the default configuration?",
                                "severity": "advisory",
                                "blocking": False,
                            }
                        ],
                        "missing_evidence": [
                            {
                                "id": "me-1",
                                "description": "Confirm the default constant mapping.",
                                "impact": "This only affects exploitability breadth, not the core verdict.",
                            }
                        ],
                        "expansion_attempts": [],
                    }
                )
                + "\n",
                encoding="utf-8",
            )

            cluster_pack = {
                "plugin_slug": "demo",
                "cluster_id": "cluster-c01",
                "member_findings": [{"finding_id": "finding-1"}],
            }

            run_phase2_clusters.normalize_cluster_output(output_path, "challenge", cluster_pack)
            data = json.loads(output_path.read_text(encoding="utf-8"))

            self.assertEqual(data["open_questions"][0]["target_finding_ids"], ["finding-1"])
            self.assertIn("why_it_matters", data["open_questions"][0])
            self.assertEqual(
                data["missing_evidence"][0]["evidence_needed"],
                "Confirm the default constant mapping. Impact/context: This only affects exploitability breadth, not the core verdict.",
            )
            self.assertEqual(
                data["missing_evidence"][0]["reason"],
                "This only affects exploitability breadth, not the core verdict.",
            )

            run_phase2_clusters.validate_cluster_output(output_path)

    def test_compact_validation_error_returns_first_line(self) -> None:
        exc = ValueError("first line\nsecond line\nthird line")
        self.assertEqual(run_phase2_clusters.compact_validation_error(exc), "first line")


if __name__ == "__main__":
    unittest.main()
