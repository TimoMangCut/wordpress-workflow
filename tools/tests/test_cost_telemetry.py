import importlib.util
import json
import pathlib
import tempfile
import unittest
from argparse import Namespace


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "cost_telemetry.py"

spec = importlib.util.spec_from_file_location("cost_telemetry", MODULE_PATH)
cost_telemetry = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(cost_telemetry)


class CostTelemetryTests(unittest.TestCase):
    def test_parse_claude_raw_usage_from_result_event(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            raw_path = pathlib.Path(tmpdir) / "claude.raw.log"
            raw_path.write_text(
                "\n".join(
                    [
                        json.dumps({"type": "assistant", "message": {"content": [{"type": "text", "text": "hello"}]}}),
                        json.dumps(
                            {
                                "type": "result",
                                "duration_ms": 1234,
                                "total_cost_usd": 0.25,
                                "usage": {
                                    "input_tokens": 10,
                                    "output_tokens": 5,
                                    "cache_creation_input_tokens": 20,
                                    "cache_read_input_tokens": 30,
                                },
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            payload = cost_telemetry.parse_claude_raw_usage(raw_path)
            self.assertEqual(payload["usage_source"], "claude_stream_result")
            self.assertEqual(payload["token_input"], 10)
            self.assertEqual(payload["token_output"], 5)
            self.assertEqual(payload["cache_creation_input_tokens"], 20)
            self.assertEqual(payload["cache_read_input_tokens"], 30)
            self.assertEqual(payload["token_total"], 65)
            self.assertEqual(payload["cost_estimate"], 0.25)
            self.assertEqual(payload["duration_ms"], 1234)

    def test_summarize_run_includes_balance_delta_and_cost_totals(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp = pathlib.Path(tmpdir)
            ledger = tmp / "quota-ledger.jsonl"
            before = tmp / "before.json"
            after = tmp / "after.json"
            provider_policy = tmp / "provider-policy.json"
            output = tmp / "summary.json"

            ledger.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "ts": "2026-04-07T10:00:00Z",
                                "phase": "phase2",
                                "slug": "demo",
                                "run_id": "run-1",
                                "mode": "worker-r1-deep",
                                "provider": "claude",
                                "model": "claude-sonnet-4.6",
                                "status": "ok",
                                "duration_sec": 100,
                                "component": "llm_prompt",
                                "role": "worker",
                                "usage_source": "claude_stream_result",
                                "token_input": 10,
                                "token_output": 5,
                                "token_total": 15,
                                "cache_creation_input_tokens": 100,
                                "cache_read_input_tokens": 50,
                                "cost_estimate": 1.5,
                            }
                        ),
                        json.dumps(
                            {
                                "ts": "2026-04-07T10:05:00Z",
                                "phase": "phase3",
                                "slug": "demo",
                                "run_id": "run-1",
                                "mode": "llm_skeptic",
                                "provider": "codex",
                                "model": "gpt-5.4",
                                "status": "failed",
                                "duration_sec": 20,
                                "component": "phase3_llm_review",
                                "role": "reviewer",
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            before.write_text(json.dumps({"balance_vnd": 1000}), encoding="utf-8")
            after.write_text(json.dumps({"balance_vnd": 900}), encoding="utf-8")
            provider_policy.write_text(
                json.dumps(
                    {
                        "final": {
                            "tier_id": "A2",
                            "stage_providers": {
                                "worker": "codex",
                                "reviewer_explore": "claude",
                            },
                        }
                    }
                ),
                encoding="utf-8",
            )

            rc = cost_telemetry.summarize_run(
                Namespace(
                    ledger=str(ledger),
                    run_id="run-1",
                    slug="demo",
                    before=str(before),
                    after=str(after),
                    provider_policy=str(provider_policy),
                    output=str(output),
                    exit_code="0",
                    execution_status="success",
                )
            )
            self.assertEqual(rc, 0)
            summary = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(summary["event_count"], 2)
            self.assertEqual(summary["totals"]["calls"], 2)
            self.assertEqual(summary["totals"]["ok"], 1)
            self.assertEqual(summary["totals"]["failed"], 1)
            self.assertEqual(summary["totals"]["token_total"], 15)
            self.assertEqual(summary["totals"]["cost_usd"], 1.5)
            self.assertEqual(summary["tracking"]["balance_delta_vnd"], 100.0)
            self.assertEqual(summary["by_phase"]["phase2"]["cost_usd"], 1.5)
            self.assertEqual(summary["by_provider"]["claude"]["token_total"], 15)
            self.assertEqual(summary["by_agent"]["unknown"]["calls"], 2)
            self.assertEqual(summary["by_usage_source"]["unavailable"]["calls"], 1)
            self.assertEqual(summary["usage_availability"]["available_calls"], 1)
            self.assertEqual(summary["usage_availability"]["unavailable_calls"], 1)
            self.assertEqual(summary["provider_strategy"]["final"]["tier_id"], "A2")


if __name__ == "__main__":
    unittest.main()
