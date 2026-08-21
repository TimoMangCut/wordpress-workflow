#!/usr/bin/env python3
"""Summarize LLM usage ledger for quota and per-run cost tracing."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, Iterable, List
import sys

try:
    from .report_paths import build_report_layout
except ImportError:  # pragma: no cover - direct script execution
    _SCRIPT_DIR = Path(__file__).resolve().parent
    if str(_SCRIPT_DIR) not in sys.path:
        sys.path.insert(0, str(_SCRIPT_DIR))
    from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Quota dashboard from reports/logs/quota-ledger.jsonl")
    p.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"))
    p.add_argument("--phase", default="all", choices=["all", "phase2", "phase3"])
    p.add_argument("--days", type=int, default=7, help="Only include last N days (UTC)")
    p.add_argument("--limit", type=int, default=20, help="Top rows for per-plugin section")
    p.add_argument("--run-id", default="", help="Filter to a specific AUDIT_RUN_ID")
    return p.parse_args()


def parse_ts(ts: str) -> dt.datetime:
    if ts.endswith("Z"):
        ts = ts[:-1] + "+00:00"
    return dt.datetime.fromisoformat(ts)


def load_events(path: Path) -> List[Dict[str, Any]]:
    events: List[Dict[str, Any]] = []
    if not path.exists():
        return events
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            item = json.loads(raw)
        except Exception:
            continue
        if isinstance(item, dict):
            events.append(item)
    return events


def empty_bucket() -> Dict[str, float]:
    return {
        "calls": 0,
        "ok": 0,
        "failed": 0,
        "duration": 0.0,
        "tokens": 0.0,
        "cost": 0.0,
        "usage_available": 0,
        "usage_unavailable": 0,
    }


def accumulate(bucket: Dict[str, float], event: Dict[str, Any]) -> None:
    status = str(event.get("status", "unknown"))
    usage_source = str(event.get("usage_source") or "unavailable")
    bucket["calls"] += 1
    bucket["duration"] += float(event.get("duration_sec", 0) or 0)
    bucket["tokens"] += float(event.get("token_total", 0) or 0)
    bucket["cost"] += float(event.get("cost_estimate", 0) or 0)
    if status == "ok":
        bucket["ok"] += 1
    else:
        bucket["failed"] += 1
    if usage_source == "unavailable":
        bucket["usage_unavailable"] += 1
    else:
        bucket["usage_available"] += 1


def summarize_by(events: Iterable[Dict[str, Any]], key_name: str) -> Dict[str, Dict[str, float]]:
    groups: Dict[str, Dict[str, float]] = defaultdict(empty_bucket)
    for event in events:
        key = str(event.get(key_name) or "unknown")
        accumulate(groups[key], event)
    return dict(sorted(groups.items(), key=lambda item: (-item[1]["cost"], item[0])))


def render_table(title: str, headers: List[str], rows: List[List[str]]) -> None:
    print(title)
    if not rows:
        print("  (none)")
        print("")
        return
    widths = [len(header) for header in headers]
    for row in rows:
        for idx, cell in enumerate(row):
            widths[idx] = max(widths[idx], len(cell))
    header_line = " ".join(header.ljust(widths[idx]) for idx, header in enumerate(headers))
    print(header_line)
    for row in rows:
        print(" ".join(cell.ljust(widths[idx]) for idx, cell in enumerate(row)))
    print("")


def bucket_to_row(name: str, bucket: Dict[str, float]) -> List[str]:
    avg = bucket["duration"] / bucket["calls"] if bucket["calls"] else 0
    usage = f"{int(bucket['usage_available'])}/{int(bucket['usage_unavailable'])}"
    return [
        name,
        str(int(bucket["calls"])),
        str(int(bucket["ok"])),
        str(int(bucket["failed"])),
        f"{avg:.1f}",
        str(int(bucket["tokens"])),
        f"{bucket['cost']:.4f}",
        usage,
    ]


def main() -> int:
    args = parse_args()
    reports_dir = Path(args.reports_dir).resolve()
    ledger = build_report_layout(reports_dir).ensure().quota_ledger
    events = load_events(ledger)
    if not events:
        print(f"[!] No quota events found: {ledger}")
        return 1

    now = dt.datetime.now(dt.timezone.utc)
    cutoff = now - dt.timedelta(days=max(1, args.days))

    filtered: List[Dict[str, Any]] = []
    for event in events:
        ts = event.get("ts")
        phase = str(event.get("phase", ""))
        if not ts:
            continue
        try:
            tsv = parse_ts(ts).astimezone(dt.timezone.utc)
        except Exception:
            continue
        if tsv < cutoff:
            continue
        if args.phase != "all" and phase != args.phase:
            continue
        if args.run_id and str(event.get("run_id") or "") != args.run_id:
            continue
        filtered.append(event)

    if not filtered:
        print("[!] No events match selected filters.")
        return 1

    totals = empty_bucket()
    for event in filtered:
        accumulate(totals, event)

    print("=== QUOTA DASHBOARD ===")
    print(f"  Ledger: {ledger}")
    print(f"  Window: last {args.days} day(s), phase={args.phase}")
    if args.run_id:
        print(f"  Run ID: {args.run_id}")
    print(f"  Events: {len(filtered)}")
    print(
        "  Totals: "
        f"calls={int(totals['calls'])} ok={int(totals['ok'])} failed={int(totals['failed'])} "
        f"tokens={int(totals['tokens'])} cost_usd={totals['cost']:.4f} "
        f"usage_available={int(totals['usage_available'])} usage_unavailable={int(totals['usage_unavailable'])}"
    )
    print("")

    if args.run_id:
        sections = [
            ("== By Phase ==", summarize_by(filtered, "phase")),
            ("== By Model ==", summarize_by(filtered, "model")),
            ("== By Role ==", summarize_by(filtered, "role")),
            ("== By Component ==", summarize_by(filtered, "component")),
            ("== By Provider ==", summarize_by(filtered, "provider")),
            ("== By Agent ==", summarize_by(filtered, "agent_id")),
            ("== By Cluster ==", summarize_by(filtered, "cluster_id")),
            ("== By Usage Source ==", summarize_by(filtered, "usage_source")),
        ]
        headers = ["Key", "Calls", "OK", "Fail", "AvgSec", "Tokens", "CostUSD", "Usage(A/U)"]
        for title, groups in sections:
            rows = [bucket_to_row(name, bucket) for name, bucket in groups.items()]
            render_table(title, headers, rows)
        return 0

    daily: Dict[tuple, Dict[str, float]] = defaultdict(empty_bucket)
    by_plugin = summarize_by(filtered, "slug")
    for event in filtered:
        day = str(event.get("ts", ""))[:10]
        key = (day, str(event.get("phase", "unknown")), str(event.get("mode", "unknown")), str(event.get("provider", "unknown")))
        accumulate(daily[key], event)

    daily_rows = [
        [
            day,
            phase,
            mode,
            provider,
            str(int(bucket["calls"])),
            str(int(bucket["ok"])),
            str(int(bucket["failed"])),
            f"{(bucket['duration'] / bucket['calls']) if bucket['calls'] else 0:.1f}",
            str(int(bucket["tokens"])),
            f"{bucket['cost']:.4f}",
            f"{int(bucket['usage_available'])}/{int(bucket['usage_unavailable'])}",
        ]
        for (day, phase, mode, provider), bucket in sorted(daily.items())
    ]
    render_table(
        "== Daily by Phase/Mode/Provider ==",
        ["Date", "Phase", "Mode", "Provider", "Calls", "OK", "Fail", "AvgSec", "Tokens", "CostUSD", "Usage(A/U)"],
        daily_rows,
    )

    plugin_rows = [bucket_to_row(name, bucket) for name, bucket in list(by_plugin.items())[: max(1, args.limit)]]
    render_table("== Top Plugins by LLM Cost ==", ["Slug", "Calls", "OK", "Fail", "AvgSec", "Tokens", "CostUSD", "Usage(A/U)"], plugin_rows)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
