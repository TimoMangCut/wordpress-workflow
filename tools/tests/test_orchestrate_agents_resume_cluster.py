import json
import os
import pathlib
import shutil
import stat
import subprocess
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


class OrchestrateAgentsResumeClusterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.slug = f"test-resume-cluster-{uuid.uuid4().hex[:8]}"
        self.tempdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tempdir.cleanup)
        self.stub_codex = pathlib.Path(self.tempdir.name) / "fake-codex-success.sh"
        self.stub_cluster_builder = pathlib.Path(self.tempdir.name) / "fake-cluster-builder.sh"
        self.cluster_capture = pathlib.Path(self.tempdir.name) / "cluster-builder-capture.json"
        self._write_fake_codex()
        self._write_fake_cluster_builder()
        self._build_resume_fixture()
        self.addCleanup(self._cleanup_artifacts)

    def _write_fake_codex(self) -> None:
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
            "cat >/dev/null\n"
            "python3 - \"$AGENT_OUTPUT_FILE\" \"$AGENT_ID\" \"$AGENT_SLUG\" \"$last_message\" <<'PY'\n"
            "import json, sys\n"
            "output_path, agent_id, slug, last_message = sys.argv[1:5]\n"
            "payload = {\n"
            "    'agent_id': agent_id,\n"
            "    'plugin_slug': slug,\n"
            "    'execution_time_ms': 1,\n"
            "    'findings': [],\n"
            "    'negative_findings': [],\n"
            "}\n"
            "text = json.dumps(payload, indent=2) + '\\n'\n"
            "open(output_path, 'w', encoding='utf-8').write(text)\n"
            "if last_message:\n"
            "    open(last_message, 'w', encoding='utf-8').write(text)\n"
            "PY\n"
            "exit 0\n",
            encoding="utf-8",
        )
        self.stub_codex.chmod(self.stub_codex.stat().st_mode | stat.S_IXUSR)

    def _write_fake_cluster_builder(self) -> None:
        self.stub_cluster_builder.write_text(
            "#!/usr/bin/env python3\n"
            "import json\n"
            "import os\n"
            "import pathlib\n"
            "import sys\n"
            "\n"
            "slug = ''\n"
            "phase2_json = ''\n"
            "reports_dir = ''\n"
            "args = iter(sys.argv[1:])\n"
            "for arg in args:\n"
            "    if arg == '--phase2-json':\n"
            "        phase2_json = next(args)\n"
            "    elif arg == '--reports-dir':\n"
            "        reports_dir = next(args)\n"
            "    elif not slug:\n"
            "        slug = arg\n"
            "capture_path = pathlib.Path(os.environ['STUB_CLUSTER_CAPTURE'])\n"
            "payload = {\n"
            "    'slug': slug,\n"
            "    'phase2_json': phase2_json,\n"
            "    'reports_dir': reports_dir,\n"
            "}\n"
            "capture_path.write_text(json.dumps(payload, indent=2) + '\\n', encoding='utf-8')\n"
            "cluster_plan_path = pathlib.Path(reports_dir) / 'phase2' / f'{slug}-cluster-plan.json'\n"
            "cluster_plan_path.write_text(json.dumps({'plugin_slug': slug, 'clusters': []}, indent=2) + '\\n', encoding='utf-8')\n",
            encoding="utf-8",
        )
        self.stub_cluster_builder.chmod(self.stub_cluster_builder.stat().st_mode | stat.S_IXUSR)

    def _build_resume_fixture(self) -> None:
        REPORTS.ensure()
        self.phase1_ir = REPORTS.phase1 / f"{self.slug}-ir.json"
        self.phase2_prep = REPORTS.phase2_prep(self.slug)
        self.phase2_candidates = REPORTS.phase2_prep_candidate_bundles(self.slug)
        self.phase2_agents = REPORTS.phase2_agents(self.slug)
        self.dispatch_path = REPORTS.phase2_dispatch(self.slug)
        self.manifest_path = REPORTS.phase2_dispatch_manifest(self.slug)
        self.inventory_path = REPORTS.phase2_candidate_inventory(self.slug)
        self.bundle_w01 = REPORTS.phase2_candidate_bundle(self.slug, "agent-w01")
        self.bundle_w02 = REPORTS.phase2_candidate_bundle(self.slug, "agent-w02")
        self.threat_context_path = REPORTS.threat_context(self.slug)
        self.phase2_candidates.mkdir(parents=True, exist_ok=True)
        self.phase2_agents.mkdir(parents=True, exist_ok=True)
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
            json.dumps({"plugin_slug": self.slug, "total_bundles": 2}, indent=2) + "\n",
            encoding="utf-8",
        )
        for agent_id, bundle_path in (("agent-w01", self.bundle_w01), ("agent-w02", self.bundle_w02)):
            bundle_path.write_text(
                json.dumps(
                    {
                        "metadata": {"plugin_slug": self.slug},
                        "bundle": {"agent_id": agent_id, "bug_family": "authorization"},
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

        existing_output = REPORTS.phase2_agent_output(self.slug, "agent-w01")
        existing_output.write_text(
            json.dumps(
                {
                    "agent_id": "agent-w01",
                    "plugin_slug": self.slug,
                    "execution_time_ms": 1,
                    "findings": [],
                    "negative_findings": [],
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

        dispatch = {
            "slug": self.slug,
            "agents": ["agent-w01", "agent-w02"],
            "inputs": {
                "agent-w01": f"reports/phase2/prep/{self.slug}/candidate-bundles/agent-w01.input.json",
                "agent-w02": f"reports/phase2/prep/{self.slug}/candidate-bundles/agent-w02.input.json",
            },
            "source_dir": f"plugins/{self.slug}/",
            "timeout_seconds": 30,
            "default_provider": "codex",
            "provider_map": {
                "agent-w01": "codex",
                "agent-w02": "codex",
            },
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
                dispatch_input_entry(ROOT, "agent-w01", self.bundle_w01, origin="bundle"),
                dispatch_input_entry(ROOT, "agent-w02", self.bundle_w02, origin="bundle"),
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
            REPORTS.phase2_local_output(self.slug),
            REPORTS.phase2 / f"{self.slug}-phase2.merged.json",
            REPORTS.phase2 / f"{self.slug}-phase2.consensus.json",
            REPORTS.phase2 / f"{self.slug}-phase2.json",
            REPORTS.phase2 / f"{self.slug}-cluster-plan.json",
            REPORTS.phase2 / f"{self.slug}-phase2.state.json",
            REPORTS.phase2 / f"{self.slug}-provider-policy.json",
            REPORTS.threat_context(self.slug),
        ]:
            try:
                path.unlink()
            except FileNotFoundError:
                pass

    def test_resume_uses_local_phase2_for_cluster_builder_and_reports_resume_counts(self) -> None:
        env = os.environ.copy()
        env["CODEX_BIN"] = str(self.stub_codex)
        env["PHASE2_CLUSTER_BUILDER"] = str(self.stub_cluster_builder)
        env["STUB_CLUSTER_CAPTURE"] = str(self.cluster_capture)
        env["PHASE2_CLUSTER_PACK_BUILDER"] = str(pathlib.Path(self.tempdir.name) / "missing-pack-builder.sh")
        env["SKIP_QUOTA_PROBE"] = "1"
        env["AUDIT_RUN_ID"] = f"{self.slug}-run"

        result = subprocess.run(
            [
                "bash",
                str(ORCHESTRATOR),
                self.slug,
                "--parallel-limit",
                "1",
                "--resume-missing-only",
                "--no-single-agent-fallback",
            ],
            cwd=ROOT,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=60,
        )

        self.assertEqual(result.returncode, 0, msg=result.stderr)
        self.assertTrue(self.cluster_capture.exists())
        capture = json.loads(self.cluster_capture.read_text(encoding="utf-8"))
        self.assertEqual(
            pathlib.Path(capture["phase2_json"]).resolve(),
            REPORTS.phase2_local_output(self.slug).resolve(),
        )

        summary = json.loads(
            REPORTS.phase2_chunked_run_summary(self.slug).read_text(encoding="utf-8")
        )
        self.assertEqual(summary["completed_this_run_count"], 1)
        self.assertEqual(summary["resume_skipped_count"], 1)
        self.assertEqual(summary["usable_outputs_total"], 2)
        self.assertEqual(summary["expected_agents_total"], 2)

        live_log = REPORTS.phase2_chunked_run_live_log(self.slug).read_text(encoding="utf-8")
        self.assertIn("Completed this run: 1 agent(s)", live_log)
        self.assertIn("Reused existing outputs: 1 agent(s)", live_log)
        self.assertIn("Usable outputs total: 2/2 agent(s) (newly completed=1, reused=1)", live_log)


if __name__ == "__main__":
    unittest.main()
