import importlib.util
import json
import pathlib
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "phase3_llm_review.py"
sys.path.insert(0, str(ROOT / "tools" / "bin"))

spec = importlib.util.spec_from_file_location("phase3_llm_review", MODULE_PATH)
phase3_llm_review = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(phase3_llm_review)


class Phase3LlmReviewMaterializationTests(unittest.TestCase):
    def test_default_template_uses_tagged_no_write_contract(self) -> None:
        template = phase3_llm_review.DEFAULT_TEMPLATE
        self.assertIn("<PHASE3_REVIEW_JSON>", template)
        self.assertIn("<PHASE3_REVIEW_MARKDOWN>", template)
        self.assertNotIn("Write JSON to:", template)
        self.assertNotIn("Write Markdown to:", template)

    def test_materialize_phase3_response_writes_json_and_markdown(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            tmpdir = pathlib.Path(tmp)
            review_output = tmpdir / "review.json"
            markdown_output = tmpdir / "review.md"
            response = """
<PHASE3_REVIEW_JSON>
```json
{"plugin_slug":"demo","reviews":[]}
```
</PHASE3_REVIEW_JSON>
<PHASE3_REVIEW_MARKDOWN>
```markdown
# Plugin Overview

## Validation Summary
```
</PHASE3_REVIEW_MARKDOWN>
"""
            phase3_llm_review.materialize_phase3_response(response, review_output, markdown_output)
            self.assertEqual(json.loads(review_output.read_text(encoding="utf-8"))["plugin_slug"], "demo")
            self.assertIn("# Plugin Overview", markdown_output.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
