#!/usr/bin/env python3
"""
merge_phase2_reviewer_batches.py — merge reviewer_core batch outputs into final review artifact
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import jsonschema

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.bin.build_phase2_reviewer_input import find_project_root, load_json


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Merge reviewer_core batch outputs into the canonical review round artifact.")
    parser.add_argument("--plan", required=True, help="Path to reviewer core batch plan JSON")
    parser.add_argument("--output", required=True, help="Merged review output path")
    return parser.parse_args()


def merge_reviewer_batches(*, root: Path, plan_path: Path, output_path: Path) -> dict:
    plan = load_json(plan_path)
    plan_schema = load_json(root / "contracts" / "phase2-review-batch-plan.schema.json")
    jsonschema.validate(instance=plan, schema=plan_schema)

    core_schema = load_json(root / "contracts" / "phase2-review-core-output.schema.json")
    ordered_packet_ids = [packet_id for batch in plan.get("batches") or [] for packet_id in batch.get("packet_ids") or []]
    packet_order = {packet_id: index for index, packet_id in enumerate(ordered_packet_ids)}

    merged_finding_reviews = []
    batch_notes: list[str] = []
    review_status = "stable"
    worker_findings_reviewed = 0
    material = False
    seen_packet_ids: set[str] = set()

    for batch in plan.get("batches") or []:
        batch_output = root / batch["output_path"]
        if not batch_output.exists():
            raise SystemExit(f"Missing batch output: {batch_output}")
        data = load_json(batch_output)
        jsonschema.validate(instance=data, schema=core_schema)
        if data.get("review_status") != "stable":
            review_status = "needs_revision"
        summary = data.get("summary") or {}
        worker_findings_reviewed += int(summary.get("worker_findings_reviewed") or 0)
        material = material or bool(summary.get("material_issues_found"))
        if summary.get("notes"):
            batch_notes.append(str(summary["notes"]))
        for item in data.get("finding_reviews") or []:
            packet_id = str(item.get("packet_id") or item.get("finding_id") or "")
            if not packet_id:
                continue
            if packet_id in seen_packet_ids:
                raise SystemExit(f"Duplicate reviewer packet across batches: {packet_id}")
            seen_packet_ids.add(packet_id)
            merged_finding_reviews.append(item)

    expected_packet_ids = set(ordered_packet_ids)
    if seen_packet_ids != expected_packet_ids:
        missing = sorted(expected_packet_ids - seen_packet_ids)
        extra = sorted(seen_packet_ids - expected_packet_ids)
        raise SystemExit(f"Merged reviewer batches did not cover the same packet IDs. missing={missing} extra={extra}")

    merged_finding_reviews.sort(key=lambda item: packet_order.get(str(item.get("packet_id") or item.get("finding_id") or ""), 10**6))
    if any(item.get("assessment") not in {"keep", "field_fix"} for item in merged_finding_reviews):
        material = True

    merged = {
        "plugin_slug": plan["plugin_slug"],
        "review_round": plan["review_round"],
        "review_mode": "core",
        "review_status": review_status,
        "summary": {
            "worker_findings_reviewed": len(merged_finding_reviews),
            "material_issues_found": material,
            "new_candidate_count": 0,
            "notes": "; ".join(batch_notes[:6]) if batch_notes else f"Merged reviewer_core from {len(plan.get('batches') or [])} batches.",
        },
        "finding_reviews": merged_finding_reviews,
    }
    jsonschema.validate(instance=merged, schema=core_schema)
    output_path.write_text(json.dumps(merged, indent=2) + "\n", encoding="utf-8")
    return merged


def main() -> int:
    args = parse_args()
    root = find_project_root()
    plan_path = Path(args.plan)
    output_path = Path(args.output)
    merge_reviewer_batches(root=root, plan_path=plan_path, output_path=output_path)
    print(f"[OK] Reviewer batch merge written: {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
