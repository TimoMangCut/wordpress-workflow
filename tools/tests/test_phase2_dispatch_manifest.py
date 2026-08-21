import json
import pathlib
import tempfile
import unittest

from tools.bin.phase2_dispatch_manifest import (
    ManifestVerificationError,
    build_dispatch_manifest,
    dispatch_input_entry,
    verify_dispatch_manifest,
)


class Phase2DispatchManifestTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmpdir = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmpdir.cleanup)
        self.repo_root = pathlib.Path(self.tmpdir.name).resolve()
        (self.repo_root / "reports" / "phase1").mkdir(parents=True, exist_ok=True)
        (self.repo_root / "reports" / "phase2" / "prep" / "demo" / "candidate-bundles").mkdir(parents=True, exist_ok=True)
        (self.repo_root / "reports" / "phase2").mkdir(parents=True, exist_ok=True)
        (self.repo_root / "reports" / "context").mkdir(parents=True, exist_ok=True)

        self.ir_path = self.repo_root / "reports" / "phase1" / "demo-ir.json"
        self.semgrep_path = self.repo_root / "reports" / "phase1" / "demo-semgrep.json"
        self.psalm_path = self.repo_root / "reports" / "phase1" / "demo-psalm.sarif"
        self.dispatch_path = self.repo_root / "reports" / "phase2" / "prep" / "demo" / "dispatch.json"
        self.inventory_path = self.repo_root / "reports" / "phase2" / "prep" / "demo" / "candidate-inventory.json"
        self.bundle_path = self.repo_root / "reports" / "phase2" / "prep" / "demo" / "candidate-bundles" / "agent-w01.input.json"
        self.manifest_path = self.repo_root / "reports" / "phase2" / "prep" / "demo" / "dispatch.manifest.json"
        self.policy_path = self.repo_root / "reports" / "phase2" / "demo-provider-policy.json"
        self.threat_context_path = self.repo_root / "reports" / "context" / "demo-threat-context.json"

        self.ir_path.write_text(json.dumps({"metadata": {"plugin_slug": "demo"}, "entry_points": [], "sources": [], "sinks": [], "guards": [], "anomalies": [], "unresolved_hooks": [], "coverage_gaps": []}) + "\n", encoding="utf-8")
        self.semgrep_path.write_text(json.dumps({"results": []}) + "\n", encoding="utf-8")
        self.psalm_path.write_text(json.dumps({"runs": []}) + "\n", encoding="utf-8")
        self.inventory_path.write_text(json.dumps({"plugin_slug": "demo", "total_bundles": 1}) + "\n", encoding="utf-8")
        self.bundle_path.write_text(json.dumps({"metadata": {"plugin_slug": "demo"}, "bundle": {"agent_id": "agent-w01"}, "candidate_hypotheses": [], "entry_points": [], "sources": [], "sinks": [], "guards": [], "anomalies": [], "unresolved_hooks": [], "coverage_gaps": [], "semgrep_results": [], "psalm_results": [], "source_focus_files": []}) + "\n", encoding="utf-8")
        self.policy_path.write_text(json.dumps({"tier": "A0"}) + "\n", encoding="utf-8")
        self.threat_context_path.write_text(json.dumps({"plugin_slug": "demo", "matched_categories": [], "priority_vulns": []}) + "\n", encoding="utf-8")

        dispatch = {
            "slug": "demo",
            "inputs": {
                "agent-w01": "reports/phase2/prep/demo/candidate-bundles/agent-w01.input.json",
            },
            "agents": ["agent-w01"],
            "source_dir": "plugins/demo/",
            "bundle_inventory": "reports/phase2/prep/demo/candidate-inventory.json",
            "threat_context_path": "reports/context/demo-threat-context.json",
        }
        self.dispatch_path.write_text(json.dumps(dispatch, indent=2) + "\n", encoding="utf-8")

    def test_verify_dispatch_manifest_accepts_matching_artifacts(self) -> None:
        manifest = build_dispatch_manifest(
            repo_root=self.repo_root,
            slug="demo",
            source_dir="plugins/demo/",
            run_id="run-1",
            dispatch_path=self.dispatch_path,
            inventory_path=self.inventory_path,
            ir_path=self.ir_path,
            semgrep_path=self.semgrep_path,
            psalm_path=self.psalm_path,
            threat_context_path=self.threat_context_path,
            provider_policy_path=self.policy_path,
            dispatch_inputs=[
                dispatch_input_entry(
                    self.repo_root,
                    "agent-w01",
                    self.bundle_path,
                    origin="bundle",
                )
            ],
        )
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

        verified = verify_dispatch_manifest(
            manifest_path=self.manifest_path,
            repo_root=self.repo_root,
            dispatch_path=self.dispatch_path,
            expected_slug="demo",
        )
        self.assertEqual(verified["plugin_slug"], "demo")

    def test_verify_dispatch_manifest_rejects_tampered_dispatch_input(self) -> None:
        manifest = build_dispatch_manifest(
            repo_root=self.repo_root,
            slug="demo",
            source_dir="plugins/demo/",
            run_id="run-1",
            dispatch_path=self.dispatch_path,
            inventory_path=self.inventory_path,
            ir_path=self.ir_path,
            semgrep_path=self.semgrep_path,
            psalm_path=self.psalm_path,
            threat_context_path=self.threat_context_path,
            provider_policy_path=self.policy_path,
            dispatch_inputs=[
                dispatch_input_entry(
                    self.repo_root,
                    "agent-w01",
                    self.bundle_path,
                    origin="bundle",
                )
            ],
        )
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        self.bundle_path.write_text(self.bundle_path.read_text(encoding="utf-8").replace('"agent-w01"', '"agent-w02"'), encoding="utf-8")

        with self.assertRaises(ManifestVerificationError):
            verify_dispatch_manifest(
                manifest_path=self.manifest_path,
                repo_root=self.repo_root,
                dispatch_path=self.dispatch_path,
                expected_slug="demo",
            )

    def test_verify_dispatch_manifest_rejects_threat_context_mismatch(self) -> None:
        manifest = build_dispatch_manifest(
            repo_root=self.repo_root,
            slug="demo",
            source_dir="plugins/demo/",
            run_id="run-1",
            dispatch_path=self.dispatch_path,
            inventory_path=self.inventory_path,
            ir_path=self.ir_path,
            semgrep_path=self.semgrep_path,
            psalm_path=self.psalm_path,
            threat_context_path=self.threat_context_path,
            provider_policy_path=self.policy_path,
            dispatch_inputs=[
                dispatch_input_entry(
                    self.repo_root,
                    "agent-w01",
                    self.bundle_path,
                    origin="bundle",
                )
            ],
        )
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        dispatch = json.loads(self.dispatch_path.read_text(encoding="utf-8"))
        dispatch["threat_context_path"] = "reports/context/other-threat-context.json"
        self.dispatch_path.write_text(json.dumps(dispatch, indent=2) + "\n", encoding="utf-8")

        with self.assertRaises(ManifestVerificationError):
            verify_dispatch_manifest(
                manifest_path=self.manifest_path,
                repo_root=self.repo_root,
                dispatch_path=self.dispatch_path,
                expected_slug="demo",
            )

    def test_verify_dispatch_manifest_accepts_absolute_dispatch_paths_within_repo(self) -> None:
        dispatch = json.loads(self.dispatch_path.read_text(encoding="utf-8"))
        dispatch["inputs"]["agent-w01"] = str(self.bundle_path.resolve())
        dispatch["bundle_inventory"] = str(self.inventory_path.resolve())
        self.dispatch_path.write_text(json.dumps(dispatch, indent=2) + "\n", encoding="utf-8")

        manifest = build_dispatch_manifest(
            repo_root=self.repo_root,
            slug="demo",
            source_dir="plugins/demo/",
            run_id="run-1",
            dispatch_path=self.dispatch_path,
            inventory_path=self.inventory_path,
            ir_path=self.ir_path,
            semgrep_path=self.semgrep_path,
            psalm_path=self.psalm_path,
            threat_context_path=self.threat_context_path,
            provider_policy_path=self.policy_path,
            dispatch_inputs=[
                dispatch_input_entry(
                    self.repo_root,
                    "agent-w01",
                    self.bundle_path,
                    origin="bundle",
                )
            ],
        )
        self.manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

        verified = verify_dispatch_manifest(
            manifest_path=self.manifest_path,
            repo_root=self.repo_root,
            dispatch_path=self.dispatch_path,
            expected_slug="demo",
        )
        self.assertEqual(verified["plugin_slug"], "demo")


if __name__ == "__main__":
    unittest.main()
