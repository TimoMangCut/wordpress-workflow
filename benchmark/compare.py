#!/usr/bin/env python3
"""
benchmark/compare.py — Pipeline benchmark comparison tool
Session 0: ground truth + compare.py
Session 26: Option D — read gate output (phase3.final.json), not phase2 verdicts.

Compares pipeline phase3 output against ground truth to compute:
  - Quality Score = TP / (TP + FP + FN)
    (UNCERTAIN not in QS denominator — they're undecided, neither right nor wrong)
  - Decision Rate = (TP + FP) / (TP + FP + FN + UNCERTAIN)
    (UNCERTAIN counts as "not yet decided" in DR — measures gate decisiveness)

Metric semantics (Option D):
  TP           = CONFIRMED or PLAUSIBLE finding that matches a GT finding
  FP           = CONFIRMED or PLAUSIBLE finding that does NOT match any GT finding
  FN           = GT finding not matched by any CONFIRMED/PLAUSIBLE pipeline finding
  UNCERTAIN    = Gate-undecided findings (in DR denominator; not in QS denominator)
  ACCEPTED_FP  = Correctly rejected findings (not in any denominator)

Source ref: change_manifest_session_25.json:deferred_reason.DI-24-03
            (user approval of Option D in Session 25 via session_cards/session_25)

Usage:
  python3 benchmark/compare.py <slug>
  python3 benchmark/compare.py --all
  python3 benchmark/compare.py --all --save-baseline
"""

import json
import sys
import os
import glob
from datetime import datetime
from pathlib import Path


REPO_ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(REPO_ROOT / "tools" / "bin"))

from artifact_freshness import resolve_canonical_phase3_path

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
# Extract pipeline findings from phase3 final/gate JSON (Option D)
# ---------------------------------------------------------------------------

def load_phase3_final(slug: str) -> dict:
    """Load the canonical Phase 3 artifact for a slug.

    `phase3.final.json` is canonical only when it is not older than `phase3.json`.
    """
    canonical_path = resolve_canonical_phase3_path(PHASE3_DIR, slug)
    if canonical_path is not None:
        with open(canonical_path) as f:
            return json.load(f)
    raise FileNotFoundError(
        f"Phase3 output not found for slug: {slug}"
    )


def load_ground_truth(slug: str) -> dict:
    """Load benchmark/ground-truth/<slug>.json"""
    path = GROUND_TRUTH_DIR / f"{slug}.json"
    if not path.exists():
        raise FileNotFoundError(f"Ground truth not found: {path}")
    with open(path) as f:
        return json.load(f)


def extract_gate_findings(phase3: dict) -> tuple:
    """
    Option D extraction: read validation_status from phase3 validated_findings.

    Returns:
      decided_findings  — list of (validated_finding, match_dict) for CONFIRMED/PLAUSIBLE
      uncertain_count   — count of UNCERTAIN findings (undecided; in DR denominator)
      accepted_fp_count — count of ACCEPTED_FP findings (excluded from all denominators)
    """
    decided_findings = []  # (validated_finding, match_dict)
    uncertain_count = 0
    accepted_fp_count = 0

    for vf in phase3.get("validated_findings", []):
        status = vf.get("validation_status", "").upper()
        if status in ("CONFIRMED", "PLAUSIBLE"):
            decided_findings.append(vf)
        elif status == "UNCERTAIN":
            uncertain_count += 1
        elif status == "ACCEPTED_FP":
            accepted_fp_count += 1
        # LIKELY_HALLUCINATION: treated like ACCEPTED_FP (excluded from denominators)

    return decided_findings, uncertain_count, accepted_fp_count


def _finding_to_match_dict(validated_finding: dict) -> dict:
    """
    Convert a phase3 validated_finding into a flat dict for matching against GT.
    Extracts the fields needed for sink file+line matching.

    Phase3 validated_findings now carry sink_file_path and sink_line_number directly
    (propagated from Phase 2 by the gate). Fall back to extracting from check_notes
    for backwards compatibility with older gate runs.
    """
    d = {}

    # vuln_type: now propagated from Phase 2 by the gate
    d["vuln_type"] = validated_finding.get("vuln_type", "unknown")

    # sink_file: prefer direct field, fall back to check_notes.file_exists note
    notes = validated_finding.get("check_notes", {})
    sink_file = validated_finding.get("sink_file_path") or ""
    if not sink_file:
        file_exists_note = notes.get("file_exists", "")
        # Pattern: "exists: path/to/file.php" or "basename resolved uniquely → path/to/file.php"
        if "exists:" in file_exists_note:
            sink_file = file_exists_note.split("exists:", 1)[1].strip()
        elif "→" in file_exists_note:
            sink_file = file_exists_note.split("→", 1)[1].strip()
    d["sink_file"] = sink_file

    # sink_line_approx: prefer direct field, fall back to code_evidence note extraction
    sink_line = validated_finding.get("sink_line_number") or -1
    if sink_line == -1:
        code_evidence_note = notes.get("code_evidence", "")
        # Pattern: "sink function '...' not found near line N"
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
# Core metrics computation (Option D)
# ---------------------------------------------------------------------------

