#!/usr/bin/env python3
"""
benchmark/compare.py — Pipeline benchmark comparison tool
Session 0: ground truth + compare.py

Compares pipeline phase3 output against ground truth to compute:
  - Quality Score = TP / (TP + FP + FN)
  - Decision Rate = (TP + FP) / (TP + FP + REVIEW_HIT + REVIEW_MISS)

Usage:
  python3 benchmark/compare.py <slug>
  python3 benchmark/compare.py --all
  python3 benchmark/compare.py --all --save-baseline

Source ref: skill-sets-framework.md:412-427
"""

import json
import sys
import os
import glob
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent
GROUND_TRUTH_DIR = REPO_ROOT / "benchmark" / "ground-truth"
RESULTS_DIR = REPO_ROOT / "benchmark" / "results"
PHASE3_DIR = REPO_ROOT / "reports" / "phase3"


# ---------------------------------------------------------------------------
# Matching logic (per skill-sets-framework.md:413-419)
# ---------------------------------------------------------------------------

def _is_single_ep(gt_finding: dict) -> bool:
    return gt_finding.get("flow_type") != "cross_ep"


def _match_single_ep(pipeline_finding: dict, gt_finding: dict) -> bool:
    """
    Single-EP match: same vuln_type + same sink file ±10 lines
    (skill-sets-framework.md:415)
    """
    if pipeline_finding.get("vuln_type") != gt_finding.get("vuln_type"):
        return False

    # Sink file: basename comparison (pipeline may store full path or basename)
    pf_sink = os.path.basename(pipeline_finding.get("sink_file", ""))
    gt_sink = os.path.basename(gt_finding.get("sink_file", ""))
    if not pf_sink or not gt_sink:
        return False
    if pf_sink != gt_sink:
        return False

    # Line proximity ±10
    try:
        pf_line = int(pipeline_finding.get("sink_line_approx", -999))
        gt_line = int(gt_finding.get("sink_line_approx", -999))
        if pf_line < 0 or gt_line < 0:
            return False
        return abs(pf_line - gt_line) <= 10
    except (TypeError, ValueError):
        return False


def _match_cross_ep(pipeline_finding: dict, gt_finding: dict) -> bool:
    """
    Cross-EP match: same vuln_type + same storage_key + same sink file ±10 lines
    (skill-sets-framework.md:416)
    """
    if pipeline_finding.get("vuln_type") != gt_finding.get("vuln_type"):
        return False
    if pipeline_finding.get("storage_key") != gt_finding.get("storage_key"):
        return False

    pf_sink = os.path.basename(pipeline_finding.get("sink_file", ""))
    gt_sink = os.path.basename(gt_finding.get("sink_file", ""))
    if not pf_sink or not gt_sink:
        return False
    if pf_sink != gt_sink:
        return False

    try:
        pf_line = int(pipeline_finding.get("sink_line_approx", -999))
        gt_line = int(gt_finding.get("sink_line_approx", -999))
        if pf_line < 0 or gt_line < 0:
            return False
        return abs(pf_line - gt_line) <= 10
    except (TypeError, ValueError):
        return False


def matches(pipeline_finding: dict, gt_finding: dict) -> bool:
    if _is_single_ep(gt_finding):
        return _match_single_ep(pipeline_finding, gt_finding)
    else:
        return _match_cross_ep(pipeline_finding, gt_finding)


# ---------------------------------------------------------------------------
# Extract pipeline findings from phase3 JSON
# ---------------------------------------------------------------------------

def load_phase3(slug: str) -> dict:
    """Load reports/<slug>-phase3.json"""
    path = PHASE3_DIR / f"{slug}-phase3.json"
    if not path.exists():
        raise FileNotFoundError(f"Phase3 output not found: {path}")
    with open(path) as f:
        return json.load(f)


def load_ground_truth(slug: str) -> dict:
    """Load benchmark/ground-truth/<slug>.json"""
    path = GROUND_TRUTH_DIR / f"{slug}.json"
    if not path.exists():
        raise FileNotFoundError(f"Ground truth not found: {path}")
    with open(path) as f:
        return json.load(f)


