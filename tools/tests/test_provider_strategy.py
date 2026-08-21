import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "provider_strategy.py"
sys.path.insert(0, str(ROOT / "tools" / "bin"))

spec = importlib.util.spec_from_file_location("provider_strategy", MODULE_PATH)
provider_strategy = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(provider_strategy)


class ProviderStrategyTests(unittest.TestCase):
    def test_prephase2_low_signal_defaults_to_a0(self):
        ir = {
            "entry_points": [],
            "sources": [],
            "sinks": [],
            "anomalies": [],
            "coverage_gaps": [],
        }
        policy = provider_strategy.resolve_prephase2_policy(
            "demo",
            ir,
            None,
            None,
            None,
        )
        self.assertEqual(policy["tier_id"], "A0")
        self.assertEqual(policy["stage_providers"]["worker"], "codex")
        self.assertEqual(policy["stage_providers"]["cluster_challenger"], "codex")

    def test_prephase2_high_value_potential_resolves_to_a2(self):
        ir = {
            "entry_points": [
                {"id": "ep_ajax_demo", "auth_level": "none"},
                {"id": "ep_rest_demo", "auth_level": "none"},
            ],
            "sources": [{"type": "rest_json"}],
            "sinks": [
                {"category": "sql"},
                {"category": "remote_request"},
            ],
            "anomalies": [{} for _ in range(3)],
            "coverage_gaps": [{}, {}],
        }
        policy = provider_strategy.resolve_prephase2_policy(
            "demo",
            ir,
            None,
            None,
            None,
        )
        self.assertEqual(policy["tier_id"], "A2")
        self.assertEqual(policy["stage_providers"]["reviewer_explore"], "claude")
        self.assertEqual(policy["stage_providers"]["cluster_challenger"], "claude")

    def test_prephase2_high_impact_threat_context_resolves_to_a3(self):
        ir = {
            "entry_points": [{"id": "ep_rest_demo", "auth_level": "none"}],
            "sources": [{"type": "rest_json"}],
            "sinks": [{"category": "sql"}],
            "anomalies": [{} for _ in range(9)],
            "coverage_gaps": [{}, {}, {}],
        }
        threat = {
            "matched_categories": ["authorization"],
            "priority_vulns": ["auth_bypass"],
        }
        policy = provider_strategy.resolve_prephase2_policy(
            "demo",
            ir,
            threat,
            None,
            None,
        )
        self.assertEqual(policy["tier_id"], "A3")
        self.assertEqual(policy["phase3_recommendation"]["providers"], ["codex", "claude"])

    def test_postreview_escalates_a1_to_a2_on_high_impact_ambiguity(self):
        base = provider_strategy.base_policy_payload(
            "demo",
            "A1",
            {
                "entry_points": 2,
                "anomalies": 2,
                "coverage_gaps": 0,
                "unauth_ep": 0,
                "sensitive_sinks": 1,
                "sql_sinks": 0,
                "rest_json_sources": 1,
                "output_sinks": 0,
                "source_count": 2,
                "sink_count": 1,
                "sensitive_sink_breakdown": {},
            },
            "deep-elevated",
            10,
            {"matched_categories": [], "priority_vulns": [], "high_impact_priority_vulns": []},
            ["deep_codex_default"],
        )
        policy_doc = {"pre_phase2": base, "post_review": None, "final": dict(base)}
        worker_doc = {
            "findings": [
                {"verdict": "TP", "vuln_type": "arbitrary_file_upload"},
            ]
        }
        review_doc = {
            "review_status": "needs_revision",
            "summary": {"material_issues_found": True},
            "finding_reviews": [{"assessment": "revisit"}],
            "missed_findings": [],
        }
        resolved = provider_strategy.resolve_postreview_policy(policy_doc, worker_doc, review_doc)
        self.assertEqual(resolved["final"]["tier_id"], "A2")
        self.assertTrue(resolved["post_review"]["escalated"])

    def test_postreview_escalates_to_a3_for_stored_high_impact(self):
        base = provider_strategy.base_policy_payload(
            "demo",
            "A2",
            {
                "entry_points": 5,
                "anomalies": 8,
                "coverage_gaps": 2,
                "unauth_ep": 1,
                "sensitive_sinks": 5,
                "sql_sinks": 1,
                "rest_json_sources": 2,
                "output_sinks": 0,
                "source_count": 4,
                "sink_count": 5,
                "sensitive_sink_breakdown": {},
            },
            "deep-extended",
            18,
            {"matched_categories": ["authorization"], "priority_vulns": ["auth_bypass"], "high_impact_priority_vulns": ["auth_bypass"]},
            ["adaptive_profile_deep_extended"],
        )
        policy_doc = {"pre_phase2": base, "post_review": None, "final": dict(base)}
        worker_doc = {
            "findings": [
                {
                    "verdict": "REVIEW",
                    "vuln_type": "privilege_escalation",
                    "storage_key": "demo_option",
                }
            ]
        }
        review_doc = {
            "review_status": "needs_revision",
            "summary": {"material_issues_found": False},
            "finding_reviews": [],
            "missed_findings": [{"finding_id": "f1"}],
        }
        resolved = provider_strategy.resolve_postreview_policy(policy_doc, worker_doc, review_doc)
        self.assertEqual(resolved["final"]["tier_id"], "A3")
        self.assertTrue(resolved["final"]["phase3_recommendation"]["skeptic_enabled"])

    def test_fallback_policy_payload_preserves_explicit_phase3_provider_set(self):
        payload = provider_strategy.fallback_policy_payload(
            "demo",
            worker_provider="codex",
            reviewer_core_provider="codex",
            reviewer_explore_provider="claude",
            cluster_synth_provider="codex",
            cluster_challenger_provider="claude",
            phase3_primary="codex",
            phase3_providers="codex,claude",
            adaptive_profile="deep-extended",
            signal_score=18,
            reasons=["resolver_failed"],
        )
        self.assertEqual(payload["tier_id"], "fallback")
        self.assertEqual(payload["stage_providers"]["reviewer_explore"], "claude")
        self.assertEqual(payload["phase3_recommendation"]["primary_provider"], "codex")
        self.assertEqual(payload["phase3_recommendation"]["providers"], ["codex", "claude"])
        self.assertEqual(payload["phase3_recommendation"]["skeptic_provider"], "claude")


if __name__ == "__main__":
    unittest.main()
