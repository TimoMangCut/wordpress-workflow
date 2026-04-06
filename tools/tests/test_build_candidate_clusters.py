import unittest


from tools.bin.build_candidate_clusters import build_cluster_input, connected_components, derive_bug_family, link_findings


class BuildCandidateClustersTests(unittest.TestCase):
    def test_link_findings_on_shared_entry_point(self):
        a = {
            "finding_id": "f1",
            "entry_point_id": "ep_rest_demo",
            "vuln_type": "broken_access_control",
            "auth_required": "none",
            "source_agents": ["agent-w01"],
        }
        b = {
            "finding_id": "f2",
            "entry_point_id": "ep_rest_demo",
            "vuln_type": "sensitive_information_disclosure",
            "auth_required": "none",
            "source_agents": ["agent-w02"],
        }
        self.assertTrue(link_findings(a, b))

    def test_connected_components_keeps_unrelated_findings_apart(self):
        findings = [
            {
                "finding_id": "f1",
                "entry_point_id": "ep_a",
                "vuln_type": "broken_access_control",
                "auth_required": "none",
                "source_file_path": "a.php",
                "source_agents": ["agent-w01"],
            },
            {
                "finding_id": "f2",
                "entry_point_id": "ep_a",
                "vuln_type": "sensitive_information_disclosure",
                "auth_required": "none",
                "sink_file_path": "a.php",
                "source_agents": ["agent-w02"],
            },
            {
                "finding_id": "f3",
                "entry_point_id": "ep_b",
                "vuln_type": "stored_xss",
                "auth_required": "editor",
                "source_file_path": "b.php",
                "source_agents": ["agent-w09"],
            },
        ]
        components = connected_components(findings)
        sizes = sorted(len(component) for component in components)
        self.assertEqual(sizes, [1, 2])

    def test_bug_family_derivation(self):
        self.assertEqual(derive_bug_family("arbitrary_file_upload"), "file_ops")
        self.assertEqual(derive_bug_family("broken_access_control"), "authorization")
        self.assertEqual(derive_bug_family("unknown_custom_issue"), "generic")

    def test_build_cluster_input_is_compact(self):
        cluster_doc = {
            "plugin_slug": "demo",
            "cluster_id": "cluster-c01",
            "cluster_strategy": "cross_bundle_cluster_v1",
            "bug_family": "authorization",
            "dominant_vuln_types": ["broken_access_control"],
            "auth_boundary": "none",
            "priority_score": 9,
            "synthesis_scope": "cross_bundle",
            "entry_point_ids": ["ep_rest_demo"],
            "supporting_files": ["includes/rest.php", "includes/guards.php"],
            "source_agents": ["agent-w01", "agent-w02"],
            "recommended_models": {
                "synthesizer": {"provider": "codex", "model": "gpt-5.4"},
                "challenger": {"provider": "claude", "model": "claude-sonnet-4.6"},
            },
            "member_findings": [
                {
                    "finding_id": "demo-f1",
                    "verdict": "TP",
                    "vuln_type": "broken_access_control",
                    "confidence": 0.91,
                    "severity": "medium",
                    "auth_required": "none",
                    "entry_point_id": "ep_rest_demo",
                    "source_file_path": "includes/rest.php",
                    "source_line_number": 12,
                    "sink_file_path": "includes/rest.php",
                    "sink_line_number": 42,
                    "reasoning": "Very long prose that should not survive into the compact cluster input.",
                    "source_agents": ["agent-w01"],
                    "phase3_review": {
                        "counter_evidence": [
                            {"file": "includes/guards.php", "line": 10}
                        ]
                    },
                }
            ],
        }
        cluster_input = build_cluster_input(cluster_doc)
        self.assertEqual(cluster_input["cluster_summary"]["member_count"], 1)
        self.assertEqual(cluster_input["member_findings"][0]["finding_id"], "demo-f1")
        self.assertNotIn("reasoning", cluster_input["member_findings"][0])
        self.assertEqual(cluster_input["member_findings"][0]["source_anchor"], "includes/rest.php:12")
        self.assertEqual(cluster_input["member_findings"][0]["guard_anchors"], ["includes/guards.php:10"])
        self.assertIn("includes/rest.php", cluster_input["shared_context"]["primary_files"])
        self.assertIn("includes/guards.php", cluster_input["shared_context"]["primary_files"])
        self.assertEqual(cluster_input["shared_context"]["optional_files"], [])
        self.assertIn("includes/rest.php:12", cluster_input["shared_context"]["primary_anchors"])
        self.assertEqual(cluster_input["exploration_budget"]["max_out_of_band_files"], 1)


if __name__ == "__main__":
    unittest.main()