def compute_metrics(slug: str) -> dict:
    """
    Compute Quality Score and Decision Rate for one plugin.
    Uses Option D: reads gate validation_status, not phase2 verdicts.

    Returns dict with:
      tp, fp, fn, uncertain, accepted_fp,
      quality_score, decision_rate,
      slug, details
    """
    phase3 = load_phase3_final(slug)
    gt = load_ground_truth(slug)

    gt_findings = gt.get("findings", [])
    decided_findings, uncertain_count, accepted_fp_count = extract_gate_findings(phase3)

    # Convert CONFIRMED/PLAUSIBLE findings to matchable dicts
    match_dicts = [_finding_to_match_dict(vf) for vf in decided_findings]

    # --- TP count: CONFIRMED/PLAUSIBLE finding matches a GT finding ---
    matched_gt = set()
    tp_count = 0
    tp_details = []
    for pf in match_dicts:
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

    # --- FP count: CONFIRMED/PLAUSIBLE finding NOT matching any GT ---
    fp_count = len(match_dicts) - tp_count

    # --- FN count: GT finding NOT matched by any CONFIRMED/PLAUSIBLE pipeline finding ---
    fn_count = len(gt_findings) - len(matched_gt)

    # --- Quality Score: TP / (TP + FP + FN)
    # UNCERTAIN not in QS denominator (undecided — not right, not wrong)
    denom_quality = tp_count + fp_count + fn_count
    quality_score = tp_count / denom_quality if denom_quality > 0 else None

    # --- Decision Rate: (TP + FP) / (TP + FP + FN + UNCERTAIN)
    # UNCERTAIN in DR denominator — they're unresolved decisions
    # ACCEPTED_FP excluded from DR — correctly rejected, not undecided
    denom_decision = tp_count + fp_count + fn_count + uncertain_count
    decision_rate = (tp_count + fp_count) / denom_decision if denom_decision > 0 else None

    return {
        "slug": slug,
        "tp": tp_count,
        "fp": fp_count,
        "fn": fn_count,
        "uncertain": uncertain_count,
        "accepted_fp": accepted_fp_count,
        "quality_score": quality_score,
        "decision_rate": decision_rate,
        "gt_findings_count": len(gt_findings),
        "pipeline_decided_count": len(decided_findings),
        "tp_details": tp_details,
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
          f"UNCERTAIN={result['uncertain']} ACCEPTED_FP={result['accepted_fp']}")
    return result


def discover_slugs() -> list[str]:
    """Find all slugs that have BOTH a ground truth and a phase3 output."""
    gt_slugs = {p.stem for p in GROUND_TRUTH_DIR.glob("*.json")}
    ph3_slugs = set()
    for path in PHASE3_DIR.glob("*-phase3.json"):
        ph3_slugs.add(path.stem.replace("-phase3", ""))
    for path in PHASE3_DIR.glob("*-phase3.final.json"):
        ph3_slugs.add(path.stem.replace("-phase3.final", ""))
    common = sorted(gt_slugs & ph3_slugs)
    return common


def save_results(results: list[dict], path: Path) -> None:
    payload = {
        "run_timestamp": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "benchmark_version": "option_d",
        "plugins": results,
        "aggregate": {
            "total_tp": sum(r["tp"] for r in results),
            "total_fp": sum(r["fp"] for r in results),
            "total_fn": sum(r["fn"] for r in results),
            "total_uncertain": sum(r["uncertain"] for r in results),
            "total_accepted_fp": sum(r["accepted_fp"] for r in results),
        }
    }
    agg = payload["aggregate"]
    d_q = agg["total_tp"] + agg["total_fp"] + agg["total_fn"]
    # DR denominator includes UNCERTAIN (unresolved decisions)
    d_dr = agg["total_tp"] + agg["total_fp"] + agg["total_fn"] + agg["total_uncertain"]
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
