import importlib.util
import pathlib
import sys
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "phase2_failure_semantics.py"
sys.path.insert(0, str(ROOT / "tools" / "bin"))

spec = importlib.util.spec_from_file_location("phase2_failure_semantics", MODULE_PATH)
phase2_failure_semantics = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(phase2_failure_semantics)


class Phase2FailureSemanticsTests(unittest.TestCase):
    def test_classify_model_capacity(self):
        result = phase2_failure_semantics.classify_provider_failure(
            "ERROR: Selected model is at capacity. Please try a different model."
        )
        self.assertEqual(result["failure_type"], "provider_model_capacity")
        self.assertEqual(result["provider_signal"], "model_at_capacity")

    def test_classify_turn_interrupted(self):
        result = phase2_failure_semantics.classify_provider_failure("turn interrupted")
        self.assertEqual(result["failure_type"], "interrupted_run")
        self.assertEqual(result["provider_signal"], "turn_interrupted")

    def test_classify_503_before_generic_quota(self):
        result = phase2_failure_semantics.classify_provider_failure(
            "ERROR: unexpected status 503 Service Unavailable: Rate limit exceeded. Try again later."
        )
        self.assertEqual(result["failure_type"], "provider_transport_503")
        self.assertEqual(result["provider_signal"], "http_503")

    def test_build_failure_entry_uses_process_exit_code_and_stage(self):
        entry = phase2_failure_semantics.build_failure_entry(
            phase="phase2",
            agent="agent-w08",
            failure_type="provider_model_capacity",
            timestamp="2026-04-10T00:00:00Z",
            retry_count=0,
            resolution="skipped",
            impact="capacity",
            provider="codex",
            process_exit_code=1,
            stderr_excerpt="capacity",
            attempt=1,
            retry_index=0,
            retry_limit=3,
        )
        self.assertEqual(entry["failure_stage"], "worker")
        self.assertEqual(entry["process_exit_code"], "1")
        self.assertNotIn("preflight_exit_code", entry)

    def test_summary_marks_done_agents_as_superseding_prior_failures(self):
        failures = [
            {
                "phase": "phase2",
                "agent": "agent-w01",
                "failure_type": "provider_transport_503",
                "failure_stage": "worker",
                "timestamp": "2026-04-10T00:00:00Z",
                "retry_count": 0,
                "resolution": "skipped",
                "impact": "retry later",
            },
            {
                "phase": "phase2",
                "agent": "agent-w08",
                "failure_type": "provider_model_capacity",
                "failure_stage": "worker",
                "timestamp": "2026-04-10T00:01:00Z",
                "retry_count": 0,
                "resolution": "skipped",
                "impact": "capacity",
            },
        ]
        final_agents = {
            "agent-w01": {"status": "done", "provider": "codex"},
            "agent-w08": {"status": "failed", "provider": "codex"},
        }
        payload = phase2_failure_semantics.build_chunked_run_summary_payload(
            slug="demo",
            run_id="run-123",
            failures=failures,
            final_agents=final_agents,
            completed_agents=["agent-w01"],
            failed_agents=["agent-w08"],
            resume_skipped_agents=[],
            bundle_review={"started": 1, "stable": 0, "revision_started": 0, "revision_applied": 0, "degraded": 0},
            merge_ready=False,
        )
        self.assertEqual(payload["failure_counts"]["provider_transport_503"], 1)
        self.assertEqual(payload["completed_this_run_count"], 1)
        self.assertEqual(payload["resume_skipped_count"], 0)
        self.assertEqual(payload["usable_outputs_total"], 0)
        self.assertEqual(payload["expected_agents_total"], 2)
        self.assertEqual(len(payload["superseded_failures"]), 1)
        self.assertEqual(payload["superseded_failures"][0]["agent"], "agent-w01")
        self.assertEqual(payload["terminal_failure_counts"]["provider_model_capacity"], 1)


if __name__ == "__main__":
    unittest.main()
