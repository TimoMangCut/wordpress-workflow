#!/usr/bin/env python3

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "tools" / "bin"))

from artifact_freshness import (
    is_fresh,
    is_trusted_phase2_output,
    newest_mtime,
    resolve_canonical_phase3_path,
    resolve_phase2_closure_complete,
    resolve_phase2_trust_state,
)


class ArtifactFreshnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write(self, rel_path: str, *, mtime: int) -> Path:
        path = self.root / rel_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(rel_path, encoding="utf-8")
        path.touch()
        path.chmod(0o644)
        path_ts = float(mtime)
        os.utime(path, (path_ts, path_ts))
        return path

    def test_newest_mtime_recurses_directories(self) -> None:
        source_dir = self.root / "plugin"
        source_dir.mkdir(parents=True, exist_ok=True)
        os.utime(source_dir, (100.0, 100.0))
        nested = self._write("plugin/includes/controller.php", mtime=250)

        self.assertGreaterEqual(newest_mtime(source_dir), newest_mtime(nested))

    def test_is_fresh_true_when_output_newer_than_all_inputs(self) -> None:
        output = self._write("reports/phase2/demo-phase2.json", mtime=300)
        ir = self._write("reports/phase1/demo-ir.json", mtime=200)
        prompt = self._write("tools/config/phase2-prompt-template.md", mtime=250)

        self.assertTrue(is_fresh(output, [ir, prompt]))

    def test_is_fresh_false_when_any_input_is_newer(self) -> None:
        output = self._write("reports/phase2/demo-phase2.json", mtime=300)
        ir = self._write("reports/phase1/demo-ir.json", mtime=400)

        self.assertFalse(is_fresh(output, [ir]))

    def test_resolve_canonical_phase3_prefers_gate_when_final_is_older(self) -> None:
        phase3_dir = self.root / "reports" / "phase3"
        gate = self._write("reports/phase3/demo-phase3.json", mtime=500)
        self._write("reports/phase3/demo-phase3.final.json", mtime=450)

        self.assertEqual(resolve_canonical_phase3_path(phase3_dir, "demo"), gate)

    def test_resolve_canonical_phase3_prefers_final_when_not_older(self) -> None:
        phase3_dir = self.root / "reports" / "phase3"
        self._write("reports/phase3/demo-phase3.json", mtime=500)
        final = self._write("reports/phase3/demo-phase3.final.json", mtime=500)

        self.assertEqual(resolve_canonical_phase3_path(phase3_dir, "demo"), final)

    def test_resolve_canonical_phase3_uses_gate_when_final_missing(self) -> None:
        phase3_dir = self.root / "reports" / "phase3"
        gate = self._write("reports/phase3/demo-phase3.json", mtime=500)

        self.assertEqual(resolve_canonical_phase3_path(phase3_dir, "demo"), gate)

    def test_resolve_phase2_trust_state_prefers_top_level_value(self) -> None:
        phase2 = self.root / "reports" / "phase2" / "demo-phase2.json"
        phase2.parent.mkdir(parents=True, exist_ok=True)
        phase2.write_text(
            '{"trust_state":"success","merge_stats":{"trust_state":"degraded_success"}}',
            encoding="utf-8",
        )

        self.assertEqual(resolve_phase2_trust_state(phase2), "success")
        self.assertIsNone(resolve_phase2_closure_complete(phase2))
        self.assertTrue(is_trusted_phase2_output(phase2))

    def test_resolve_phase2_trust_state_falls_back_to_consensus(self) -> None:
        phase2 = self.root / "reports" / "phase2" / "demo-phase2.json"
        phase2.parent.mkdir(parents=True, exist_ok=True)
        phase2.write_text(
            '{"consensus":{"trust_state":"degraded_success","degradation_signals":["x"]}}',
            encoding="utf-8",
        )

        self.assertEqual(resolve_phase2_trust_state(phase2), "degraded_success")
        self.assertFalse(is_trusted_phase2_output(phase2))

    def test_success_trust_is_not_trusted_when_closure_incomplete(self) -> None:
        phase2 = self.root / "reports" / "phase2" / "demo-phase2.json"
        phase2.parent.mkdir(parents=True, exist_ok=True)
        phase2.write_text(
            '{"trust_state":"success","needs_review":1,"findings":[{"finding_id":"f1","verdict":"REVIEW"}]}',
            encoding="utf-8",
        )

        self.assertEqual(resolve_phase2_trust_state(phase2), "success")
        self.assertFalse(resolve_phase2_closure_complete(phase2))
        self.assertFalse(is_trusted_phase2_output(phase2))

    def test_success_trust_uses_explicit_closure_complete_when_present(self) -> None:
        phase2 = self.root / "reports" / "phase2" / "demo-phase2.json"
        phase2.parent.mkdir(parents=True, exist_ok=True)
        phase2.write_text(
            '{"trust_state":"success","consensus":{"closure_complete":true}}',
            encoding="utf-8",
        )

        self.assertTrue(resolve_phase2_closure_complete(phase2))
        self.assertTrue(is_trusted_phase2_output(phase2))

    def test_resolve_phase2_trust_state_returns_none_for_invalid_json(self) -> None:
        phase2 = self.root / "reports" / "phase2" / "demo-phase2.json"
        phase2.parent.mkdir(parents=True, exist_ok=True)
        phase2.write_text("{invalid", encoding="utf-8")

        self.assertIsNone(resolve_phase2_trust_state(phase2))
        self.assertFalse(is_trusted_phase2_output(phase2))


if __name__ == "__main__":
    unittest.main()
