#!/usr/bin/env python3
"""Partition an IR into priority-ordered, budget-sized slices for one-agent review.

A single model cannot self-parse and trace a large plugin (hundreds of entry points) in one
pass — the real run on woocommerce-payments covered ~9% of surfaces. This deterministic helper
restores the chunking *mechanism* the retired pipeline had, as a plain tool (no orchestration,
no sub-agents): it groups entry points by trust-boundary priority (unauth first) and splits each
group into batches small enough to trace deeply, so the agent works the plugin sequentially,
batch by batch, with a coverage manifest to prove nothing was skipped.

Each slice is a per-batch subset of the IR conforming to contracts/ir-slice.schema.json (entry
points + only the sources/sinks/guards/anomalies linked by entry_point_id). unresolved_hooks and
coverage_gaps stay with the full IR (the recall backstop pass, not a per-batch concern).

Usage:
    python3 tools/bin/slice_ir.py <ir.json> --out <dir> [--slug <slug>] [--batch-size N] [--validate]

Writes <dir>/slice-plan.json (ordered manifest) and <dir>/slice-NNN.json (one per batch), and
prints the ordered plan. Exit 0 on success, 2 on usage/env error, 1 if --validate finds a slice
that does not conform.
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parents[2]
SLICE_SCHEMA = REPO_ROOT / "contracts" / "ir-slice.schema.json"

# Sink categories that make a surface worth tracing first within its priority bucket.
DANGEROUS_SINKS = {
    "sql", "file", "file_read", "file_write", "file_delete", "eval", "command",
    "deserialize", "redirect", "include", "output", "rce",
}

# Priority buckets (lower = reviewed first). Trust boundary drives the order.
BUCKETS = [
    (0, "unauth-ajax"),
    (1, "unauth/unknown-rest"),
    (2, "auth-ajax"),
    (3, "auth-rest"),
    (4, "block/shortcode"),
    (5, "bootstrap/other"),
]
BUCKET_LABEL = dict(BUCKETS)


def _unauth(auth: str | None) -> bool:
    return (auth or "unknown").lower() in ("none", "unknown")


def bucket_of(ep: dict) -> int:
    t = (ep.get("type") or "").lower()
    unauth = _unauth(ep.get("auth_level"))
    # wc_ajax is WooCommerce's ?wc-ajax= front controller: reachable unauthenticated,
    # so it belongs in the highest-priority unauth-ajax bucket alongside ajax_nopriv.
    if t in ("ajax_nopriv", "admin_post_nopriv", "wc_ajax"):
        return 0
    if t in ("rest_route", "rest_api_init"):
        return 1 if unauth else 3
    if t in ("ajax_priv", "admin_post"):
        return 2
    if t in ("block", "shortcode"):
        return 4
    return 5  # admin_init, init, template_redirect, wp_loaded, cron, filter_capability, …


def _by_ep(items: list[dict], ep_ids: set[str]) -> list[dict]:
    return [it for it in items if it.get("entry_point_id") in ep_ids]


def _files_of(slice_ir: dict) -> list[str]:
    files: set[str] = set()
    for ep in slice_ir["entry_points"]:
        if ep.get("file"):
            files.add(ep["file"])
        cb = ep.get("callback")
        if isinstance(cb, dict) and cb.get("file"):
            files.add(cb["file"])
    for section in ("sources", "sinks", "guards"):
        for it in slice_ir[section]:
            if it.get("file"):
                files.add(it["file"])
    return sorted(files)


def build_slice(ir: dict, eps: list[dict]) -> dict:
    ep_ids = {ep["id"] for ep in eps}
    return {
        "metadata": ir.get("metadata", {}),
        "entry_points": eps,
        "sources": _by_ep(ir.get("sources", []), ep_ids),
        "sinks": _by_ep(ir.get("sinks", []), ep_ids),
        "guards": _by_ep(ir.get("guards", []), ep_ids),
        "anomalies": _by_ep(ir.get("anomalies", []), ep_ids),
        "unresolved_hooks": [],
        "coverage_gaps": [],
    }


def order_and_batch(ir: dict, batch_size: int) -> list[tuple[int, list[dict]]]:
    """Return [(bucket, [entry_points])] in priority order, each list <= batch_size."""
    sinks_by_ep: dict[str, list[dict]] = {}
    for s in ir.get("sinks", []):
        sinks_by_ep.setdefault(s.get("entry_point_id"), []).append(s)
    anoms_by_ep: dict[str, list[dict]] = {}
    for a in ir.get("anomalies", []):
        anoms_by_ep.setdefault(a.get("entry_point_id"), []).append(a)

    def ep_rank(ep: dict) -> tuple:
        eid = ep.get("id")
        has_danger = any((s.get("category") or "") in DANGEROUS_SINKS for s in sinks_by_ep.get(eid, []))
        has_anom = bool(anoms_by_ep.get(eid))
        # within a bucket: dangerous sinks first, then anomalies, then stable by hook name
        return (0 if has_danger else 1, 0 if has_anom else 1, ep.get("hook_name") or "")

    batches: list[tuple[int, list[dict]]] = []
    for bucket, _label in BUCKETS:
        eps = sorted((e for e in ir.get("entry_points", []) if bucket_of(e) == bucket), key=ep_rank)
        for i in range(0, len(eps), batch_size):
            batches.append((bucket, eps[i:i + batch_size]))
    return batches


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Partition an IR into priority-ordered review slices.")
    parser.add_argument("ir", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--slug", default=None)
    parser.add_argument("--batch-size", type=int, default=12)
    parser.add_argument("--validate", action="store_true", help="Validate each slice against ir-slice.schema.json.")
    args = parser.parse_args(argv)

    if args.batch_size < 1:
        print("error: --batch-size must be >= 1", file=sys.stderr)
        return 2
    try:
        ir = json.loads(args.ir.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"error: cannot read IR {args.ir}: {exc}", file=sys.stderr)
        return 2

    args.out.mkdir(parents=True, exist_ok=True)
    batches = order_and_batch(ir, args.batch_size)

    validator = None
    if args.validate:
        try:
            import jsonschema
            validator = jsonschema.Draft7Validator(json.loads(SLICE_SCHEMA.read_text()))
        except ImportError:
            print("warning: jsonschema not installed; skipping --validate", file=sys.stderr)

    manifest: dict[str, Any] = {
        "slug": args.slug or ir.get("metadata", {}).get("plugin_slug") or ir.get("metadata", {}).get("plugin"),
        "total_entry_points": len(ir.get("entry_points", [])),
        "batch_size": args.batch_size,
        "batches": [],
    }
    invalid = 0
    for idx, (bucket, eps) in enumerate(batches, 1):
        if not eps:
            continue
        sl = build_slice(ir, eps)
        name = f"slice-{idx:03d}.json"
        (args.out / name).write_text(json.dumps(sl, indent=2, ensure_ascii=False), encoding="utf-8")
        if validator is not None:
            errs = sorted(validator.iter_errors(sl), key=lambda e: list(e.absolute_path))
            if errs:
                invalid += 1
                print(f"INVALID {name}: {errs[0].message} at {'/'.join(str(p) for p in errs[0].absolute_path)}", file=sys.stderr)
        manifest["batches"].append({
            "batch_id": idx,
            "priority_bucket": bucket,
            "bucket_label": BUCKET_LABEL[bucket],
            "ep_count": len(eps),
            "hooks": [e.get("hook_name") for e in eps],
            "files": _files_of(sl),
            "slice_file": name,
        })

    (args.out / "slice-plan.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")

    print(f"Sliced {manifest['total_entry_points']} entry points into {len(manifest['batches'])} "
          f"batches of <= {args.batch_size}, priority order:")
    for b in manifest["batches"]:
        print(f"  #{b['batch_id']:>3} [{b['bucket_label']:<20}] {b['ep_count']:>2} EP, {len(b['files'])} files -> {b['slice_file']}")
    print(f"\nManifest: {args.out / 'slice-plan.json'}")
    if invalid:
        print(f"{invalid} slice(s) failed schema validation.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
