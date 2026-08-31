"""Regression tests locking the single-agent review enforcement layer.

Run from the repo root:  python3 -m unittest tools.tests.test_review_enforcement
"""
import copy
import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BIN = REPO_ROOT / "tools" / "bin"
EXAMPLE = REPO_ROOT / "contracts" / "examples"
REVIEW = EXAMPLE / "methodology-review.example.json"
IR = EXAMPLE / "example-ir.json"
INVENTORY = EXAMPLE / "example-inventory.txt"

HAS_JSONSCHEMA = importlib.util.find_spec("jsonschema") is not None


def run(script: str, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(BIN / script), *args],
        capture_output=True, text=True, cwd=str(REPO_ROOT),
    )


def write_tmp(obj: dict) -> str:
    fh = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    json.dump(obj, fh)
    fh.close()
    return fh.name


class TestGoldenExample(unittest.TestCase):
    def test_example_files_exist(self):
        for p in (REVIEW, IR, INVENTORY):
            self.assertTrue(p.exists(), f"missing fixture: {p}")

    @unittest.skipUnless(HAS_JSONSCHEMA, "jsonschema not installed")
    def test_golden_validates(self):
        r = run("validate_review.py", str(REVIEW))
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_golden_passes_gate(self):
        r = run("complete_gate.py", str(REVIEW), "--ir", str(IR), "--inventory", str(INVENTORY))
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("GATE PASSED", r.stdout)


class TestGateFailsClosed(unittest.TestCase):
    def setUp(self):
        self.review = json.loads(REVIEW.read_text())

    def test_missing_tool_artifacts_fail(self):
        r = run("complete_gate.py", str(REVIEW), "--slug", "no-such-slug-xyz")
        self.assertEqual(r.returncode, 1)
        self.assertIn("ir.json missing", r.stdout)

    def test_unanchored_refutation_fails(self):
        broken = copy.deepcopy(self.review)
        broken["findings"][0]["refutations"][0]["locations"] = []
        path = write_tmp(broken)
        r = run("complete_gate.py", path, "--ir", str(IR), "--inventory", str(INVENTORY))
        self.assertEqual(r.returncode, 1)
        self.assertIn("anchored refutation", r.stdout)

    def test_unresolved_surface_without_disposition_fails(self):
        broken = copy.deepcopy(self.review)
        for s in broken["coverage"]["surfaces"]:
            if s.get("status") == "UNRESOLVED":
                s["notes"] = []
        path = write_tmp(broken)
        r = run("complete_gate.py", path, "--ir", str(IR), "--inventory", str(INVENTORY))
        self.assertEqual(r.returncode, 1)
        self.assertIn("UNRESOLVED disposition", r.stdout)


class TestMetricsRun(unittest.TestCase):
    def test_single_metrics(self):
        r = run("review_metrics.py", str(REVIEW), "--ir", str(IR), "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        data = json.loads(r.stdout)
        self.assertEqual(data["metrics"]["ir_coverage_gaps_accounted_pct"], 100.0)
        self.assertEqual(data["metrics"]["findings_anchored_refutation_pct"], 100.0)

    def test_stability_identical_is_100(self):
        r = run("review_metrics.py", str(REVIEW), "--compare", str(REVIEW), "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(json.loads(r.stdout)["stability"]["jaccard_overlap_pct"], 100.0)


if __name__ == "__main__":
    unittest.main()