def extract_pipeline_findings(phase3: dict) -> tuple[list, list]:
    """
    Returns (tp_findings, review_findings) from phase3 validated_findings.
    TP = verdict == "TP", REVIEW = verdict == "REVIEW".
    FP = verdict == "FP" (also tracked for completeness).
    """
    tp_findings = []
    review_findings = []
    fp_findings = []

    for f in phase3.get("validated_findings", []):
        verdict = f.get("verdict", "").upper()
        if verdict == "TP":
            tp_findings.append(f)
        elif verdict == "REVIEW":
            review_findings.append(f)
        elif verdict == "FP":
            fp_findings.append(f)

    return tp_findings, review_findings, fp_findings


def _finding_to_match_dict(validated_finding: dict) -> dict:
    """
    Convert a phase3 validated_finding into a flat dict for matching.
    Extracts the fields that compare.py needs.
    Phase3 findings reference entry point and sink via check_notes.
    We use available structured fields.
    """
    # Phase3 validated_findings don't have a uniform flat structure matching
    # ground truth schema directly. They have resolved_entry_point_id and
    # check_notes with sink info. We extract what we can.
    d = {}

    # vuln_type: not directly in phase3 validated_finding — stored in check_notes
    # or the original phase2 finding (not linked here). Use "unknown" fallback.
    d["vuln_type"] = validated_finding.get("vuln_type", "unknown")

    # sink_file: extracted from check_notes if present
    notes = validated_finding.get("check_notes", {})
    file_exists_note = notes.get("file_exists", "")
    # Pattern: "exists: path/to/file.php" or "basename resolved uniquely → path/to/file.php"
    sink_file = ""
    if "exists:" in file_exists_note:
        sink_file = file_exists_note.split("exists:", 1)[1].strip()
    elif "→" in file_exists_note:
        sink_file = file_exists_note.split("→", 1)[1].strip()
    d["sink_file"] = sink_file

    # sink_line_approx: from check_notes code_evidence note (rough extraction)
    code_evidence_note = notes.get("code_evidence", "")
    # Pattern: "sink function '...' not found near line N" — extract line
    sink_line = -1
    if "near line" in code_evidence_note:
        try:
            sink_line = int(code_evidence_note.split("near line")[1].strip().split()[0])
        except (ValueError, IndexError):
            pass
    d["sink_line_approx"] = sink_line

    # flow_type and storage_key: not in current phase3 output schema
    d["flow_type"] = validated_finding.get("flow_type", None)
    d["storage_key"] = validated_finding.get("storage_key", None)

    return d


# ---------------------------------------------------------------------------
# Core metrics computation
# ---------------------------------------------------------------------------

def compute_metrics(slug: str) -> dict:
    """
    Compute Quality Score and Decision Rate for one plugin.

    Returns dict with:
      tp, fp, fn, review_hit, review_miss,
      quality_score, decision_rate,
      slug, details
    """
    phase3 = load_phase3(slug)
    gt = load_ground_truth(slug)

    gt_findings = gt.get("findings", [])
    tp_pf, review_pf, fp_pf = extract_pipeline_findings(phase3)

    # Convert pipeline findings to matchable dicts
    tp_match = [_finding_to_match_dict(f) for f in tp_pf]
    review_match = [_finding_to_match_dict(f) for f in review_pf]

    # --- TP count: pipeline TP finding matches a ground truth finding ---
    matched_gt = set()
    tp_count = 0
    tp_details = []
    for pf in tp_match:
        for i, gf in enumerate(gt_findings):
            if i not in matched_gt and matches(pf, gf):
                matched_gt.add(i)
                tp_count += 1
                tp_details.append({
                    "pipeline_sink_file": pf["sink_file"],
                    "gt_sink_file": gf.get("sink_file", ""),
                    "match": "TP"
                })
                break

    # --- FP count: pipeline TP finding NOT matching any ground truth ---
    fp_count = len(tp_match) - tp_count

    # --- FN count: ground truth finding NOT matched by any pipeline TP ---
    fn_count = len(gt_findings) - len(matched_gt)

    # --- REVIEW_HIT: pipeline REVIEW finding matches a ground truth location ---
    review_matched_gt = set()
    review_hit = 0
    review_miss = 0
    for pf in review_match:
        matched = False
        for i, gf in enumerate(gt_findings):
            if i not in review_matched_gt and matches(pf, gf):
                review_matched_gt.add(i)
                review_hit += 1
                matched = True
                break
        if not matched:
            review_miss += 1

    # --- Metrics ---
    denom_quality = tp_count + fp_count + fn_count
    quality_score = tp_count / denom_quality if denom_quality > 0 else None

    denom_decision = tp_count + fp_count + review_hit + review_miss
    decision_rate = (tp_count + fp_count) / denom_decision if denom_decision > 0 else None

    return {
        "slug": slug,
        "tp": tp_count,
        "fp": fp_count,
        "fn": fn_count,
        "review_hit": review_hit,
        "review_miss": review_miss,
        "quality_score": quality_score,
        "decision_rate": decision_rate,
        "gt_findings_count": len(gt_findings),
        "pipeline_tp_count": len(tp_match),
        "pipeline_review_count": len(review_match),
    }


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def run_single(slug: str) -> dict:
    print(f"  [{slug}] computing...", end=" ", flush=True)
    result = compute_metrics(slug)
    qs = f"{result['quality_score']:.4f}" if result["quality_score"] is not None else "N/A"
    dr = f"{result['decision_rate']:.4f}" if result["decision_rate"] is not None else "N/A"
    print(f"QS={qs}  DR={dr}  TP={result['tp']} FP={result['fp']} FN={result['fn']} "
          f"RH={result['review_hit']} RM={result['review_miss']}")
    return result


