#!/usr/bin/env python3
"""Failure classification and summary helpers for chunked Phase 2 runs."""

from __future__ import annotations

import argparse
import json
import re
from collections import Counter
from pathlib import Path
from typing import Any


PROVIDER_FAILURE_TYPES = {
    "quota_exhausted_mid_run",
    "provider_model_capacity",
    "provider_transport_503",
    "interrupted_run",
}

FAILURE_STAGE_MAP = {
    "missing_input": "dispatch",
    "missing_input_file": "dispatch",
    "empty_execution_surface": "dispatch",
    "quota_exhausted": "preflight",
    "claude_cli_missing": "preflight",
    "claude_preflight_failed": "preflight",
    "missing_skill_set": "worker",
    "invalid_output_contract": "worker",
    "quota_exhausted_mid_run": "worker",
    "provider_model_capacity": "worker",
    "provider_transport_503": "worker",
    "interrupted_run": "worker",
    "missing_output": "worker",
    "timeout": "worker",
    "all_agents_failed": "orchestration",
    "merge_failed": "merge",
    "cluster_pack_build_failed": "cluster",
    "cluster_build_failed": "cluster",
    "cluster_synth_failed": "cluster",
    "cluster_challenge_failed": "cluster",
    "consensus_write_failed": "consensus",
    "consensus_script_missing": "consensus",
}


def _clean_text(text: str | None) -> str:
    return (text or "").strip()


def classify_provider_failure(log_text: str | None, default_type: str = "missing_output") -> dict[str, str]:
    normalized = _clean_text(log_text).lower()
    if "selected model is at capacity" in normalized:
        return {
            "failure_type": "provider_model_capacity",
            "provider_signal": "model_at_capacity",
        }
    if "turn interrupted" in normalized:
        return {
            "failure_type": "interrupted_run",
            "provider_signal": "turn_interrupted",
        }
    if "unexpected status 503" in normalized or "503 service unavailable" in normalized:
        return {
            "failure_type": "provider_transport_503",
            "provider_signal": "http_503",
        }
    if re.search(r"usage limit|usage exhausted|rate limit|quota", normalized):
        return {
            "failure_type": "quota_exhausted_mid_run",
            "provider_signal": "quota_or_rate_limit",
        }
    return {
        "failure_type": default_type,
        "provider_signal": "",
    }


def infer_failure_stage(failure_type: str) -> str:
    return FAILURE_STAGE_MAP.get(failure_type, "phase2")


def _maybe_int(value: Any) -> int | None:
    if value in ("", None):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def build_failure_entry(
    *,
    phase: str,
    agent: str,
    failure_type: str,
    timestamp: str,
    retry_count: int | str | None,
    resolution: str,
    impact: str,
    provider: str = "",
    quota_account: str = "",
    process_exit_code: int | str | None = None,
    stderr_excerpt: str = "",
    failure_stage: str = "",
    provider_signal: str = "",
    attempt: int | str | None = None,
    retry_index: int | str | None = None,
    retry_limit: int | str | None = None,
) -> dict[str, Any]:
    retry_count_int = _maybe_int(retry_count)
    retry_index_int = _maybe_int(retry_index)
    retry_limit_int = _maybe_int(retry_limit)
    attempt_int = _maybe_int(attempt)
    exit_code_int = _maybe_int(process_exit_code)
    entry: dict[str, Any] = {
        "phase": phase,
        "agent": agent,
        "failure_type": failure_type,
        "failure_stage": failure_stage or infer_failure_stage(failure_type),
        "timestamp": timestamp,
        "retry_count": retry_count_int or 0,
        "resolution": resolution,
        "impact": impact,
    }
    if provider:
        entry["provider"] = provider
    if quota_account:
        entry["quota_account"] = quota_account
    if exit_code_int is not None:
        entry["process_exit_code"] = str(exit_code_int)
    if stderr_excerpt:
        entry["stderr_excerpt"] = stderr_excerpt[:500]
    if provider_signal:
        entry["provider_signal"] = provider_signal
    if attempt_int is not None:
        entry["attempt"] = attempt_int
    if retry_index_int is not None:
        entry["retry_index"] = retry_index_int
    if retry_limit_int is not None:
        entry["retry_limit"] = retry_limit_int
    return entry


