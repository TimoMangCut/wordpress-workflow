#!/usr/bin/env python3
"""Intrinsic quality metrics for a single-agent methodology review.

Deliberately measures PROCESS FIDELITY and COVERAGE, not outcome against a known-CVE set:
scoring against external known vulnerabilities biases the reviewer toward known bug shapes and
away from novel findings. These metrics need no external ground truth and introduce no such bias.

Reported per review:
  - surface coverage: traced / unresolved (and whether UNRESOLVED carry a disposition)
  - IR reconciliation: % of IR entry_points / unresolved_hooks / coverage_gaps accounted for
  - refutation discipline: % of findings with an anchored refutation
  - trace completeness: % of CONFIRMED findings with a full REGISTRATION+SOURCE+SINK+IMPACT trace
  - verdict mix + UNCERTAIN rate (a rising UNCERTAIN rate is the hedging-trap signal)

With --compare, reports run-to-run stability: finding overlap between two reviews of the same
target (a proxy for reproducibility — non-determinism is a known limit of LLM review).

Usage:
    python3 tools/bin/review_metrics.py <review.json> [--ir <ir.json>] [--json]
    python3 tools/bin/review_metrics.py <review_a.json> --compare <review_b.json> [--json]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"error: not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    except json.JSONDecodeError as exc:
        print(f"error: {path} is not valid JSON: {exc}", file=sys.stderr)
        raise SystemExit(2)


def _basename(p: Any) -> str:
    return Path(str(p)).name


def _pct(num: int, den: int) -> float:
    return round(100.0 * num / den, 1) if den else 100.0


def _haystack(review: dict) -> str:
    cov = review.get("coverage", {}) or {}
    parts = [json.dumps(cov, ensure_ascii=False)]
    for f in review.get("findings", []) or []:
        parts.append(json.dumps(f, ensure_ascii=False))
    return "\n".join(parts).lower()


def _sink_location(finding: dict) -> tuple[str, int]:
    for step in finding.get("trace", []) or []:
        if step.get("kind") == "SINK":
            loc = step.get("location", {}) or {}
            return _basename(loc.get("path", "")), int(loc.get("line", 0) or 0)
    return "", 0


def _finding_key(finding: dict) -> tuple[str, int, str]:
    """Structured identity: (sink file, sink line bucket, vuln class). Line bucketed to ±5
    so trivial line drift does not count as a different finding."""
    fbase, line = _sink_location(finding)
    vclass = str(finding.get("vulnerability_class") or finding.get("title", "")).lower().strip()
    return (fbase, line // 5, vclass)


def single_metrics(review: dict, ir: dict | None) -> dict:
    cov = review.get("coverage", {}) or {}
    surfaces = cov.get("surfaces", []) or []
    traced = [s for s in surfaces if s.get("status") == "TRACED"]
    unresolved = [s for s in surfaces if s.get("status") == "UNRESOLVED"]
    unresolved_with_disp = [s for s in unresolved if s.get("notes")]

    findings = review.get("findings", []) or []
    by_verdict: dict[str, int] = {}
    for f in findings:
        by_verdict[f.get("verdict", "?")] = by_verdict.get(f.get("verdict", "?"), 0) + 1

    anchored_refs = [
        f for f in findings
        if any((r.get("locations") or []) for r in (f.get("refutations") or []))
    ]
    confirmed = [f for f in findings if f.get("verdict") == "CONFIRMED"]
    full_trace = []
    for f in confirmed:
        kinds = {s.get("kind") for s in (f.get("trace") or [])}
        if {"REGISTRATION", "SOURCE", "SINK", "IMPACT"} <= kinds:
            full_trace.append(f)

    metrics: dict[str, Any] = {
        "surfaces_total": len(surfaces),
        "surfaces_traced": len(traced),
        "surfaces_unresolved": len(unresolved),
        "unresolved_with_disposition_pct": _pct(len(unresolved_with_disp), len(unresolved)),
        "findings_total": len(findings),
        "verdicts": by_verdict,
        "uncertain_rate_pct": _pct(by_verdict.get("UNCERTAIN", 0), len(findings)),
        "findings_anchored_refutation_pct": _pct(len(anchored_refs), len(findings)),
        "confirmed_full_trace_pct": _pct(len(full_trace), len(confirmed)),
        "tool_diagnostics": len(review.get("tool_diagnostics", []) or []),
    }

    if ir is not None:
        hay = _haystack(review)
        eps = ir.get("entry_points", []) or []
        ep_acc = sum(
            1 for ep in eps
            if (_basename(ep.get("file", "")).lower() in hay) or (str(ep.get("hook_name", "")).lower() in hay)
        )
        uhs = ir.get("unresolved_hooks", []) or []
        uh_acc = sum(
            1 for uh in uhs
            if str(uh.get("hook_name") or uh.get("name") or "").lower() in hay
            or _basename(uh.get("file", "")).lower() in hay
        )
        cgs = ir.get("coverage_gaps", []) or []
        cg_acc = sum(1 for cg in cgs if _basename(cg.get("file", "")).lower() in hay)
        metrics["ir_entry_points_accounted_pct"] = _pct(ep_acc, len(eps))
        metrics["ir_unresolved_hooks_accounted_pct"] = _pct(uh_acc, len(uhs))
        metrics["ir_coverage_gaps_accounted_pct"] = _pct(cg_acc, len(cgs))

    return metrics


def stability_metrics(a: dict, b: dict) -> dict:
    ka = {_finding_key(f) for f in a.get("findings", []) or []}
    kb = {_finding_key(f) for f in b.get("findings", []) or []}
    inter = ka & kb
    union = ka | kb
    return {
        "findings_a": len(ka),
        "findings_b": len(kb),
        "shared": len(inter),
        "jaccard_overlap_pct": _pct(len(inter), len(union)),
        "only_in_a": sorted(f"{k[0]}~{k[1]*5}:{k[2]}" for k in (ka - kb)),
        "only_in_b": sorted(f"{k[0]}~{k[1]*5}:{k[2]}" for k in (kb - ka)),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Intrinsic metrics for a methodology review.")
    parser.add_argument("review", type=Path)
    parser.add_argument("--ir", type=Path, default=None)
    parser.add_argument("--compare", type=Path, default=None, help="Second review of the same target for stability.")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)

    review = _load(args.review)
    if args.compare:
        result = {"mode": "stability", "stability": stability_metrics(review, _load(args.compare))}
    else:
        ir = _load(args.ir) if args.ir else None
        result = {"mode": "single", "metrics": single_metrics(review, ir)}

    if args.json:
        print(json.dumps(result, indent=2, ensure_ascii=False))
        return 0

    if result["mode"] == "stability":
        s = result["stability"]
        print(f"Run-to-run stability: {s['jaccard_overlap_pct']}% overlap "
              f"({s['shared']} shared of {s['findings_a']}/{s['findings_b']})")
        if s["only_in_a"]:
            print("  only in A:", ", ".join(s["only_in_a"]))
        if s["only_in_b"]:
            print("  only in B:", ", ".join(s["only_in_b"]))
    else:
        for k, v in result["metrics"].items():
            print(f"  {k}: {v}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
