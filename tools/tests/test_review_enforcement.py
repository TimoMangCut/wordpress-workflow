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

    def test_empty_hookname_obligation_is_not_falsely_accounted(self):
        """Regression: an unresolved_hook with an empty hook_name that the review never
        mentions must NOT count as accounted (the empty string is a substring of everything)."""
        from tools.bin import review_metrics  # noqa: PLC0415
        ir = {"unresolved_hooks": [{"file": "includes/unmentioned.php", "line": 1, "hook_arg_type": "constant"}],
              "coverage_gaps": [], "entry_points": []}
        review = {"coverage": {"gaps": [], "files_reviewed": [], "surfaces": [], "secure_areas": []}, "findings": []}
        m = review_metrics.single_metrics(review, ir)
        self.assertEqual(m["ir_unresolved_hooks_accounted_pct"], 0.0)


SYNTH_IR = {
    "metadata": {"plugin_slug": "t"},
    "entry_points": [
        {"id": "e4", "type": "admin_init", "hook_name": "admin_init", "auth_level": "unknown", "file": "d.php", "line": 1, "callback": {"type": "function", "name": "g"}},
        {"id": "e3", "type": "ajax_priv", "hook_name": "wp_ajax_c", "auth_level": "subscriber", "file": "c.php", "line": 1, "callback": {"type": "method", "name": "c", "class": "C", "file": "c.php", "line_start": 1, "line_end": 2}},
        {"id": "e2", "type": "rest_route", "hook_name": "rest_x", "auth_level": "unknown", "file": "b.php", "line": 1, "callback": {"type": "function", "name": "f"}},
        {"id": "e1", "type": "ajax_nopriv", "hook_name": "wp_ajax_nopriv_a", "auth_level": "none", "file": "a.php", "line": 1, "callback": {"type": "method", "name": "a", "class": "C", "file": "a.php", "line_start": 1, "line_end": 2}},
    ],
    "sources": [{"id": "s1", "entry_point_id": "e1", "type": "superglobal_post", "variable": "$_POST", "key": "q", "file": "a.php", "line": 2}],
    "sinks": [{"id": "k1", "entry_point_id": "e1", "category": "sql", "function_called": "query", "uses_prepared_statement": False, "file": "a.php", "line": 2}],
    "guards": [], "anomalies": [],
    "unresolved_hooks": [{"file": "z.php", "line": 1}],
    "coverage_gaps": [{"file": "y.php", "signals": ["x"], "reason": "r"}],
}


class TestSlicer(unittest.TestCase):
    def test_priority_order_and_linkage(self):
        from tools.bin import slice_ir  # noqa: PLC0415
        batches = slice_ir.order_and_batch(SYNTH_IR, batch_size=12)
        buckets = [b for b, _eps in batches]
        # unauth-ajax(0) before unauth-rest(1) before auth-ajax(2) before bootstrap(5)
        self.assertEqual(buckets, sorted(buckets))
        self.assertEqual(batches[0][0], 0)
        self.assertEqual(batches[0][1][0]["id"], "e1")
        sl = slice_ir.build_slice(SYNTH_IR, batches[0][1])
        self.assertEqual([s["id"] for s in sl["sinks"]], ["k1"])  # linked by entry_point_id
        self.assertEqual(sl["unresolved_hooks"], [])  # backstop stays with full IR
        self.assertEqual(sl["coverage_gaps"], [])

    @unittest.skipUnless(HAS_JSONSCHEMA, "jsonschema not installed")
    def test_cli_slices_validate(self):
        import tempfile as _tf
        ir_path = write_tmp(SYNTH_IR)
        out = _tf.mkdtemp()
        r = run("slice_ir.py", ir_path, "--out", out, "--slug", "t", "--batch-size", "12", "--validate")
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        plan = json.loads((Path(out) / "slice-plan.json").read_text())
        self.assertEqual(plan["total_entry_points"], 4)
        self.assertEqual(plan["batches"][0]["bucket_label"], "unauth-ajax")


if __name__ == "__main__":
    unittest.main()
