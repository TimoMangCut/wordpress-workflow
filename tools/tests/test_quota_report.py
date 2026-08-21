import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = ROOT / "tools" / "bin" / "quota-report.py"

spec = importlib.util.spec_from_file_location("quota_report", MODULE_PATH)
quota_report = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(quota_report)


class QuotaReportTests(unittest.TestCase):
    def test_run_id_view_breaks_down_phase_model_role_and_usage(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = pathlib.Path(tmpdir)
            reports = root / "reports"
            ledger = reports / "logs" / "quota-ledger.jsonl"
            ledger.parent.mkdir(parents=True)
            ledger.write_text(
                "\n".join(
                    [
                        json.dumps(
                            {
                                "ts": "2026-04-08T01:00:00Z",
                                "phase": "phase2",
                                "slug": "demo",
                                "run_id": "run-1",
                                "mode": "worker-r1-deep",
                                "provider": "claude",
                                "model": "claude-sonnet-4.6",
                                "status": "ok",
                                "duration_sec": 120,
                                "component": "chunked_agent",
                                "role": "worker",
                                "agent_id": "agent-w01",
                                "usage_source": "claude_stream_result",
                                "token_total": 321,
                                "cost_estimate": 0.5,
                            }
                        ),
                        json.dumps(
                            {
                                "ts": "2026-04-08T01:10:00Z",
                                "phase": "phase2",
                                "slug": "demo",
                                "run_id": "run-1",
                                "mode": "review-core",
                                "provider": "codex",
                                "model": "gpt-5.4",
                                "status": "failed",
                                "duration_sec": 30,
                                "component": "review_round",
                                "role": "reviewer",
                                "agent_id": "agent-w01",
                                "usage_source": "unavailable",
                            }
                        ),
                    ]
                )
                + "\n",
                encoding="utf-8",
            )

            with mock.patch.object(
                quota_report,
                "parse_args",
                return_value=quota_report.argparse.Namespace(
                    reports_dir=str(reports),
                    phase="all",
                    days=30,
                    limit=20,
                    run_id="run-1",
                ),
            ):
                buffer = io.StringIO()
                with redirect_stdout(buffer):
                    rc = quota_report.main()
            self.assertEqual(rc, 0)
            output = buffer.getvalue()
            self.assertIn("== By Phase ==", output)
            self.assertIn("== By Model ==", output)
            self.assertIn("== By Role ==", output)
            self.assertIn("== By Usage Source ==", output)
            self.assertIn("usage_available=1", output)
            self.assertIn("usage_unavailable=1", output)


if __name__ == "__main__":
    unittest.main()
