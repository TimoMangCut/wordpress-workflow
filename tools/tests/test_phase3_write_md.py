#!/usr/bin/env python3

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]


class Phase3WriteMarkdownTests(unittest.TestCase):
    def test_phase3_write_md_writes_phase3_and_final_reports(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            reports = root / "reports"
            phase1 = reports / "phase1"
            phase2 = reports / "phase2"
            phase3 = reports / "phase3"
            for path in (phase1, phase2, phase3):
                path.mkdir(parents=True, exist_ok=True)

            slug = "demo"
            (phase1 / f"{slug}-ir.json").write_text(
                json.dumps({"metadata": {"plugin_slug": slug}}, indent=2) + "\n",
                encoding="utf-8",
            )
            (phase1 / f"{slug}-semgrep.json").write_text(json.dumps({"results": []}) + "\n", encoding="utf-8")
            (phase2 / f"{slug}-phase2.json").write_text(
                json.dumps({"plugin_slug": slug, "findings": []}, indent=2) + "\n",
                encoding="utf-8",
            )
            (phase3 / f"{slug}-phase3.json").write_text(
                json.dumps(
                    {
                        "plugin_slug": slug,
                        "phase1_summary": {"entry_points": 0, "anomalies": 0, "sources": 0, "sinks": 0},
                        "phase2_summary": {"total": 0, "tp": 0, "fp": 0, "review": 0},
                        "phase3_summary": {"confirmed": 0, "uncertain": 0, "risk_note": 0, "rejected": 0},
                        "validated_findings": [],
                    },
                    indent=2,
                )
                + "\n",
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    sys.executable,
                    str(REPO_ROOT / "tools" / "bin" / "phase3_write_md.py"),
                    slug,
                    "--reports-dir",
                    str(reports),
                    "--index",
                    "1",
                ],
                cwd=REPO_ROOT,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=60,
            )

            self.assertEqual(result.returncode, 0, msg=result.stdout + result.stderr)
            phase3_md = phase3 / f"1-{slug}.md"
            final_md = reports / "final" / f"1-{slug}.md"
            self.assertTrue(phase3_md.exists())
            self.assertTrue(final_md.exists())
            self.assertEqual(phase3_md.read_text(encoding="utf-8"), final_md.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
