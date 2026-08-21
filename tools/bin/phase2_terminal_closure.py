#!/usr/bin/env python3
"""Apply terminal Phase 2 closure decisions to the worker artifact.

Happy path:
- consume a terminal_core review artifact
- apply the reviewer's explicit TP/FP closure verdicts packet-by-packet

Controlled safety net:
- if invoked with a legacy core review artifact, deterministically reject only
  unresolved non-keep/non-field-fix packets as FP

The goal is to keep final-round closure authority with the reviewer contract,
while still preserving a bounded structural fallback if that contract fails.
"""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--slug", required=True)
    parser.add_argument("--worker-input", required=True)
    parser.add_argument("--review-input", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def pick_anchor(finding: Dict[str, Any]) -> Tuple[Optional[str], Optional[int]]:
    candidates = (
        (finding.get("source_file_path"), finding.get("source_line_number")),
        (finding.get("sink_file_path"), finding.get("sink_line_number")),
        (finding.get("file_path"), finding.get("line_number")),
    )
    for file_path, line in candidates:
        if file_path:
            try:
                line_value = int(line) if line is not None else None
            except (TypeError, ValueError):
                line_value = None
            return str(file_path), line_value
    return None, None


def build_fp_evidence(
    finding: Dict[str, Any], review_item: Dict[str, Any]
) -> Dict[str, Any]:
    counter_evidence = review_item.get("counter_evidence") or []
    for item in counter_evidence:
        if not isinstance(item, dict):
            continue
        detail = str(item.get("detail") or item.get("defense") or "").strip()
        file_path = item.get("file")
        line = item.get("line")
        if not detail:
            continue
        try:
            line_value = int(line) if line is not None else None
        except (TypeError, ValueError):
            line_value = None
        return {
            "defense": detail,
            "file": file_path,
            "line": line_value,
        }

    anchor_file, anchor_line = pick_anchor(finding)
    missing = review_item.get("missing_evidence") or []
    if missing:
        defense = (
            "Terminal closure rejected the packet after bounded core-review "
            f"exhaustion because the required exploit proof was still missing: {missing[0]}"
        )
    else:
        defense = (
            "Terminal closure rejected the packet after bounded core-review "
            "exhaustion because the final core review still lacked sufficient "
            "packet-local exploit evidence."
        )
    return {
        "defense": defense,
        "file": anchor_file,
        "line": anchor_line,
    }


def build_fp_reason(review_item: Dict[str, Any]) -> str:
    reason = str(review_item.get("reason") or "").strip()
    missing = [
        str(item).strip()
        for item in (review_item.get("missing_evidence") or [])
        if str(item).strip()
    ]
    reopen = ""
    if missing:
        reopen = " Reopen only if new evidence resolves: " + "; ".join(missing)
    if reason:
        return (
            "Terminal closure applied after bounded core-review exhaustion. "
            + reason
            + reopen
        ).strip()
    base = (
        "Terminal closure applied after bounded core-review exhaustion because "
        "the packet remained unproven."
    )
    return (base + reopen).strip()


def build_tp_reason(review_item: Dict[str, Any]) -> str:
    reason = str(review_item.get("reason") or "").strip()
    if reason:
        return (
            "Terminal core review confirmed the packet after bounded Phase 2 review. "
            + reason
        ).strip()
    return "Terminal core review confirmed the packet after bounded Phase 2 review."


def recompute_summary(data: Dict[str, Any]) -> None:
    findings = data.get("findings") or []
    tp = sum(1 for item in findings if item.get("verdict") == "TP")
    fp = sum(1 for item in findings if item.get("verdict") == "FP")
    review = sum(1 for item in findings if item.get("verdict") == "REVIEW")
    data["total_findings_analyzed"] = len(findings)
    data["true_positives"] = tp
    data["false_positives"] = fp
    data["needs_review"] = review

    sev_order = {"informational": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
    max_tp = -1
    for finding in findings:
        if finding.get("verdict") != "TP":
            continue
        severity = str(finding.get("severity") or "").strip().lower()
        max_tp = max(max_tp, sev_order.get(severity, -1))
    if max_tp >= 0:
        inv = {value: key for key, value in sev_order.items()}
        data["overall_risk"] = inv.get(max_tp, "medium")
    elif review > 0:
        data["overall_risk"] = "review"
    else:
        data["overall_risk"] = "none"


def update_analysis_summary(data: Dict[str, Any], closed_count: int) -> None:
    if closed_count <= 0:
        return
    note = (
        f" Terminal closure rejected {closed_count} unresolved core-review packet(s) "
        "after bounded Phase 2 review exhaustion."
    )
    summary = str(data.get("analysis_summary") or "").strip()
    if summary:
        if note.strip() not in summary:
            data["analysis_summary"] = summary + note
    else:
        data["analysis_summary"] = note.strip()


def main() -> int:
    args = parse_args()
    worker_input = Path(args.worker_input)
    review_input = Path(args.review_input)
    output_path = Path(args.output)

    worker_doc = load_json(worker_input)
    review_doc = load_json(review_input)
    findings: List[Dict[str, Any]] = worker_doc.get("findings") or []
    original_finding_by_id = {
        str(finding.get("finding_id")): finding
        for finding in findings
        if finding.get("finding_id")
    }

    review_mode = str(review_doc.get("review_mode") or "").strip().lower()
    terminal_mode = review_mode == "terminal_core"

    closure_items = []
    for item in (review_doc.get("finding_reviews") or []):
        assessment = str(item.get("assessment") or "").strip().lower()
        closure_verdict = str(item.get("closure_verdict") or "").strip().upper()
        if terminal_mode:
            if closure_verdict in {"TP", "FP"}:
                closure_items.append(item)
            continue
        if assessment and assessment not in {"keep", "field_fix"}:
            closure_items.append(item)

    output_doc = copy.deepcopy(worker_doc)
    output_findings: List[Dict[str, Any]] = output_doc.get("findings") or []
    output_finding_by_id = {
        str(finding.get("finding_id")): finding
        for finding in output_findings
        if finding.get("finding_id")
    }
    current_review_ids: set[str] = set()
    review_findings_missing_id = 0
    for finding in output_findings:
        if str(finding.get("verdict") or "").upper() != "REVIEW":
            continue
        finding_id = str(finding.get("finding_id") or "").strip()
        if not finding_id:
            review_findings_missing_id += 1
            continue
        current_review_ids.add(finding_id)
    if terminal_mode and review_findings_missing_id:
        print(
            "[ERROR] terminal_core closure requires finding_id on every current REVIEW finding",
            file=sys.stderr,
        )
        return 1
    if terminal_mode and not current_review_ids:
        print(
            "[ERROR] terminal_core closure requires at least one current REVIEW finding",
            file=sys.stderr,
        )
        return 1

    closed: List[Dict[str, Any]] = []
    confirmed: List[Dict[str, Any]] = []
    already_absent: List[str] = []
    already_closed: List[str] = []
    invalid_terminal_targets: List[Tuple[str, str]] = []
    processed_terminal_ids: set[str] = set()

    for item in closure_items:
        finding_id = str(
            item.get("finding_id")
            or item.get("parent_finding_id")
            or item.get("packet_id")
            or ""
        ).strip()
        if not finding_id:
            continue
        finding = output_finding_by_id.get(finding_id)
        if terminal_mode:
            if not finding:
                invalid_terminal_targets.append((finding_id, "absent"))
                continue
            current_verdict = str(finding.get("verdict") or "").upper()
            if current_verdict != "REVIEW":
                invalid_terminal_targets.append((finding_id, current_verdict or "unknown"))
                continue
            processed_terminal_ids.add(finding_id)
        if not terminal_mode and not finding:
            already_absent.append(finding_id)
            continue
        if not terminal_mode and finding.get("verdict") == "FP":
            already_closed.append(finding_id)
            continue

        closure_verdict = str(item.get("closure_verdict") or "").strip().upper()
        if terminal_mode and closure_verdict == "TP":
            finding["verdict"] = "TP"
            finding["review_reason"] = build_tp_reason(item)
            finding["fp_reason"] = None
            finding["fp_evidence"] = None
            finding["terminal_closure"] = {
                "source_review_round": review_doc.get("review_round"),
                "source_review_mode": review_doc.get("review_mode"),
                "source_assessment": item.get("assessment"),
                "closure_policy": "terminal_core_review_confirms_packet",
                "closure_verdict": "TP",
                "reopen_if": item.get("missing_evidence") or [],
            }
            confirmed.append(
                {
                    "finding_id": finding_id,
                    "previous_verdict": (original_finding_by_id.get(finding_id) or {}).get("verdict"),
                    "closure_assessment": item.get("assessment"),
                }
            )
            continue

        finding["verdict"] = "FP"
        finding["reasoning"] = None
        finding["review_reason"] = None
        finding["fp_reason"] = build_fp_reason(item)
        finding["fp_evidence"] = build_fp_evidence(finding, item)
        finding["terminal_closure"] = {
            "source_review_round": review_doc.get("review_round"),
            "source_review_mode": review_doc.get("review_mode"),
            "source_assessment": item.get("assessment"),
            "closure_policy": (
                "terminal_core_review_rejects_or_unproven_packet"
                if terminal_mode
                else "bounded_core_review_exhaustion_rejects_unproven_packets"
            ),
            "closure_verdict": "FP",
            "reopen_if": item.get("missing_evidence") or [],
        }
        closed.append(
            {
                "finding_id": finding_id,
                "previous_verdict": (original_finding_by_id.get(finding_id) or {}).get("verdict"),
                "closure_assessment": item.get("assessment"),
            }
        )

    if terminal_mode and invalid_terminal_targets:
        for finding_id, state in invalid_terminal_targets:
            print(
                f"[ERROR] terminal_core closure target {finding_id} is not a current REVIEW finding (state={state})",
                file=sys.stderr,
            )
        return 1
    if terminal_mode:
        missing_targets = sorted(current_review_ids - processed_terminal_ids)
        if missing_targets:
            print(
                "[ERROR] terminal_core closure did not cover current REVIEW findings: "
                + ", ".join(missing_targets),
                file=sys.stderr,
            )
            return 1

    recompute_summary(output_doc)
    update_analysis_summary(output_doc, len(closed))
    output_doc["phase2_terminal_closure"] = {
        "version": "v2-terminal-review-authoritative",
        "plugin_slug": args.slug,
        "closure_policy": (
            "terminal_core_review_closure"
            if terminal_mode
            else "bounded_core_review_exhaustion_rejects_unproven_packets"
        ),
        "source_review_round": review_doc.get("review_round"),
        "source_review_mode": review_doc.get("review_mode"),
        "closed_unresolved_count": len(closed),
        "confirmed_terminal_count": len(confirmed),
        "closed_findings": closed,
        "closed_finding_ids": [item["finding_id"] for item in closed],
        "confirmed_findings": confirmed,
        "confirmed_finding_ids": [item["finding_id"] for item in confirmed],
        "already_absent_finding_ids": sorted(set(already_absent)),
        "already_closed_finding_ids": sorted(set(already_closed)),
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output_doc, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
