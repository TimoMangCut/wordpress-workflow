#!/usr/bin/env python3
"""Summarize LLM usage ledger for quota tracking."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List

from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Quota dashboard from reports/logs/quota-ledger.jsonl")
    p.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"))
    p.add_argument("--phase", default="all", choices=["all", "phase2", "phase3"])
    p.add_argument("--days", type=int, default=7, help="Only include last N days (UTC)")
    p.add_argument("--limit", type=int, default=20, help="Top rows for per-plugin section")
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
            if isinstance(item, dict):
                events.append(item)
        except Exception:
            continue
    return events


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
    for e in events:
        ts = e.get("ts")
        phase = str(e.get("phase", ""))
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
        filtered.append(e)

    if not filtered:
        print("[!] No events match selected filters.")
        return 1

    # Daily summary by phase + mode
    daily: Dict[tuple, Dict[str, float]] = defaultdict(lambda: {"calls": 0, "ok": 0, "failed": 0, "duration": 0.0})
    by_plugin: Dict[str, Dict[str, float]] = defaultdict(lambda: {"calls": 0, "ok": 0, "failed": 0, "duration": 0.0})

    for e in filtered:
        phase = str(e.get("phase", "unknown"))
        mode = str(e.get("mode", "unknown"))
        provider = str(e.get("provider", "unknown"))
        status = str(e.get("status", "unknown"))
        slug = str(e.get("slug", "unknown"))
        dur = float(e.get("duration_sec", 0) or 0)
        day = str(e.get("ts", ""))[:10]

        key = (day, phase, mode, provider)
        daily[key]["calls"] += 1
        daily[key]["duration"] += dur
        if status == "ok":
            daily[key]["ok"] += 1
        else:
            daily[key]["failed"] += 1

        by_plugin[slug]["calls"] += 1
        by_plugin[slug]["duration"] += dur
        if status == "ok":
            by_plugin[slug]["ok"] += 1
        else:
            by_plugin[slug]["failed"] += 1

    print("=== QUOTA DASHBOARD ===")
    print(f"  Ledger: {ledger}")
    print(f"  Window: last {args.days} day(s), phase={args.phase}")
    print(f"  Events: {len(filtered)}")
    print("")

    print("== Daily by Phase/Mode/Provider ==")
    print(f"{'Date':<12} {'Phase':<8} {'Mode':<12} {'Provider':<8} {'Calls':>6} {'OK':>6} {'Fail':>6} {'AvgSec':>8}")
    for (day, phase, mode, provider), s in sorted(daily.items()):
        avg = s["duration"] / s["calls"] if s["calls"] else 0
        print(f"{day:<12} {phase:<8} {mode:<12} {provider:<8} {int(s['calls']):>6} {int(s['ok']):>6} {int(s['failed']):>6} {avg:>8.1f}")

    print("")
    print("== Top Plugins by LLM Calls ==")
    print(f"{'Slug':<42} {'Calls':>6} {'OK':>6} {'Fail':>6} {'AvgSec':>8}")
    ranked = sorted(by_plugin.items(), key=lambda x: (-x[1]["calls"], x[0]))[: max(1, args.limit)]
    for slug, s in ranked:
        avg = s["duration"] / s["calls"] if s["calls"] else 0
        print(f"{slug:<42} {int(s['calls']):>6} {int(s['ok']):>6} {int(s['failed']):>6} {avg:>8.1f}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
