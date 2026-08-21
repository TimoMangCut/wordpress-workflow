import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class Phase3ManualGuardrailsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.reports_dir = self.root / "reports"
        self.plugins_dir = self.root / "plugins"
        (self.reports_dir / "phase1").mkdir(parents=True, exist_ok=True)
        (self.reports_dir / "phase2").mkdir(parents=True, exist_ok=True)
        (self.reports_dir / "phase3").mkdir(parents=True, exist_ok=True)
        (self.plugins_dir / "demo").mkdir(parents=True, exist_ok=True)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def _write_json(self, path: Path, payload: dict) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    def _run(self, script_rel: str, *args: str) -> subprocess.CompletedProcess[str]:
        script = REPO_ROOT / script_rel
        return subprocess.run(
            [sys.executable, str(script), *args],
            cwd=str(REPO_ROOT),
            text=True,
            capture_output=True,
        )

    def _seed_untrusted_phase2(self) -> Path:
        phase2_path = self.reports_dir / "phase2" / "demo-phase2.json"
        self._write_json(
            phase2_path,
            {
                "plugin_slug": "demo",
                "trust_state": "degraded_success",
                "findings": [],
            },
        )
        return phase2_path

    def test_phase3_apply_review_rejects_untrusted_phase2(self) -> None:
        self._seed_untrusted_phase2()
        self._write_json(self.reports_dir / "phase3" / "demo-phase3-review.json", {"reviews": []})

        result = self._run(
            "tools/bin/phase3_apply_review.py",
            "demo",
            "--reports-dir",
            str(self.reports_dir),
            "--plugins-dir",
            str(self.plugins_dir),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("not trusted", result.stdout)

    def test_phase3_llm_review_rejects_untrusted_phase2(self) -> None:
        self._seed_untrusted_phase2()
        self._write_json(self.reports_dir / "phase1" / "demo-ir.json", {"entry_points": []})
        self._write_json(self.reports_dir / "phase3" / "demo-phase3.json", {"phase3_summary": {}, "validated_findings": []})

        result = self._run(
            "tools/bin/phase3_llm_review.py",
            "demo",
            "--reports-dir",
            str(self.reports_dir),
            "--plugins-dir",
            str(self.plugins_dir),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("not trusted", result.stdout)

    def test_phase3_validate_rejects_untrusted_phase2(self) -> None:
        self._seed_untrusted_phase2()
        self._write_json(self.reports_dir / "phase1" / "demo-ir.json", {"entry_points": []})

        result = self._run(
            "tools/bin/phase3-validate.py",
            "demo",
            "--reports-dir",
            str(self.reports_dir),
            "--plugins-dir",
            str(self.plugins_dir),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("not trusted", result.stdout)

    def test_build_candidate_clusters_rejects_untrusted_canonical_default(self) -> None:
        self._seed_untrusted_phase2()

        result = self._run(
            "tools/bin/build_candidate_clusters.py",
            "demo",
            "--reports-dir",
            str(self.reports_dir),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("not trusted", result.stdout)

    def test_phase2_postprocess_blocks_default_canonical_target(self) -> None:
        self._seed_untrusted_phase2()
        (self.plugins_dir / "demo" / "demo.php").write_text("<?php\n", encoding="utf-8")

        result = self._run(
            "tools/bin/phase2_postprocess.py",
            "demo",
            "--reports-dir",
            str(self.reports_dir),
            "--plugins-dir",
            str(self.plugins_dir),
        )

        self.assertEqual(result.returncode, 1)
        self.assertIn("Refusing to postprocess canonical Phase 2", result.stdout)


if __name__ == "__main__":
    unittest.main()
