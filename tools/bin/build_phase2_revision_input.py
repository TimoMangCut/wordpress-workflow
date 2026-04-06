#!/usr/bin/env python3
import argparse
import json
from collections import defaultdict
from pathlib import Path
from typing import Any, Dict, List, Optional


def _read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _reasoning_summary(reasoning: Any) -> Any:
    if not isinstance(reasoning, dict):
        return reasoning
    return {
        "hypothesis": reasoning.get("hypothesis"),
        "trace": reasoning.get("trace"),
        "conclusion": reasoning.get("conclusion"),
        "defenses": reasoning.get("defenses") or [],
        "refutation": reasoning.get("refutation") or [],
    }


def _finding_anchor(path: Optional[str], line: Optional[Any]) -> Optional[str]:
    if not path or line in (None, ""):
        return None
    return f"{path}:{line}"


def _compact_finding(finding: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "finding_id": finding.get("finding_id"),
        "verdict": finding.get("verdict"),
        "vuln_type": finding.get("vuln_type"),
        "cwe_id": finding.get("cwe_id"),
        "severity": finding.get("severity"),
        "auth_required": finding.get("auth_required"),
        "confidence": finding.get("confidence"),
        "entry_point_id": finding.get("entry_point_id"),
        "source_function": finding.get("source_function"),
        "sink_function": finding.get("sink_function"),
        "source_file_path": finding.get("source_file_path"),
        "source_line_number": finding.get("source_line_number"),
        "sink_file_path": finding.get("sink_file_path"),
        "sink_line_number": finding.get("sink_line_number"),
        "file_path": finding.get("file_path"),
        "line_number": finding.get("line_number"),
        "patchstack_eligible": finding.get("patchstack_eligible"),
        "cvss_vector": finding.get("cvss_vector"),
        "poc_description": finding.get("poc_description"),
        "remediation": finding.get("remediation"),
        "fp_reason": finding.get("fp_reason"),
        "fp_evidence": finding.get("fp_evidence"),
        "reasoning": _reasoning_summary(finding.get("reasoning")),
        "anchors": {
            "source_anchor": _finding_anchor(finding.get("source_file_path"), finding.get("source_line_number")),
            "sink_anchor": _finding_anchor(finding.get("sink_file_path"), finding.get("sink_line_number")),
            "entry_point_anchor": _finding_anchor(finding.get("file_path"), finding.get("line_number")),
        },
    }


def _files_from_review_item(item: Dict[str, Any]) -> List[str]:
    files: List[str] = []
    for evidence in item.get("counter_evidence") or []:
        file = evidence.get("file")
        if file:
            files.append(file)
    for key in ("entry_point_anchor", "source_anchor", "sink_anchor"):
        value = (item.get("suggested_field_corrections") or {}).get(key)
        if isinstance(value, str) and ":" in value:
            files.append(value.split(":", 1)[0])
    return files


def build_revision_input(
    root: Path,
    slug: str,
    review_round: int,
    worker_mode: str,
    previous_worker_output_path: Path,
    review_output_path: Path,
    output_path: Path,
) -> Dict[str, Any]:
    worker_data = _read_json(previous_worker_output_path)
    review_data = _read_json(review_output_path)

    grouped_reviews: Dict[str, List[Dict[str, Any]]] = defaultdict(list)
    for item in review_data.get("finding_reviews") or []:
        parent = item.get("parent_finding_id") or item.get("finding_id") or item.get("packet_id")
        if parent:
            grouped_reviews[parent].append(item)

    findings = worker_data.get("findings") or []
    targets: List[Dict[str, Any]] = []
    touched_ids = set()

    for finding in findings:
        finding_id = finding.get("finding_id")
        if not finding_id:
            continue
        reviews = grouped_reviews.get(finding_id, [])
        if not reviews:
            continue
        touched_ids.add(finding_id)
        scope_files = {
            finding.get("source_file_path"),
            finding.get("sink_file_path"),
            finding.get("file_path"),
        }
        for item in reviews:
            scope_files.update(_files_from_review_item(item))
        scope_files = {value for value in scope_files if value}
        targets.append(
            {
                "finding_id": finding_id,
                "previous_finding": _compact_finding(finding),
                "review_feedback": {
                    "aggregate_assessment": "needs_more_evidence"
                    if any(item.get("assessment") == "needs_more_evidence" for item in reviews)
                    else "field_fix",
                    "packet_count": len(reviews),
                    "packets": reviews,
                },
                "source_scope_files": sorted(scope_files),
            }
        )

    untouched = [
        finding.get("finding_id")
        for finding in findings
        if finding.get("finding_id") and finding.get("finding_id") not in touched_ids
    ]

    payload = {
        "plugin_slug": slug,
        "worker_round": review_round + 1,
        "worker_mode": worker_mode,
        "task": {
            "role": f"phase2_worker_{worker_mode}",
            "goal": "Revise the Phase 2 findings using reviewer critique without restarting a whole-plugin audit.",
            "output_path": str(output_path),
            "previous_worker_output_path": str(previous_worker_output_path),
            "review_output_path": str(review_output_path),
        },
        "previous_worker_summary": {
            "analysis_summary": worker_data.get("analysis_summary"),
            "overall_risk": worker_data.get("overall_risk"),
            "total_findings_analyzed": worker_data.get("total_findings_analyzed"),
            "true_positives": worker_data.get("true_positives"),
            "false_positives": worker_data.get("false_positives"),
            "needs_review": worker_data.get("needs_review"),
            "finding_count": len(findings),
        },
        "review_summary": {
            "review_status": review_data.get("review_status"),
            "notes": (review_data.get("summary") or {}).get("notes"),
            "material_issues_found": (review_data.get("summary") or {}).get("material_issues_found"),
            "finding_review_count": len(review_data.get("finding_reviews") or []),
            "missed_finding_count": len(review_data.get("missed_findings") or []),
        },
        "revision_targets": targets,
        "untouched_finding_ids": untouched,
        "missed_findings": review_data.get("missed_findings") or [],
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description="Build JSON-first Phase 2 revision input.")
    parser.add_argument("slug")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--round", type=int, required=True)
    parser.add_argument("--worker-mode", default="revision")
    parser.add_argument("--previous-worker-output", required=True)
    parser.add_argument("--review-output", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    build_revision_input(
        root=Path(args.root),
        slug=args.slug,
        review_round=args.round,
        worker_mode=args.worker_mode,
        previous_worker_output_path=Path(args.previous_worker_output),
        review_output_path=Path(args.review_output),
        output_path=Path(args.output),
    )


if __name__ == "__main__":
    main()