def build_chunked_run_summary_payload(
    *,
    slug: str,
    run_id: str,
    failures: list[dict[str, Any]],
    final_agents: dict[str, dict[str, Any]],
    completed_agents: list[str],
    failed_agents: list[str],
    resume_skipped_agents: list[str],
    bundle_review: dict[str, int] | None = None,
    merge_ready: bool = False,
) -> dict[str, Any]:
    failure_counts = Counter(item.get("failure_type", "unknown") for item in failures)
    provider_failure_counts = Counter(
        item.get("failure_type", "unknown")
        for item in failures
        if item.get("failure_type") in PROVIDER_FAILURE_TYPES
    )
    final_status_counts = Counter(
        (data.get("status") or "unknown") for data in final_agents.values()
    )
    superseded_failures: list[dict[str, Any]] = []
    unresolved_failures: list[dict[str, Any]] = []
    terminal_failure_counts: Counter[str] = Counter()
    for item in failures:
        agent = item.get("agent", "")
        agent_state = final_agents.get(agent, {})
        status = agent_state.get("status")
        if status in {"done", "resume_skipped"}:
            superseded = dict(item)
            superseded["superseded_by_final_status"] = status
            superseded_failures.append(superseded)
            continue
        unresolved_failures.append(dict(item))
        terminal_failure_counts[item.get("failure_type", "unknown")] += 1
    completed_this_run_count = len(completed_agents)
    resume_skipped_count = len(resume_skipped_agents)
    expected_agents_total = len(final_agents)
    usable_outputs_total = sum(
        1 for data in final_agents.values() if bool(data.get("output_present"))
    )
    return {
        "slug": slug,
        "run_id": run_id,
        "merge_ready": bool(merge_ready),
        "completed_agents": sorted(completed_agents),
        "completed_this_run_count": completed_this_run_count,
        "failed_agents": sorted(failed_agents),
        "resume_skipped_agents": sorted(resume_skipped_agents),
        "resume_skipped_count": resume_skipped_count,
        "usable_outputs_total": usable_outputs_total,
        "expected_agents_total": expected_agents_total,
        "failure_counts": dict(sorted(failure_counts.items())),
        "provider_failure_counts": dict(sorted(provider_failure_counts.items())),
        "terminal_failure_counts": dict(sorted(terminal_failure_counts.items())),
        "final_status_counts": dict(sorted(final_status_counts.items())),
        "superseded_failures": superseded_failures,
        "unresolved_failures": unresolved_failures,
        "final_agents": final_agents,
        "bundle_review": bundle_review or {},
    }


def _load_json(path: str) -> Any:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _write_json(path: str, payload: Any) -> None:
    Path(path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _command_classify(args: argparse.Namespace) -> int:
    text_parts: list[str] = []
    if args.text:
        text_parts.append(args.text)
    if args.text_file:
        text_parts.append(Path(args.text_file).read_text(encoding="utf-8", errors="ignore"))
    payload = classify_provider_failure("\n".join(text_parts), default_type=args.default_type)
    print(json.dumps(payload))
    return 0


def _command_build_summary(args: argparse.Namespace) -> int:
    failures_doc = _load_json(args.failures_log)
    final_agents = _load_json(args.final_agents_json)
    payload = build_chunked_run_summary_payload(
        slug=args.slug,
        run_id=args.run_id,
        failures=list(failures_doc.get("failures", [])),
        final_agents=final_agents,
        completed_agents=list(args.completed_agent or []),
        failed_agents=list(args.failed_agent or []),
        resume_skipped_agents=list(args.resume_skipped_agent or []),
        bundle_review={
            "started": args.bundle_review_started,
            "stable": args.bundle_review_stable,
            "revision_started": args.bundle_revision_started,
            "revision_applied": args.bundle_revision_applied,
            "degraded": args.bundle_review_degraded,
        },
        merge_ready=args.merge_ready,
    )
    if args.summary_path:
        _write_json(args.summary_path, payload)
    else:
        print(json.dumps(payload, indent=2))
    return 0


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    classify_parser = subparsers.add_parser("classify", help="Classify provider failure text")
    classify_parser.add_argument("--default-type", default="missing_output")
    classify_parser.add_argument("--text")
    classify_parser.add_argument("--text-file")
    classify_parser.set_defaults(func=_command_classify)

    summary_parser = subparsers.add_parser("build-summary", help="Build chunked run summary JSON")
    summary_parser.add_argument("--slug", required=True)
    summary_parser.add_argument("--run-id", default="")
    summary_parser.add_argument("--failures-log", required=True)
    summary_parser.add_argument("--final-agents-json", required=True)
    summary_parser.add_argument("--summary-path")
    summary_parser.add_argument("--completed-agent", action="append", default=[])
    summary_parser.add_argument("--failed-agent", action="append", default=[])
    summary_parser.add_argument("--resume-skipped-agent", action="append", default=[])
    summary_parser.add_argument("--bundle-review-started", type=int, default=0)
    summary_parser.add_argument("--bundle-review-stable", type=int, default=0)
    summary_parser.add_argument("--bundle-revision-started", type=int, default=0)
    summary_parser.add_argument("--bundle-revision-applied", type=int, default=0)
    summary_parser.add_argument("--bundle-review-degraded", type=int, default=0)
    summary_parser.add_argument("--merge-ready", action="store_true")
    summary_parser.set_defaults(func=_command_build_summary)
    return parser


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
