import pathlib
import unittest


from tools.bin.report_paths import build_report_layout


class ReportPathsTests(unittest.TestCase):
    def test_phase2_layout_paths_are_normalized(self):
        root = pathlib.Path("/tmp/demo-reports").resolve()
        layout = build_report_layout(root)

        self.assertEqual(layout.threat_context("demo"), root / "context" / "demo-threat-context.json")
        self.assertEqual(layout.phase2_dispatch("demo"), root / "phase2" / "prep" / "demo" / "dispatch.json")
        self.assertEqual(layout.phase2_dispatch_manifest("demo"), root / "phase2" / "prep" / "demo" / "dispatch.manifest.json")
        self.assertEqual(layout.phase2_candidate_inventory("demo"), root / "phase2" / "prep" / "demo" / "candidate-inventory.json")
        self.assertEqual(layout.phase2_candidate_bundle("demo", "agent-w01"), root / "phase2" / "prep" / "demo" / "candidate-bundles" / "agent-w01.input.json")
        self.assertEqual(layout.phase2_agent_output("demo", "agent-w01"), root / "phase2" / "agents" / "demo" / "agent-w01.output.json")
        self.assertEqual(layout.phase2_agent_attempt_output("demo", "agent-w01", 2), root / "phase2" / "agents" / "demo" / "attempts" / "agent-w01.attempt-02.output.json")
        self.assertEqual(layout.phase2_agent_attempt_normalized_output("demo", "agent-w01", 2), root / "phase2" / "agents" / "demo" / "attempts" / "agent-w01.attempt-02.normalized.json")
        self.assertEqual(layout.phase2_agent_revision_normalized("demo", "agent-w01", 1), root / "phase2" / "agents" / "demo" / "agent-w01.revision.r1.normalized.json")
        self.assertEqual(layout.phase2_merge_ready("demo"), root / "phase2" / "agents" / "demo" / "merge-ready")
        self.assertEqual(layout.phase2_local_output("demo"), root / "phase2" / "demo-phase2.local.json")
        self.assertEqual(layout.phase2_state("demo"), root / "phase2" / "demo-phase2.state.json")
        self.assertEqual(layout.phase2_chunked_run_live_log("demo"), root / "logs" / "demo" / "phase2" / "chunked" / "run.live.log")
        self.assertEqual(layout.phase2_chunked_run_summary("demo"), root / "logs" / "demo" / "phase2" / "chunked" / "run.summary.json")
        self.assertEqual(layout.phase2_chunked_agent_assistant_live_log("demo", "agent-w01", 1), root / "logs" / "demo" / "phase2" / "chunked" / "agents" / "agent-w01" / "attempt-01" / "assistant.live.log")
        self.assertEqual(layout.phase2_cluster_stage_raw_log("demo", "cluster-c01", "synth"), root / "logs" / "demo" / "phase2" / "cluster" / "cluster-c01.synth.raw.log")
        self.assertEqual(layout.phase3_provider_raw_log("demo", "claude"), root / "logs" / "demo" / "phase3" / "providers" / "claude.raw.log")
        self.assertEqual(layout.final_report("demo", 7), root / "final" / "7-demo.md")
        self.assertEqual(layout.cost_run_summary("demo", "run-123"), root / "cost" / "demo" / "run-123.cost.json")
        self.assertEqual(layout.cost_tracking_snapshot("demo", "run-123", "before"), root / "cost" / "demo" / "run-123.tracking.before.json")


if __name__ == "__main__":
    unittest.main()
