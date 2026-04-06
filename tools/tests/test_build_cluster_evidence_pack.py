import tempfile
import unittest
from pathlib import Path


from tools.bin.build_cluster_evidence_pack import build_pack


class BuildClusterEvidencePackTests(unittest.TestCase):
    def test_build_pack_extracts_primary_and_optional_snippets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plugin_dir = root / "plugins" / "demo"
            plugin_dir.mkdir(parents=True)
            (plugin_dir / "a.php").write_text(
                "<?php\nline1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\n",
                encoding="utf-8",
            )
            (plugin_dir / "b.php").write_text(
                "<?php\nb1\nb2\nb3\nb4\nb5\nb6\nb7\nb8\n",
                encoding="utf-8",
            )
            cluster_input = {
                "plugin_slug": "demo",
                "cluster_id": "cluster-c01",
                "cluster_strategy": "cross_bundle_cluster_v1",
                "cluster_summary": {},
                "shared_context": {
                    "entry_point_ids": ["ep_demo"],
                    "supporting_files": ["a.php", "b.php"],
                    "primary_files": ["a.php"],
                    "optional_files": ["b.php"],
                    "primary_anchors": ["a.php:5"],
                    "source_agents": ["agent-w01"],
                    "shared_signals": ["shared_entry_point"],
                },
                "member_findings": [
                    {
                        "finding_id": "f1",
                        "verdict": "REVIEW",
                        "vuln_type": "broken_access_control",
                        "confidence": 0.7,
                        "auth_required": "none",
                        "entry_point_ids": ["ep_demo"],
                        "source_agents": ["agent-w01"],
                        "source_anchor": "a.php:5",
                        "sink_anchor": "a.php:8",
                        "supporting_files": ["a.php", "b.php"],
                        "guard_anchors": ["b.php:3"],
                        "why_this_might_connect": "demo",
                    }
                ],
                "questions_to_answer": ["q1"],
                "exploration_budget": {
                    "max_optional_files": 1,
                    "max_out_of_band_files": 1,
                    "max_new_links": 3,
                    "max_open_questions": 3,
                },
                "constraints": ["c1"],
                "recommended_models": {},
            }
            pack = build_pack(cluster_input, root)
            self.assertEqual(pack["evidence_pack"]["snippet_counts"]["primary"], 1)
            self.assertEqual(pack["evidence_pack"]["snippet_counts"]["optional"], 1)
            self.assertEqual(pack["evidence_pack"]["primary_files_covered"], ["a.php"])
            self.assertEqual(pack["evidence_pack"]["optional_files_covered"], ["b.php"])


if __name__ == "__main__":
    unittest.main()
