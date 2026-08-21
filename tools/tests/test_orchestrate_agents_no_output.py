import json
import os
import pathlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import uuid

from tools.bin.phase2_dispatch_manifest import (
    build_dispatch_manifest,
    dispatch_input_entry,
)
from tools.bin.report_paths import build_report_layout


ROOT = pathlib.Path(__file__).resolve().parents[2]
REPORTS = build_report_layout(ROOT / "reports")
ORCHESTRATOR = ROOT / "tools" / "bin" / "orchestrate-agents.sh"


class OrchestrateAgentsNoOutputTests(unittest.TestCase):
    def setUp(self) -> None:
        self.slug = f"test-no-output-{uuid.uuid4().hex[:8]}"
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.stub_codex = pathlib.Path(self.tempdir.name) / "fake-codex.sh"
        self.stub_codex.write_text(
            "#!/usr/bin/env bash\n"
            "set -euo pipefail\n"
            "last_message=\"\"\n"
            "while [[ $# -gt 0 ]]; do\n"
            "  case \"$1\" in\n"
            "    --output-last-message)\n"
            "      last_message=\"$2\"\n"
            "      shift 2\n"
            "      ;;\n"
            "    *)\n"
            "      shift\n"
            "      ;;\n"
            "  esac\n"
            "done\n"
            "if [[ -n \"$last_message\" ]]; then\n"
            "  : > \"$last_message\"\n"
            "fi\n"
            "cat >/dev/null\n"
            "echo 'ERROR: unexpected status 503 Service Unavailable: Rate limit exceeded. Try again later.' >&2\n"
            "exit 1\n",
            encoding="utf-8",
        )
        self.stub_codex.chmod(self.stub_codex.stat().st_mode | stat.S_IXUSR)
        self._build_minimal_dispatch_fixture()
        self.addCleanup(self._cleanup_artifacts)

    def _build_minimal_dispatch_fixture(self) -> None:
        REPORTS.ensure()
        self.phase1_ir = REPORTS.phase1 / f"{self.slug}-ir.json"
        self.phase2_prep = REPORTS.phase2_prep(self.slug)
        self.phase2_prep_candidate_bundles = REPORTS.phase2_prep_candidate_bundles(self.slug)
        self.dispatch_path = REPORTS.phase2_dispatch(self.slug)
        self.manifest_path = REPORTS.phase2_dispatch_manifest(self.slug)
        self.inventory_path = REPORTS.phase2_candidate_inventory(self.slug)
        self.bundle_path = REPORTS.phase2_candidate_bundle(self.slug, "agent-w01")
        self.threat_context_path = REPORTS.threat_context(self.slug)

        self.phase2_prep_candidate_bundles.mkdir(parents=True, exist_ok=True)
        self.threat_context_path.parent.mkdir(parents=True, exist_ok=True)

        self.phase1_ir.write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": self.slug},
                    "entry_points": [],
                    "sources": [],
                    "sinks": [],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.inventory_path.write_text(
            json.dumps({"plugin_slug": self.slug, "total_bundles": 1}, indent=2) + "\n",
            encoding="utf-8",
        )
        self.bundle_path.write_text(
            json.dumps(
                {
                    "metadata": {"plugin_slug": self.slug},
                    "bundle": {"agent_id": "agent-w01", "bug_family": "authorization"},
                    "candidate_hypotheses": [],
                    "entry_points": [],
                    "sources": [],
                    "sinks": [],
                    "guards": [],
                    "anomalies": [],
                    "unresolved_hooks": [],
                    "coverage_gaps": [],
                    "semgrep_results": [],
                    "psalm_results": [],
                    "source_focus_files": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        self.threat_context_path.write_text(
            json.dumps(
                {
                    "plugin_slug": self.slug,
                    "matched_categories": [],
                    "priority_vulns": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        dispatch = {
            "slug": self.slug,
            "agents": ["agent-w01"],
            "inputs": {
                "agent-w01": f"reports/phase2/prep/{self.slug}/candidate-bundles/agent-w01.input.json",
            },
            "source_dir": f"plugins/{self.slug}/",
            "timeout_seconds": 5,
            "default_provider": "codex",
            "provider_map": {"agent-w01": "codex"},
            "reviewer_provider": "codex",
            "reviewer_model": "",
            "bundle_review_enabled": False,
            "review_rounds": 0,
            "bundle_inventory": f"reports/phase2/prep/{self.slug}/candidate-inventory.json",
            "threat_context_path": f"reports/context/{self.slug}-threat-context.json",
        }
        self.dispatch_path.write_text(json.dumps(dispatch, indent=2) + "\n", encoding="utf-8")

        manifest = build_dispatch_manifest(
            repo_root=ROOT,
            slug=self.slug,
            source_dir=f"plugins/{self.slug}/",
            run_id=f"{self.slug}-run",
            dispatch_path=self.dispatch_path,
            inventory_path=self.inventory_path,
            ir_path=self.phase1_ir,
            semgrep_path=None,
            psalm_path=None,
            threat_context_path=self.threat_context_path,
            provider_policy_path=None,
            dispatch_inputs=[
                dispatch_input_entry(ROOT, "agent-w01", self.bundle_path, origin="bundle")
            ],
        )
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    def _cleanup_artifacts(self) -> None:
        for path in [
            REPORTS.phase2_prep(self.slug),
            REPORTS.phase2_agents(self.slug),
            REPORTS.slug_logs(self.slug),
            REPORTS.cost_slug_dir(self.slug),
        ]:
            shutil.rmtree(path, ignore_errors=True)
        for path in [
            REPORTS.phase1 / f"{self.slug}-ir.json",
            REPORTS.phase2 / f"{self.slug}-phase2.local.json",
            REPORTS.phase2 / f"{self.slug}-phase2.merged.json",
            REPORTS.phase2 / f"{self.slug}-phase2.json",
            REPORTS.phase2 / f"{self.slug}-phase2.state.json",
            REPORTS.phase2 / f"{self.slug}-provider-policy.json",
            REPORTS.threat_context(self.slug),
        ]:
            try:
                path.unlink()
            except FileNotFoundError:
                pass

    def test_no_output_rate_limit_path_retries_then_fails_cleanly(self) -> None:
        env = os.environ.copy()
        env["CODEX_BIN"] = str(self.stub_codex)
        env["SKIP_QUOTA_PROBE"] = "1"
        env["ORCHESTRATE_POLL_INTERVAL"] = "0"
        env["USAGE_RETRY_BACKOFF_SECONDS"] = "0"
        env["AUDIT_RUN_ID"] = f"{self.slug}-run"

        result = subprocess.run(
            [
                "bash",
                str(ORCHESTRATOR),
                self.slug,
                "--parallel-limit",
                "1",
                "--no-single-agent-fallback",
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=30,
        )

        self.assertEqual(result.returncode, 2, msg=result.stderr)
        self.assertNotIn("local: can only be used in a function", result.stderr)

        run_err = REPORTS.phase2_chunked_run_errlog(self.slug)
        self.assertTrue(run_err.exists())
        run_err_text = run_err.read_text(encoding="utf-8")
        self.assertNotIn("local: can only be used in a function", run_err_text)
        self.assertIn("All agents failed and --no-single-agent-fallback is set.", run_err_text)

        failures_path = REPORTS.phase2_chunked_logs(self.slug) / "failures.json"
        summary_path = REPORTS.phase2_chunked_run_summary(self.slug)
        self.assertTrue(failures_path.exists())
        self.assertTrue(summary_path.exists())

        failures_doc = json.loads(failures_path.read_text(encoding="utf-8"))
        summary_doc = json.loads(summary_path.read_text(encoding="utf-8"))
        agent_failures = [
            item for item in failures_doc["failures"] if item.get("agent") == "agent-w01"
        ]
        self.assertEqual(len(agent_failures), 1)
        self.assertEqual(agent_failures[0]["failure_type"], "provider_transport_503")
        self.assertEqual(agent_failures[0]["provider_signal"], "http_503")
        self.assertEqual(agent_failures[0]["process_exit_code"], "1")
        self.assertEqual(agent_failures[0]["attempt"], 4)
        self.assertEqual(agent_failures[0]["retry_index"], 3)
        self.assertEqual(agent_failures[0]["retry_limit"], 3)

        final_agent = summary_doc["final_agents"]["agent-w01"]
        self.assertEqual(final_agent["status"], "failed")
        self.assertEqual(final_agent["attempt"], 4)
        self.assertEqual(final_agent["terminal_failure_type"], "provider_transport_503")
        self.assertEqual(summary_doc["terminal_failure_counts"]["provider_transport_503"], 1)


if __name__ == "__main__":
    unittest.main()