def discover_slugs() -> list[str]:
    """Find all slugs that have BOTH a ground truth and a phase3 output."""
    gt_slugs = {p.stem for p in GROUND_TRUTH_DIR.glob("*.json")}
    ph3_slugs = {p.stem.replace("-phase3", "") for p in PHASE3_DIR.glob("*-phase3.json")}
    common = sorted(gt_slugs & ph3_slugs)
    return common


def save_results(results: list[dict], path: Path) -> None:
    payload = {
        "run_timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "plugins": results,
        "aggregate": {
            "total_tp": sum(r["tp"] for r in results),
            "total_fp": sum(r["fp"] for r in results),
            "total_fn": sum(r["fn"] for r in results),
            "total_review_hit": sum(r["review_hit"] for r in results),
            "total_review_miss": sum(r["review_miss"] for r in results),
        }
    }
    agg = payload["aggregate"]
    d_q = agg["total_tp"] + agg["total_fp"] + agg["total_fn"]
    d_dr = agg["total_tp"] + agg["total_fp"] + agg["total_review_hit"] + agg["total_review_miss"]
    payload["aggregate"]["quality_score"] = agg["total_tp"] / d_q if d_q > 0 else None
    payload["aggregate"]["decision_rate"] = (
        (agg["total_tp"] + agg["total_fp"]) / d_dr if d_dr > 0 else None
    )
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
    print(f"\n  Saved → {path.relative_to(REPO_ROOT)}")


def main():
    args = sys.argv[1:]

    if not args:
        print("Usage:")
        print("  python3 benchmark/compare.py <slug>")
        print("  python3 benchmark/compare.py --all")
        print("  python3 benchmark/compare.py --all --save-baseline")
        sys.exit(1)

    save_baseline = "--save-baseline" in args
    args = [a for a in args if a != "--save-baseline"]

    if args == ["--all"]:
        slugs = discover_slugs()
        if not slugs:
            print("No slugs found with both ground truth and phase3 output.")
            sys.exit(1)
        print(f"Running benchmark on {len(slugs)} plugin(s): {', '.join(slugs)}\n")
        results = [run_single(slug) for slug in slugs]

        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        run_path = RESULTS_DIR / f"run_{timestamp}.json"
        save_results(results, run_path)

        if save_baseline:
            baseline_path = RESULTS_DIR / "baseline.json"
            save_results(results, baseline_path)
            print(f"  Baseline saved → {baseline_path.relative_to(REPO_ROOT)}")

        # Always save baseline.json if it doesn't exist yet
        baseline_path = RESULTS_DIR / "baseline.json"
        if not baseline_path.exists():
            save_results(results, baseline_path)
            print(f"  (First run — baseline.json auto-created)")

    elif len(args) == 1 and not args[0].startswith("--"):
        slug = args[0]
        result = run_single(slug)
        timestamp = datetime.utcnow().strftime("%Y%m%d_%H%M%S")
        run_path = RESULTS_DIR / f"run_{timestamp}.json"
        save_results([result], run_path)
    else:
        print(f"Unknown arguments: {args}")
        sys.exit(1)


if __name__ == "__main__":
    main()
