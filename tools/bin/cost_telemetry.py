#!/usr/bin/env python3
"""Cost/usage telemetry helpers for workflow runs."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def maybe_int(value: str | None) -> int | None:
    if value in (None, "", "null", "None"):
        return None
    try:
        return int(value)
    except Exception:
        return None


def maybe_float(value: Any) -> float | None:
    if value in (None, "", "null", "None"):
        return None
    try:
        return float(value)
    except Exception:
        return None


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    items: list[dict[str, Any]] = []
    if not path.exists():
        return items
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if isinstance(obj, dict):
            items.append(obj)
    return items


def parse_claude_raw_usage(raw_log_path: Path) -> dict[str, Any]:
    if not raw_log_path.exists():
        return {"usage_source": "unavailable", "usage_error": "raw_log_missing"}

    latest_result: dict[str, Any] | None = None
    for raw in raw_log_path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if isinstance(obj, dict) and obj.get("type") == "result":
            latest_result = obj

    if latest_result is None:
        return {"usage_source": "unavailable", "usage_error": "no_result_event"}

    usage = latest_result.get("usage") if isinstance(latest_result.get("usage"), dict) else {}
    model_usage = latest_result.get("modelUsage") if isinstance(latest_result.get("modelUsage"), dict) else {}

    token_input = maybe_int(str(usage.get("input_tokens", "")))
    token_output = maybe_int(str(usage.get("output_tokens", "")))
    cache_creation = maybe_int(str(usage.get("cache_creation_input_tokens", "")))
    cache_read = maybe_int(str(usage.get("cache_read_input_tokens", "")))

    total_cost_usd = maybe_float(latest_result.get("total_cost_usd"))
    if total_cost_usd is None and model_usage:
        running_total = 0.0
        found_any = False
        for details in model_usage.values():
            if not isinstance(details, dict):
                continue
            value = maybe_float(details.get("costUSD"))
            if value is None:
                continue
            found_any = True
            running_total += value
        if found_any:
            total_cost_usd = running_total

    token_total = sum(
        value or 0
        for value in (token_input, token_output, cache_creation, cache_read)
    )

    payload = {
        "usage_source": "claude_stream_result",
        "token_input": token_input,
        "token_output": token_output,
        "token_total": token_total,
        "cache_creation_input_tokens": cache_creation,
        "cache_read_input_tokens": cache_read,
        "cost_estimate": total_cost_usd,
        "cost_currency": "USD" if total_cost_usd is not None else None,
        "duration_ms": maybe_int(str(latest_result.get("duration_ms", ""))),
        "provider_result_model_usage": model_usage or None,
    }
    return payload


def tracking_url_from_base(base_url: str) -> str:
    base = (base_url or "").strip().rstrip("/")
    if not base:
        return ""
    if base.endswith("/v1"):
        return f"{base}/tracking"
    return f"{base}/v1/tracking"


def fetch_tracking_snapshot(base_url: str, token: str) -> dict[str, Any]:
    tracking_url = tracking_url_from_base(base_url)
    snapshot: dict[str, Any] = {
        "captured_at": utc_now(),
        "base_url": base_url or None,
        "tracking_url": tracking_url or None,
        "tracking_supported": False,
    }
    if not tracking_url:
        snapshot["error"] = "missing_base_url"
        return snapshot
    if not token:
        snapshot["error"] = "missing_auth_token"
        return snapshot

    request = urllib.request.Request(
        tracking_url,
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode("utf-8", errors="replace"))
    except urllib.error.HTTPError as exc:
        snapshot["error"] = f"http_{exc.code}"
        return snapshot
    except Exception as exc:
        snapshot["error"] = f"{type(exc).__name__}: {exc}"
        return snapshot

    snapshot.update(
        {
            "tracking_supported": True,
            "balance_vnd": maybe_float(payload.get("balance")),
            "total_spent_vnd": maybe_float(payload.get("total_spent")),
            "total_requests": maybe_int(str(payload.get("total_requests", ""))),
            "success_rate": maybe_float(payload.get("success_rate")),
            "avg_last5_tokens": maybe_float(payload.get("avg_last5_tokens")),
            "avg_last5_cost_vnd": maybe_float(payload.get("avg_last5_cost")),
            "last_request": payload.get("last_request") if isinstance(payload.get("last_request"), dict) else None,
            "models": payload.get("models") if isinstance(payload.get("models"), list) else None,
        }
    )
    return snapshot


def append_ledger_event(args: argparse.Namespace) -> int:
    raw_log_path = Path(args.raw_log_path).resolve() if args.raw_log_path else None
    payload: dict[str, Any] = {
        "ts": utc_now(),
        "phase": args.phase,
        "slug": args.slug,
        "run_id": args.run_id or None,
        "mode": args.mode,
        "provider": args.provider,
        "model": args.model or None,
        "status": args.status,
        "duration_sec": maybe_int(args.duration),
        "component": args.component or None,
        "role": args.role or None,
        "agent_id": args.agent_id or None,
        "cluster_id": args.cluster_id or None,
        "attempt": maybe_int(args.attempt),
        "timeout_sec": maybe_int(args.timeout_seconds),
        "quota_signal": args.quota_signal or None,
        "input_path": args.input_path or None,
        "output_path": args.output_path or None,
        "errlog_path": args.errlog_path or None,
        "live_log_path": args.live_log_path or None,
        "raw_log_path": str(raw_log_path) if raw_log_path else None,
        "token_input": None,
        "token_output": None,
        "token_total": None,
        "cache_creation_input_tokens": None,
        "cache_read_input_tokens": None,
        "cost_estimate": None,
        "cost_currency": None,
        "duration_ms": None,
        "usage_source": "unavailable",
    }

    if args.provider == "claude" and raw_log_path:
        payload.update(parse_claude_raw_usage(raw_log_path))

    ledger_path = Path(args.ledger).resolve()
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    with ledger_path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(payload, separators=(",", ":")) + "\n")
    return 0


def write_tracking_snapshot(args: argparse.Namespace) -> int:
    snapshot = fetch_tracking_snapshot(
        base_url=args.base_url or os.environ.get("ANTHROPIC_BASE_URL", ""),
        token=args.token or os.environ.get("ANTHROPIC_AUTH_TOKEN", ""),
    )
    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
    print(output_path.as_posix())
    return 0


def summarize_group(events: list[dict[str, Any]], key_name: str) -> dict[str, dict[str, Any]]:
    groups: dict[str, dict[str, Any]] = defaultdict(
        lambda: {
            "calls": 0,
            "ok": 0,
            "failed": 0,
            "duration_sec": 0,
            "token_input": 0,
            "token_output": 0,
            "token_total": 0,
            "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": 0,
            "cost_usd": 0.0,
        }
    )
    for event in events:
        default_value = "unavailable" if key_name == "usage_source" else "unknown"
        key = str(event.get(key_name) or default_value)
        bucket = groups[key]
        bucket["calls"] += 1
        if str(event.get("status")) == "ok":
            bucket["ok"] += 1
        else:
            bucket["failed"] += 1
        bucket["duration_sec"] += int(event.get("duration_sec") or 0)
        bucket["token_input"] += int(event.get("token_input") or 0)
        bucket["token_output"] += int(event.get("token_output") or 0)
        bucket["token_total"] += int(event.get("token_total") or 0)
        bucket["cache_creation_input_tokens"] += int(event.get("cache_creation_input_tokens") or 0)
        bucket["cache_read_input_tokens"] += int(event.get("cache_read_input_tokens") or 0)
        bucket["cost_usd"] += float(event.get("cost_estimate") or 0.0)
    return dict(sorted(groups.items()))


def summarize_run(args: argparse.Namespace) -> int:
    ledger_path = Path(args.ledger).resolve()
    events = load_json_lines(ledger_path)
    filtered = [
        event for event in events
        if (not args.run_id or event.get("run_id") == args.run_id)
        and (not args.slug or event.get("slug") == args.slug)
    ]

    totals = {
        "calls": 0,
        "ok": 0,
        "failed": 0,
        "duration_sec": 0,
        "token_input": 0,
        "token_output": 0,
        "token_total": 0,
        "cache_creation_input_tokens": 0,
        "cache_read_input_tokens": 0,
        "cost_usd": 0.0,
    }
    for event in filtered:
        totals["calls"] += 1
        if str(event.get("status")) == "ok":
            totals["ok"] += 1
        else:
            totals["failed"] += 1
        totals["duration_sec"] += int(event.get("duration_sec") or 0)
        totals["token_input"] += int(event.get("token_input") or 0)
        totals["token_output"] += int(event.get("token_output") or 0)
        totals["token_total"] += int(event.get("token_total") or 0)
        totals["cache_creation_input_tokens"] += int(event.get("cache_creation_input_tokens") or 0)
        totals["cache_read_input_tokens"] += int(event.get("cache_read_input_tokens") or 0)
        totals["cost_usd"] += float(event.get("cost_estimate") or 0.0)

    before = None
    after = None
    if args.before and Path(args.before).exists():
        before = json.loads(Path(args.before).read_text(encoding="utf-8"))
    if args.after and Path(args.after).exists():
        after = json.loads(Path(args.after).read_text(encoding="utf-8"))

    balance_before = maybe_float(before.get("balance_vnd")) if isinstance(before, dict) else None
    balance_after = maybe_float(after.get("balance_vnd")) if isinstance(after, dict) else None
    balance_delta = None
    if balance_before is not None and balance_after is not None:
        balance_delta = balance_before - balance_after

    provider_strategy = None
    if getattr(args, "provider_policy", "") and Path(args.provider_policy).exists():
        try:
            provider_strategy = json.loads(Path(args.provider_policy).read_text(encoding="utf-8"))
        except Exception:
            provider_strategy = {"load_error": "invalid_provider_policy_json", "path": str(Path(args.provider_policy).resolve())}

    payload = {
        "generated_at": utc_now(),
        "run_id": args.run_id or None,
        "plugin_slug": args.slug or None,
        "exit_code": maybe_int(args.exit_code),
        "execution_status": args.execution_status or None,
        "ledger_path": ledger_path.as_posix(),
        "event_count": len(filtered),
        "totals": totals,
        "tracking": {
            "before": before,
            "after": after,
            "balance_before_vnd": balance_before,
            "balance_after_vnd": balance_after,
            "balance_delta_vnd": balance_delta,
        },
        "by_phase": summarize_group(filtered, "phase"),
        "by_provider": summarize_group(filtered, "provider"),
        "by_model": summarize_group(filtered, "model"),
        "by_component": summarize_group(filtered, "component"),
        "by_role": summarize_group(filtered, "role"),
        "by_mode": summarize_group(filtered, "mode"),
        "by_agent": summarize_group(filtered, "agent_id"),
        "by_cluster": summarize_group(filtered, "cluster_id"),
        "by_usage_source": summarize_group(filtered, "usage_source"),
        "usage_availability": {
            "available_calls": sum(1 for event in filtered if str(event.get("usage_source") or "unavailable") != "unavailable"),
            "unavailable_calls": sum(1 for event in filtered if str(event.get("usage_source") or "unavailable") == "unavailable"),
        },
        "provider_strategy": provider_strategy,
    }

    output_path = Path(args.output).resolve()
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(output_path.as_posix())
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Cost telemetry helpers.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    append_parser = sub.add_parser("append-event", help="Append one usage event to the quota ledger.")
    append_parser.add_argument("--ledger", required=True)
    append_parser.add_argument("--phase", required=True)
    append_parser.add_argument("--slug", required=True)
    append_parser.add_argument("--run-id", default="")
    append_parser.add_argument("--mode", required=True)
    append_parser.add_argument("--provider", required=True)
    append_parser.add_argument("--model", default="")
    append_parser.add_argument("--status", required=True)
    append_parser.add_argument("--duration", default="")
    append_parser.add_argument("--component", default="")
    append_parser.add_argument("--role", default="")
    append_parser.add_argument("--agent-id", default="")
    append_parser.add_argument("--cluster-id", default="")
    append_parser.add_argument("--attempt", default="")
    append_parser.add_argument("--timeout-seconds", default="")
    append_parser.add_argument("--quota-signal", default="")
    append_parser.add_argument("--input-path", default="")
    append_parser.add_argument("--output-path", default="")
    append_parser.add_argument("--errlog-path", default="")
    append_parser.add_argument("--live-log-path", default="")
    append_parser.add_argument("--raw-log-path", default="")
    append_parser.set_defaults(func=append_ledger_event)

    tracking_parser = sub.add_parser("tracking-snapshot", help="Write a provider tracking snapshot.")
    tracking_parser.add_argument("--output", required=True)
    tracking_parser.add_argument("--base-url", default="")
    tracking_parser.add_argument("--token", default="")
    tracking_parser.set_defaults(func=write_tracking_snapshot)

    summary_parser = sub.add_parser("summarize-run", help="Summarize quota ledger events for a run.")
    summary_parser.add_argument("--ledger", required=True)
    summary_parser.add_argument("--run-id", default="")
    summary_parser.add_argument("--slug", default="")
    summary_parser.add_argument("--before", default="")
    summary_parser.add_argument("--after", default="")
    summary_parser.add_argument("--output", required=True)
    summary_parser.add_argument("--exit-code", default="")
    summary_parser.add_argument("--execution-status", default="")
    summary_parser.add_argument("--provider-policy", default="")
    summary_parser.set_defaults(func=summarize_run)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
