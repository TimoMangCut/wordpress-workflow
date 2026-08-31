#!/usr/bin/env python3
"""Deterministic COMPLETE gate for the single-agent WordPress review.

The methodology (docs/review-methodology.md) forbids marking a review COMPLETE while
structural obligations remain open. Until now that rule lived only in prose and the model
self-certified. This script enforces it with code — no LLM, no pipeline. It cross-checks the
model's review JSON against the tool artifacts (inventory + IR) the run was required to
produce, and fails closed on the silent-drop conditions the methodology is meant to prevent.

It answers one question: is this review allowed to claim COMPLETE?

Usage:
    python3 tools/bin/complete_gate.py <review.json> \
        [--ir <ir.json>] [--inventory <inventory.txt>] [--slug <slug>] [--strict]

Resolution: if --ir/--inventory are omitted, they are looked up from --slug (or the review's
target.slug) under reports/tooling/<slug>/{ir.json,inventory.txt}.

Exit codes:
    0  gate passed (review may claim COMPLETE)
    1  gate failed — obligations remain open (printed)
    2  usage / environment error
Checks are reported as PASS / FAIL / WARN. Only FAIL blocks (WARN with --strict also blocks).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]


def _load_json(path: Path, label: str) -> Any:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"error: {label} not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    except json.JSONDecodeError as exc:
        print(f"error: {label} is not valid JSON: {path}\n  {exc}", file=sys.stderr)
        raise SystemExit(2)


def _basename(p: str) -> str:
    return Path(str(p)).name


def _review_haystack(review: dict) -> str:
    """Everything the review says about coverage, as one lowercased string for lenient
    accountability matching (an obligation is 'accounted for' if the review mentions its
    file or name anywhere in coverage/surfaces/findings)."""
    parts: list[str] = []
    cov = review.get("coverage", {}) or {}
    parts += [str(x) for x in cov.get("gaps", []) or []]
    parts += [str(x) for x in cov.get("files_reviewed", []) or []]
    for area in cov.get("secure_areas", []) or []:
        parts.append(json.dumps(area, ensure_ascii=False))
    for surf in cov.get("surfaces", []) or []:
        parts.append(json.dumps(surf, ensure_ascii=False))
    for f in review.get("findings", []) or []:
        parts.append(json.dumps(f, ensure_ascii=False))
    return "\n".join(parts).lower()


class Gate:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.warnings: list[str] = []
        self.passes: list[str] = []

    def check(self, ok: bool, label: str, detail: str = "", warn_only: bool = False) -> None:
        if ok:
            self.passes.append(label)
        elif warn_only:
            self.warnings.append(f"{label}: {detail}")
        else:
            self.failures.append(f"{label}: {detail}")


def run_gate(review: dict, ir: dict, inventory_exists: bool, ir_exists: bool) -> Gate:
    g = Gate()
    hay = _review_haystack(review)

    # 1. Lifecycle
    g.check(review.get("lifecycle") == "COMPLETE", "lifecycle==COMPLETE",
            f"lifecycle is {review.get('lifecycle')!r}; gate only clears a COMPLETE claim")

    # 2. Required tool artifacts actually ran
    g.check(inventory_exists, "inventory ran", "inventory.txt missing — the required baseline did not run")
    g.check(ir_exists, "ast/IR ran", "ir.json missing — the required AST/IR extraction did not run")

    # 3. Every finding carries an anchored refutation (refute-first, with evidence)
    for f in review.get("findings", []) or []:
        fid = f.get("finding_id", "<no-id>")
        refs = f.get("refutations", []) or []
        anchored = any((r.get("locations") or []) for r in refs)
        g.check(bool(refs) and anchored, f"finding {fid} anchored refutation",
                "no refutation with a file:line location")

    # 4. Every UNRESOLVED surface has an explicit disposition
    for s in (review.get("coverage", {}) or {}).get("surfaces", []) or []:
        if s.get("status") == "UNRESOLVED":
            sid = s.get("surface_id", "<no-id>")
            g.check(bool(s.get("notes")), f"surface {sid} UNRESOLVED disposition",
                    "UNRESOLVED surface has no notes/disposition")

    # 5. Reconciliation: every IR obligation is accounted for in the review
    for uh in ir.get("unresolved_hooks", []) or []:
        name = str(uh.get("hook_name") or uh.get("name") or "").lower()
        fileref = _basename(uh.get("file", "")).lower()
        token = name or fileref
        accounted = (name and name in hay) or (fileref and fileref in hay)
        g.check(bool(accounted), "IR unresolved_hook accounted",
                f"unresolved hook {token or uh!r} is not referenced anywhere in the review")

    for cg in ir.get("coverage_gaps", []) or []:
        fileref = _basename(cg.get("file", "")).lower()
        g.check(bool(fileref) and fileref in hay, "IR coverage_gap accounted",
                f"coverage-gap file {fileref or cg!r} is not referenced anywhere in the review")

    # 6. Every IR entry point is either mapped to a surface or explicitly deferred (warn)
    surface_files = {
        _basename((s.get("registration") or {}).get("path", "")).lower()
        for s in (review.get("coverage", {}) or {}).get("surfaces", []) or []
    }
    for ep in ir.get("entry_points", []) or []:
        fileref = _basename(ep.get("file", "")).lower()
        hook = str(ep.get("hook_name", "")).lower()
        mapped = (fileref and (fileref in surface_files or fileref in hay)) or (hook and hook in hay)
        g.check(bool(mapped), "IR entry_point mapped",
                f"entry point {hook or fileref or ep.get('id')} has no surface and no mention in the review",
                warn_only=True)

    return g


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Enforce the COMPLETE gate for a methodology review.")
    parser.add_argument("review", type=Path)
    parser.add_argument("--ir", type=Path, default=None)
    parser.add_argument("--inventory", type=Path, default=None)
    parser.add_argument("--slug", default=None)
    parser.add_argument("--strict", action="store_true", help="Treat warnings as failures.")
    args = parser.parse_args(argv)

    review = _load_json(args.review, "review")
    slug = args.slug or (review.get("target", {}) or {}).get("slug")

    ir_path = args.ir or (REPO_ROOT / "reports" / "tooling" / str(slug) / "ir.json" if slug else None)
    inv_path = args.inventory or (REPO_ROOT / "reports" / "tooling" / str(slug) / "inventory.txt" if slug else None)

    ir_exists = bool(ir_path and Path(ir_path).exists())
    inventory_exists = bool(inv_path and Path(inv_path).exists())
    ir = _load_json(Path(ir_path), "ir") if ir_exists else {}

    g = run_gate(review, ir, inventory_exists, ir_exists)

    for label in g.passes:
        print(f"PASS  {label}")
    for w in g.warnings:
        print(f"WARN  {w}")
    for fdetail in g.failures:
        print(f"FAIL  {fdetail}")

    blocked = bool(g.failures) or (args.strict and bool(g.warnings))
    print()
    if blocked:
        print(f"GATE FAILED: {len(g.failures)} failure(s), {len(g.warnings)} warning(s). "
              f"Not COMPLETE — resolve the open obligations above.")
        return 1
    print(f"GATE PASSED: {len(g.passes)} check(s) passed, {len(g.warnings)} warning(s). Review may claim COMPLETE.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
