import unittest
from pathlib import Path
import tempfile

from tools.bin.write_phase2_consensus import build_consensus, resolve_local_phase2_source


class WritePhase2ConsensusTests(unittest.TestCase):
    def test_build_consensus_aggregates_cluster_statuses(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phase2 = root / "reports" / "phase2"
            phase2.mkdir(parents=True)
            (phase2 / "demo-cluster-plan.json").write_text(
                """{
  "clusters": [
    {
      "cluster_id": "cluster-c01",
      "member_count": 2,
      "pack_path": "reports/phase2/demo-cluster-c01.pack.json"
    }
  ]
}""",
                encoding="utf-8",
            )
            (phase2 / "demo-cluster-c01.synth.json").write_text(
                """{
  "plugin_slug": "demo",
  "cluster_id": "cluster-c01",
  "stage": "synthesis",
  "status": "needs_followup",
  "summary": {"member_findings_reviewed": 2, "material_links_found": 1, "objections_count": 0, "open_questions_count": 1, "expansion_attempts_count": 0, "notes": ""},
  "suggested_actions": [],
  "proposed_links": [],
  "objections": [],
  "open_questions": [{"question":"q","why_it_matters":"m"}],
  "missing_evidence": [{"evidence_needed":"e","reason":"r"}],
  "expansion_attempts": []
}""",
                encoding="utf-8",
            )
            local_doc = {
                "plugin_slug": "demo",
                "findings": [],
                "merge_stats": {},
            }
            result = build_consensus(local_doc, "demo", phase2, root)
            self.assertEqual(result["consensus"]["clusters_total"], 1)
            self.assertEqual(result["consensus"]["synth_ok_count"], 1)
            self.assertEqual(result["consensus"]["challenge_ok_count"], 0)
            self.assertEqual(result["consensus"]["open_questions_total"], 1)
            self.assertEqual(result["consensus"]["missing_evidence_total"], 1)
            self.assertEqual(result["consensus"]["closure_packets_total"], 0)
            self.assertEqual(result["consensus"]["unresolved_cluster_ids"], ["cluster-c01"])
            self.assertTrue(result["consensus"]["closure_complete"])
            self.assertEqual(result["trust_state"], "degraded_success")
            self.assertIn("unresolved_clusters", result["degradation_signals"])
            self.assertIn("cluster_challenge_incomplete", result["degradation_signals"])

    def test_advisory_cluster_questions_do_not_degrade_when_outputs_are_complete(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phase2 = root / "reports" / "phase2"
            phase2.mkdir(parents=True)
            (phase2 / "demo-cluster-plan.json").write_text(
                """{
  "clusters": [
    {
      "cluster_id": "cluster-c01",
      "member_count": 2,
      "pack_path": "reports/phase2/demo-cluster-c01.pack.json"
    }
  ]
}""",
                encoding="utf-8",
            )
            (phase2 / "demo-cluster-c01.synth.json").write_text(
                """{
  "plugin_slug": "demo",
  "cluster_id": "cluster-c01",
  "stage": "synthesis",
  "status": "stable",
  "summary": {"member_findings_reviewed": 2, "material_links_found": 1, "objections_count": 0, "open_questions_count": 1, "closure_packets_count": 0, "expansion_attempts_count": 0, "notes": ""},
  "suggested_actions": [],
  "proposed_links": [],
  "objections": [],
  "closure_packets": [],
  "open_questions": [{"question":"advisory q","why_it_matters":"context"}],
  "missing_evidence": [{"evidence_needed":"optional replay","reason":"nice to have"}],
  "expansion_attempts": []
}""",
                encoding="utf-8",
            )
            (phase2 / "demo-cluster-c01.challenge.json").write_text(
                """{
  "plugin_slug": "demo",
  "cluster_id": "cluster-c01",
  "stage": "challenge",
  "status": "refuted",
  "summary": {"member_findings_reviewed": 2, "material_links_found": 0, "objections_count": 1, "open_questions_count": 0, "closure_packets_count": 0, "expansion_attempts_count": 0, "notes": ""},
  "suggested_actions": [],
  "proposed_links": [],
  "objections": [{"target_finding_ids":["finding-1"],"reason":"refuted"}],
  "closure_packets": [],
  "open_questions": [],
  "missing_evidence": [],
  "expansion_attempts": []
}""",
                encoding="utf-8",
            )
            local_doc = {
                "plugin_slug": "demo",
                "findings": [],
                "merge_stats": {},
            }
            result = build_consensus(local_doc, "demo", phase2, root)
            self.assertEqual(result["consensus"]["closure_packets_total"], 0)
            self.assertEqual(result["consensus"]["unresolved_cluster_ids"], [])
            self.assertTrue(result["consensus"]["closure_complete"])
            self.assertEqual(result["trust_state"], "success")
            self.assertNotIn("cluster_closure_routing_missing", result["degradation_signals"])

    def test_needs_followup_cluster_without_closure_packet_stays_unresolved(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phase2 = root / "reports" / "phase2"
            phase2.mkdir(parents=True)
            (phase2 / "demo-cluster-plan.json").write_text(
                """{
  "clusters": [
    {
      "cluster_id": "cluster-c01",
      "member_count": 2,
      "pack_path": "reports/phase2/demo-cluster-c01.pack.json"
    }
  ]
}""",
                encoding="utf-8",
            )
            synth_doc = """{
  "plugin_slug": "demo",
  "cluster_id": "cluster-c01",
  "stage": "synthesis",
  "status": "needs_followup",
  "summary": {"member_findings_reviewed": 2, "material_links_found": 1, "objections_count": 0, "open_questions_count": 1, "closure_packets_count": 0, "expansion_attempts_count": 0, "notes": ""},
  "suggested_actions": [],
  "proposed_links": [],
  "objections": [],
  "closure_packets": [],
  "open_questions": [{"question":"still unclear","why_it_matters":"changes closure"}],
  "missing_evidence": [{"evidence_needed":"packet-local proof","reason":"closure still needed"}],
  "expansion_attempts": []
}"""
            (phase2 / "demo-cluster-c01.synth.json").write_text(synth_doc, encoding="utf-8")
            (phase2 / "demo-cluster-c01.challenge.json").write_text(synth_doc.replace('"stage": "synthesis"', '"stage": "challenge"'), encoding="utf-8")
            local_doc = {
                "plugin_slug": "demo",
                "findings": [],
                "merge_stats": {},
            }
            result = build_consensus(local_doc, "demo", phase2, root)
            self.assertEqual(result["consensus"]["unresolved_cluster_ids"], ["cluster-c01"])
            self.assertTrue(result["consensus"]["closure_complete"])
            self.assertIn("cluster_closure_routing_missing", result["degradation_signals"])

    def test_closure_packets_clear_needs_followup_cluster_blocker(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phase2 = root / "reports" / "phase2"
            phase2.mkdir(parents=True)
            (phase2 / "demo-cluster-plan.json").write_text(
                """{
  "clusters": [
    {
      "cluster_id": "cluster-c01",
      "member_count": 2,
      "pack_path": "reports/phase2/demo-cluster-c01.pack.json"
    }
  ]
}""",
                encoding="utf-8",
            )
            (phase2 / "demo-cluster-c01.synth.json").write_text(
                """{
  "plugin_slug": "demo",
  "cluster_id": "cluster-c01",
  "stage": "synthesis",
  "status": "needs_followup",
  "summary": {"member_findings_reviewed": 2, "material_links_found": 1, "objections_count": 0, "open_questions_count": 1, "closure_packets_count": 1, "expansion_attempts_count": 0, "notes": ""},
  "suggested_actions": [{"finding_id":"finding-1","action":"route_to_closure","reason":"packet-local closure needed"}],
  "proposed_links": [],
  "objections": [],
  "closure_packets": [{"finding_ids":["finding-1"],"closure_need":"confirm_or_reject_shared_hypothesis","reason":"bounded closure required","evidence_needed":["prove shared exploit chain"]}],
  "open_questions": [{"question":"still unclear","why_it_matters":"changes closure"}],
  "missing_evidence": [{"evidence_needed":"packet-local proof","reason":"closure still needed"}],
  "expansion_attempts": []
}""",
                encoding="utf-8",
            )
            (phase2 / "demo-cluster-c01.challenge.json").write_text(
                """{
  "plugin_slug": "demo",
  "cluster_id": "cluster-c01",
  "stage": "challenge",
  "status": "needs_followup",
  "summary": {"member_findings_reviewed": 2, "material_links_found": 0, "objections_count": 1, "open_questions_count": 0, "closure_packets_count": 0, "expansion_attempts_count": 0, "notes": ""},
  "suggested_actions": [],
  "proposed_links": [],
  "objections": [{"target_finding_ids":["finding-1"],"reason":"needs packet-local closure"}],
  "closure_packets": [],
  "open_questions": [],
  "missing_evidence": [],
  "expansion_attempts": []
}""",
                encoding="utf-8",
            )
            local_doc = {
                "plugin_slug": "demo",
                "findings": [],
                "merge_stats": {},
            }
            result = build_consensus(local_doc, "demo", phase2, root)
            self.assertEqual(result["consensus"]["closure_packets_total"], 1)
            self.assertEqual(result["consensus"]["unresolved_cluster_ids"], [])
            self.assertTrue(result["consensus"]["closure_complete"])
            self.assertEqual(result["trust_state"], "success")

    def test_closure_incomplete_downgrades_even_without_cluster_defects(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            phase2 = root / "reports" / "phase2"
            phase2.mkdir(parents=True)
            local_doc = {
                "plugin_slug": "demo",
                "findings": [{"finding_id": "f1", "verdict": "REVIEW"}],
                "needs_review": 1,
                "merge_stats": {},
            }
            result = build_consensus(local_doc, "demo", phase2, root)
            self.assertFalse(result["consensus"]["closure_complete"])
            self.assertEqual(result["trust_state"], "degraded_success")
            self.assertIn("closure_incomplete", result["degradation_signals"])

    def test_resolve_local_phase2_source_requires_local_artifact(self):
        with tempfile.TemporaryDirectory() as tmp:
            phase2 = Path(tmp) / "reports" / "phase2"
            phase2.mkdir(parents=True)
            local = phase2 / "demo-phase2.local.json"
            local.write_text('{"plugin_slug":"demo","findings":[],"merge_stats":{}}', encoding="utf-8")
            self.assertEqual(resolve_local_phase2_source(phase2, "demo"), local)

    def test_resolve_local_phase2_source_does_not_fallback_to_canonical(self):
        with tempfile.TemporaryDirectory() as tmp:
            phase2 = Path(tmp) / "reports" / "phase2"
            phase2.mkdir(parents=True)
            canonical = phase2 / "demo-phase2.json"
            canonical.write_text('{"plugin_slug":"demo","trust_state":"success"}', encoding="utf-8")

            with self.assertRaises(FileNotFoundError):
                resolve_local_phase2_source(phase2, "demo")


if __name__ == "__main__":
    unittest.main()
