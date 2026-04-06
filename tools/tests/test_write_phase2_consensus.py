import unittest
from pathlib import Path
import tempfile


from tools.bin.write_phase2_consensus import build_consensus


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
            self.assertEqual(result["consensus"]["unresolved_cluster_ids"], ["cluster-c01"])


if __name__ == "__main__":
    unittest.main()
