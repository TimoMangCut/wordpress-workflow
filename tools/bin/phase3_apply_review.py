#!/usr/bin/env python3
"""Apply Phase 3b LLM review corrections to Phase 2 with deterministic guardrails."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

try:
    from .report_paths import build_report_layout
    from .artifact_freshness import resolve_phase2_trust_state
    from .phase3_review_contract import normalize_phase3_review_document
except ImportError:  # pragma: no cover - direct script execution
    from report_paths import build_report_layout
    from artifact_freshness import resolve_phase2_trust_state
    from phase3_review_contract import normalize_phase3_review_document

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root

FINAL_STATES = {"CONFIRMED", "UNCERTAIN", "RISK_NOTE", "REJECTED"}
DEFAULT_REOPENING_CONDITION = (
    "Reopen only if new traced entry-to-impact evidence or a reproducible exploit path "
    "contradicts the current rejection."
)


def load_json(path: str) -> Optional[dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def save_json(path: str, obj: dict) -> None:
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)


def file_line_exists(path: str, line_no: int) -> bool:
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            total = sum(1 for _ in f)
        return 1 <= line_no <= total
    except Exception:
        return False


def normalize_rel_path(path: str) -> str:
    return (path or "").replace("\\", "/").lstrip("./")


def normalize_verdict_change(value: Any) -> str:
    raw = str(value or "").strip().lower()
    aliases = {
        "rejected": "reject",
        "reject": "reject",
        "downgrade": "downgrade",
        "keep": "keep",
        "upgrade": "upgrade",
    }
    return aliases.get(raw, "")


def normalize_final_state(value: Any) -> Optional[str]:
    if value is None:
        return None
    state = str(value).strip().upper()
    return state if state in FINAL_STATES else None


def normalize_string_list(value: Any) -> List[str]:
    if not isinstance(value, list):
        return []
    out: List[str] = []
    for item in value:
        text = str(item or "").strip()
        if text:
            out.append(text)
    return out


def normalize_counter_evidence(value: Any) -> List[Dict[str, Any]]:
    if not isinstance(value, list):
        return []
    out: List[Dict[str, Any]] = []
    for item in value:
        if not isinstance(item, dict):
            continue
        clean: Dict[str, Any] = {}
        for key in ("type", "file", "line", "detail"):
            if key not in item:
                continue
            val = item.get(key)
            if key == "line":
                try:
                    clean[key] = int(val)
                except Exception:
                    continue
            else:
                text = str(val or "").strip()
                if text:
                    clean[key] = text
        if clean:
            out.append(clean)
    return out


def derive_reopening_condition(review_row: Dict[str, Any]) -> str:
    explicit = str(
        review_row.get("reopening_condition")
        or review_row.get("reopen_if")
        or review_row.get("reopen_when")
        or ""
    ).strip()
    if explicit:
        return explicit

    missing = normalize_string_list(review_row.get("missing_evidence"))
    if missing:
        return "Reopen if new evidence addresses: " + "; ".join(missing)

    return DEFAULT_REOPENING_CONDITION


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Apply phase3 review with deterministic guardrails")
    p.add_argument("slug")
    p.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"))
    p.add_argument("--plugins-dir", default=str(_ROOT_DIR / "plugins"))
    p.add_argument("--bin-dir", default=None, help="Override tools/bin directory")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    reports_dir = args.reports_dir
    plugins_dir = args.plugins_dir
    slug = args.slug
    layout = build_report_layout(reports_dir).ensure()

    review_path = os.path.join(layout.phase3, f"{slug}-phase3-review.json")
    if not os.path.exists(review_path):
        print(f"[=] No review JSON found: {review_path} (skip)")
        return 0

    review = load_json(review_path)
    if not review or not isinstance(review, dict):
        print(f"[!] Invalid review JSON: {review_path} (skip)")
        return 0

    phase2_path = os.path.join(layout.phase2, f"{slug}-phase2.json")
    phase2 = load_json(phase2_path)
    if not phase2:
        print(f"[!] Missing phase2 json: {phase2_path}")
        return 1
    phase2_trust_state = resolve_phase2_trust_state(phase2_path)
    if phase2_trust_state != "success":
        print(
            f"[!] Phase 2 canonical is not trusted for apply-review: {phase2_path} "
            f"(trust_state={phase2_trust_state or 'missing'})"
        )
        return 1
    try:
        review = normalize_phase3_review_document(review, slug=slug)
    except Exception as exc:
        print(f"[!] Invalid review contract: {review_path} ({exc})")
        return 0

    ir_path = os.path.join(layout.phase1, f"{slug}-ir.json")
    ir = load_json(ir_path) or {}
    valid_ep_ids = {ep.get("id") for ep in (ir.get("entry_points", []) or []) if ep.get("id")}

    plugin_root = os.path.join(plugins_dir, slug)
    if not os.path.isdir(plugin_root):
        print(f"[!] Plugin directory missing: {plugin_root}")
        return 1

    findings = phase2.get("findings", []) or []
    by_id = {f.get("finding_id"): f for f in findings if f.get("finding_id")}

    reviews = review.get("reviews") or review.get("findings") or []
    applied = 0
    changes: List[Dict[str, Any]] = []
    review_counts = {
        "reject": 0,
        "downgrade": 0,
        "keep": 0,
        "upgrade": 0,
    }

    for r in reviews:
        fid = r.get("finding_id")
        if not fid or fid not in by_id:
            continue
        f = by_id[fid]
        review_meta: Dict[str, Any] = {
            "original_status": str(r.get("original_status") or "").strip().upper() or None,
            "reason": r.get("reason"),
            "counter_evidence": normalize_counter_evidence(r.get("counter_evidence")),
            "missing_evidence": normalize_string_list(r.get("missing_evidence")),
            "dynamic_test_plan": normalize_string_list(r.get("dynamic_test_plan")),
        }

        # Verdict change (structured, but backward-compatible with the old review schema)
        vc = normalize_verdict_change(r.get("verdict_change"))
        proposed_final_state = normalize_final_state(
            r.get("proposed_final_state") or r.get("suggested_final_state") or r.get("final_state")
        )
        if vc:
            review_meta["verdict_change"] = vc
            review_counts[vc] = review_counts.get(vc, 0) + 1
        if proposed_final_state:
            review_meta["proposed_final_state"] = proposed_final_state

        if vc == "reject" or proposed_final_state == "REJECTED":
            old = f.get("verdict")
            if old != "FP":
                f["phase3_review_prior_verdict"] = old
                f["verdict"] = "FP"
                changes.append(
                    {
                        "finding_id": fid,
                        "field": "verdict",
                        "old": old,
                        "new": "FP",
                        "reason": r.get("reason"),
                    }
                )
                applied += 1
            review_meta["final_state"] = "REJECTED"
            review_meta["reopening_condition"] = derive_reopening_condition(r)
        elif vc == "downgrade" and f.get("verdict") == "TP":
            old = f.get("verdict")
            f["verdict"] = "REVIEW"
            f["phase3_review_verdict_reason"] = r.get("reason")
            if proposed_final_state in {"UNCERTAIN", "RISK_NOTE"}:
                review_meta["final_state"] = proposed_final_state
            changes.append({"finding_id": fid, "field": "verdict", "old": old, "new": "REVIEW", "reason": r.get("reason")})
            applied += 1
        elif vc == "upgrade":
            if f.get("verdict") in ("REVIEW", "FP"):
                old = f.get("verdict")
                f["verdict"] = "TP"
                f["phase3_review_verdict_reason"] = r.get("reason")
                changes.append({"finding_id": fid, "field": "verdict", "old": old, "new": "TP", "reason": r.get("reason")})
                applied += 1
            elif f.get("verdict") == "TP":
                f["phase3_review_verdict_reason"] = r.get("reason")
                changes.append({"finding_id": fid, "field": "phase3_review_note", "old": None, "new": "LLM confirmed TP", "reason": r.get("reason")})
                applied += 1
        elif proposed_final_state in {"UNCERTAIN", "RISK_NOTE"}:
            review_meta["final_state"] = proposed_final_state

        corr = r.get("suggested_field_corrections") or {}
        if not isinstance(corr, dict):
            corr = {}

        # entry_point_id guardrail: must exist in IR
        if "entry_point_id" in corr:
            new_ep = str(corr.get("entry_point_id") or "").strip()
            if new_ep and new_ep in valid_ep_ids and new_ep != f.get("entry_point_id"):
                old = f.get("entry_point_id")
                f["entry_point_id"] = new_ep
                changes.append({"finding_id": fid, "field": "entry_point_id", "old": old, "new": new_ep})
                applied += 1

        # source path/line guardrails
        source_path = normalize_rel_path(str(corr.get("source_file_path") or ""))
        source_line = corr.get("source_line_number")
        if source_path:
            source_abs = os.path.join(plugin_root, source_path)
            if os.path.exists(source_abs):
                if source_path != f.get("source_file_path"):
                    old = f.get("source_file_path")
                    f["source_file_path"] = source_path
                    changes.append({"finding_id": fid, "field": "source_file_path", "old": old, "new": source_path})
                    applied += 1
                if isinstance(source_line, int) and source_line > 0 and file_line_exists(source_abs, source_line):
                    if source_line != f.get("source_line_number"):
                        old = f.get("source_line_number")
                        f["source_line_number"] = source_line
                        changes.append({"finding_id": fid, "field": "source_line_number", "old": old, "new": source_line})
                        applied += 1

        # sink path/line guardrails
        sink_path = normalize_rel_path(str(corr.get("sink_file_path") or ""))
        sink_line = corr.get("sink_line_number")
        if sink_path:
            sink_abs = os.path.join(plugin_root, sink_path)
            if os.path.exists(sink_abs):
                if sink_path != f.get("sink_file_path"):
                    old = f.get("sink_file_path")
                    f["sink_file_path"] = sink_path
                    f["file_path"] = sink_path
                    changes.append({"finding_id": fid, "field": "sink_file_path", "old": old, "new": sink_path})
                    applied += 1
                if isinstance(sink_line, int) and sink_line > 0 and file_line_exists(sink_abs, sink_line):
                    if sink_line != f.get("sink_line_number"):
                        old = f.get("sink_line_number")
                        f["sink_line_number"] = sink_line
                        f["line_number"] = sink_line
                        changes.append({"finding_id": fid, "field": "sink_line_number", "old": old, "new": sink_line})
                        applied += 1

        # storage_key guardrail: non-empty string only
        if "storage_key" in corr:
            new_key = str(corr.get("storage_key") or "").strip()
            if new_key and new_key != str(f.get("storage_key") or ""):
                old = f.get("storage_key")
                f["storage_key"] = new_key
                changes.append({"finding_id": fid, "field": "storage_key", "old": old, "new": new_key})
                applied += 1

        if corr:
            review_meta["suggested_field_corrections"] = corr

        f["phase3_review"] = review_meta

    before_path = os.path.join(layout.phase2, f"{slug}-phase2.before_review.json")
    shutil.copy2(phase2_path, before_path)

    phase2.setdefault("postprocess", {})
    phase2["postprocess"]["phase3_review_applied"] = {
        "applied_edits": applied,
        "reviewed_findings": len(reviews),
        "review_counts": review_counts,
    }
    save_json(phase2_path, phase2)

    after_path = os.path.join(layout.phase2, f"{slug}-phase2.after_review.json")
    shutil.copy2(phase2_path, after_path)

    diff_path = os.path.join(layout.phase3, f"{slug}-phase3-review-diff.json")
    save_json(
        diff_path,
        {
            "plugin_slug": slug,
            "applied_edits": applied,
            "review_counts": review_counts,
            "changes": changes,
            "review_source": review_path,
        },
    )

    gate_path = os.path.join(layout.phase3, f"{slug}-phase3.json")
    gate_backup = os.path.join(layout.phase3, f"{slug}-phase3.gate.json")
    if os.path.exists(gate_path):
        shutil.copy2(gate_path, gate_backup)

    bin_dir = args.bin_dir or os.path.dirname(os.path.abspath(__file__))
    gate_script = os.path.join(bin_dir, "phase3_gate.py")
    cmd = [
        sys.executable,
        gate_script,
        slug,
        "--reports-dir",
        reports_dir,
        "--plugins-dir",
        plugins_dir,
    ]

    print(f"[=] Applying review with guardrails: {slug} (edits={applied})")
    try:
        subprocess.check_call(cmd)
    except subprocess.CalledProcessError:
        print("[!] Re-running gate failed")
        return 1

    final_path = os.path.join(layout.phase3, f"{slug}-phase3.final.json")
    if os.path.exists(gate_path):
        shutil.copy2(gate_path, final_path)
        print(f"[=] Final gate snapshot: {final_path}")
    print(f"[=] Review diff log: {diff_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
