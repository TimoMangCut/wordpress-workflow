import json
import tempfile
import unittest
from pathlib import Path

from tools.bin.normalize_agent_output import normalize_agent_output_path


class NormalizeAgentOutputTests(unittest.TestCase):
    def test_normalize_repairs_invalid_escape_and_schema_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            schema_path = Path(__file__).resolve().parents[2] / "contracts" / "agent-output.schema.json"
            input_path = root / "agent-w09.output.json"
            output_path = root / "normalized.json"
            input_path.write_text(
                """{
  "agent_id": "agent-w09",
  "plugin_slug": "backwpup",
  "execution_time_ms": null,
  "findings": [
    {
      "finding_id": "w09-f1",
      "verdict": "CONFIRMED",
      "vuln_type": "path_traversal",
      "severity": "high",
      "auth_required": "privileged",
      "entry_point_id": "ep_demo",
      "source_function": "handle_demo",
      "source_file_path": "/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/plugins/backwpup/inc/admin/class-demo.php",
      "source_line_number": 41,
      "sink_function": "write_file",
      "sink_file_path": "/Volumes/External_Disk/timo/WORDPRESS-PLUGIN-RESEARCH/plugins/backwpup/inc/admin/class-demo.php",
      "sink_line_number": 77,
      "reasoning": "User-controlled path contains ..\\' sequence and still reaches the filesystem sink."
    },
    {
      "finding_id": "w09-f2",
      "verdict": "UNCERTAIN",
      "vuln_type": "broken_access_control",
      "severity": "medium",
      "review_reason": null
    }
  ]
}
""",
                encoding="utf-8",
            )

            normalized, notes = normalize_agent_output_path(
                input_path,
                output_path,
                schema=json.loads(schema_path.read_text(encoding="utf-8")),
            )

            self.assertTrue(output_path.exists())
            self.assertIn("escaped_invalid_backslashes", notes)
            self.assertEqual(normalized["execution_time_ms"], 0)
            self.assertEqual(normalized["findings"][0]["verdict"], "TP")
            self.assertEqual(normalized["findings"][0]["auth_required"], "admin")
            self.assertEqual(normalized["findings"][0]["source_file_path"], "inc/admin/class-demo.php")
            self.assertEqual(normalized["findings"][0]["sink_file_path"], "inc/admin/class-demo.php")
            self.assertEqual(normalized["findings"][1]["verdict"], "REVIEW")
            self.assertTrue(normalized["findings"][1]["review_reason"])

    def test_normalize_downgrades_tp_without_required_evidence_to_review(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            schema_path = Path(__file__).resolve().parents[2] / "contracts" / "agent-output.schema.json"
            input_path = root / "agent-w10.output.json"
            output_path = root / "normalized.json"
            input_path.write_text(
                json.dumps(
                    {
                        "agent_id": "agent-w10",
                        "plugin_slug": "demo",
                        "findings": [
                            {
                                "finding_id": "w10-f1",
                                "verdict": "TP",
                                "vuln_type": "sql_injection",
                                "severity": "high",
                                "auth_required": "none",
                                "reasoning": "Potential SQL injection but the source/sink path is not fully pinned down.",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            normalized, _ = normalize_agent_output_path(
                input_path,
                output_path,
                schema=json.loads(schema_path.read_text(encoding="utf-8")),
            )

            finding = normalized["findings"][0]
            self.assertEqual(finding["verdict"], "REVIEW")
            self.assertEqual(finding["policy_original_verdict"], "TP")
            self.assertIn("missing", finding["review_reason"])
            self.assertTrue(finding["normalization_notes"])

    def test_expected_plugin_slug_overrides_model_slug_and_preserves_provenance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            schema_path = Path(__file__).resolve().parents[2] / "contracts" / "agent-output.schema.json"
            input_path = root / "agent-w11.output.json"
            output_path = root / "normalized.json"
            input_path.write_text(
                json.dumps(
                    {
                        "agent_id": "agent-w11",
                        "plugin_slug": "hallucinated-plugin",
                        "findings": [
                            {
                                "finding_id": "w11-f1",
                                "verdict": "FP",
                                "vuln_type": "xss",
                                "severity": "medium",
                                "auth_required": "none",
                                "fp_reason": "Escaping is already applied.",
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

            normalized, _ = normalize_agent_output_path(
                input_path,
                output_path,
                schema=json.loads(schema_path.read_text(encoding="utf-8")),
                expected_plugin_slug="backwpup",
            )

            self.assertEqual(normalized["plugin_slug"], "backwpup")
            self.assertEqual(normalized["original_plugin_slug"], "hallucinated-plugin")

    def test_normalize_extracts_json_from_prose_transcript(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            schema_path = Path(__file__).resolve().parents[2] / "contracts" / "agent-output.schema.json"
            input_path = root / "agent-w05.last-message.txt"
            output_path = root / "materialized.json"
            input_path.write_text(
                """Analysis complete.

```json
{
  "agent_id": "agent-w05",
  "plugin_slug": "litespeed-cache",
  "execution_time_ms": 0,
  "findings": [
    {
      "finding_id": "w05-f01",
      "verdict": "FP",
      "vuln_type": "xss",
      "severity": "informational",
      "auth_required": "admin",
      "fp_reason": "REST callback return values are JSON encoded, not HTML rendered."
    }
  ]
}
```

This is the complete output JSON. The file should be written to reports/phase2/agents/litespeed-cache/attempts/agent-w05.attempt-01.output.json
""",
                encoding="utf-8",
            )

            normalized, _ = normalize_agent_output_path(
                input_path,
                output_path,
                schema=json.loads(schema_path.read_text(encoding="utf-8")),
                expected_agent_id="agent-w05",
                expected_plugin_slug="litespeed-cache",
            )

            self.assertTrue(output_path.exists())
            self.assertEqual(normalized["agent_id"], "agent-w05")
            self.assertEqual(normalized["plugin_slug"], "litespeed-cache")
            self.assertEqual(normalized["findings"][0]["verdict"], "FP")
