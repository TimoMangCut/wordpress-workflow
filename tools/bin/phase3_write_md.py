#!/usr/bin/env python3
"""Render a human-readable Phase 3 markdown report from canonical Phase 3 JSON."""

from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
from typing import Any, Dict, List, Optional

from artifact_freshness import resolve_canonical_phase3_path
from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root


def load_json(path: Path) -> Optional[dict]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return None


def compute_ir_index(slug: str, reports_dir: Path) -> int:
    layout = build_report_layout(reports_dir)
    ir_files = sorted(layout.phase1.glob("*-ir.json"))
    idx = 0
    for ir_file in ir_files:
        file_slug = ir_file.name[:-8]
        if file_slug.startswith("plugin-"):
            continue
        idx += 1
        if file_slug == slug:
            return idx
    return 0


def semgrep_signal(reports_dir: Path, slug: str) -> str:
    p = build_report_layout(reports_dir).phase1 / f"{slug}-semgrep.json"
    if not p.exists():
        return "missing"
    data = load_json(p) or {}
    results = data.get("results", []) or []
    return f"ok ({len(results)} results)"


def psalm_signal(reports_dir: Path, slug: str) -> str:
    p = build_report_layout(reports_dir).phase1 / f"{slug}-psalm.sarif"
    if not p.exists():
        return "missing"
    data = load_json(p)
    if not isinstance(data, dict):
        return "invalid"
    if "status" in data:
        status = str(data.get("status", "unknown"))
        if status == "timeout":
            return f"timeout ({data.get('timeout_seconds', '?')}s)"
        if status == "error":
            return f"error (exit={data.get('exit_code', '?')})"
        if status == "not_installed":
            return "not_installed"
        return status
    runs = data.get("runs", []) or []
    if not runs:
        return "ok (0 results)"
    results = runs[0].get("results", []) or []
    return f"ok ({len(results)} results)"


def location_line(finding: dict) -> str:
    src_fp = finding.get("source_file_path") or "N/A"
    src_ln = finding.get("source_line_number") or "N/A"
    sink_fp = finding.get("sink_file_path") or finding.get("file_path") or "N/A"
    sink_ln = finding.get("sink_line_number") or finding.get("line_number") or "N/A"
    return f"source `{src_fp}:{src_ln}` -> sink `{sink_fp}:{sink_ln}`"


def _clean_text(value: Any, default: str = "unknown") -> str:
    if value is None:
        return default
    s = str(value).strip()
    return s if s else default


def short_description_two_sentences(fid: str, finding: dict, validation: dict) -> str:
    status = _clean_text(validation.get("validation_status"), "UNCERTAIN").upper()
    vuln_type = _clean_text(finding.get("vuln_type"), "security issue")
    sink_fp = _clean_text(finding.get("sink_file_path") or finding.get("file_path"), "N/A")
    sink_ln = _clean_text(finding.get("sink_line_number") or finding.get("line_number"), "N/A")
    ep = _clean_text(validation.get("resolved_entry_point_id") or finding.get("entry_point_id"), "N/A")
    conf = float(validation.get("confidence_score", 0.0))

    sentence1 = f"Finding `{fid}` flags `{vuln_type}` at `{sink_fp}:{sink_ln}` via entry point `{ep}`."
    if status == "CONFIRMED":
        sentence2 = f"Gate validation currently marks it as confirmed with confidence `{conf:.2f}` based on available static evidence."
    elif status in ("PLAUSIBLE", "UNCERTAIN"):
        sentence2 = f"Gate validation currently keeps it as `{status}` (confidence `{conf:.2f}`), so dynamic verification is still required."
    else:
        sentence2 = f"Gate validation currently treats it as non-actionable (`{status}`) with no confirmed exploit path."
    return f"{sentence1} {sentence2}"


def infer_highest_impact(finding: dict, validation: dict) -> str:
    status = _clean_text(validation.get("validation_status"), "UNCERTAIN").upper()
    auth = _clean_text(finding.get("auth_required"), "unknown")
    vuln = _clean_text(finding.get("vuln_type"), "").lower()

    if status in ("ACCEPTED_FP", "LIKELY_HALLUCINATION"):
        return "No confirmed measurable security impact in current plugin-local evidence."

    if "sql" in vuln:
        impact = "Potential unauthorized database read/write and sensitive record exposure."
    elif "xss" in vuln:
        impact = "Potential execution of attacker-controlled JavaScript in victim browser context."
    elif "ssrf" in vuln:
        impact = "Potential server-side requests to internal or restricted network resources."
    elif "file" in vuln and ("write" in vuln or "upload" in vuln):
        impact = "Potential unauthorized file/media creation or overwrite in WordPress uploads workflow."
    elif "idor" in vuln or "access control" in vuln or "authorization" in vuln:
        impact = "Potential unauthorized read/write actions beyond intended role boundary."
    elif "csrf" in vuln or "nonce" in vuln:
        impact = "Potential forced state-changing requests without valid user intent."
    else:
        impact = "Potential unauthorized state change or data disclosure if runtime checks are bypassed."

    return f"{impact} Minimum attacker context: `{auth}`."


def build_poc_steps(slug: str, finding: dict, validation: dict) -> List[str]:
    status = _clean_text(validation.get("validation_status"), "UNCERTAIN").upper()
    auth = _clean_text(finding.get("auth_required"), "unknown")
    ep = _clean_text(validation.get("resolved_entry_point_id") or finding.get("entry_point_id"), "N/A")
    src_fp = _clean_text(finding.get("source_file_path"), "N/A")
    src_ln = _clean_text(finding.get("source_line_number"), "N/A")
    sink_fp = _clean_text(finding.get("sink_file_path") or finding.get("file_path"), "N/A")
    sink_ln = _clean_text(finding.get("sink_line_number") or finding.get("line_number"), "N/A")
    poc_hint = _clean_text(finding.get("poc_description"), "")

    steps: List[str] = []
    steps.append("Step 1 (Setup): Prepare a clean WordPress lab, enable debug logging, and snapshot database state.")
    steps.append(
        f"Step 2 (Activate): Install and activate plugin `{slug}`, then create/login with minimum role `{auth}` required by this path."
    )

    if poc_hint and poc_hint.upper() not in {"N/A", "NA", "NONE"}:
        attack = poc_hint
    else:
        attack = (
            f"Use entry point `{ep}` and send crafted input from source `{src_fp}:{src_ln}` "
            f"toward sink `{sink_fp}:{sink_ln}`."
        )
    steps.append(f"Step 3 (Attack): {attack}")

    if status in ("ACCEPTED_FP", "LIKELY_HALLUCINATION"):
        verify = "Confirm the action is rejected or results in no unauthorized read/write/privilege change."
    else:
        verify = "Confirm measurable impact occurs (unauthorized data read/write, privilege effect, or persistent state change)."
    steps.append(f"Step 4 (Verify): {verify}")
    return steps


def render_status_block(title: str, rows: List[tuple[str, dict, dict]], slug: str) -> List[str]:
    out = [f"## {title}"]
    if not rows:
        out.append("None.")
        out.append("")
        return out

    for fid, f, v in rows:
        status = _clean_text(v.get("validation_status"), "N/A")
        vuln_type = _clean_text(f.get("vuln_type"), "unknown")
        auth_required = _clean_text(f.get("auth_required"), "unknown")
        out.append(f"### {fid}")
        out.append(f"- Type: `{vuln_type}`")
        out.append(f"- Minimum Role/Capability: `{auth_required}`")
        out.append(
            f"- Severity: `{f.get('severity', 'unknown')}` | "
            f"Confidence: `{v.get('confidence_score', 0):.2f}`"
        )
        out.append(f"- Gate Verdict: `{status}`")
        out.append(
            f"- Entry point: claimed `{f.get('entry_point_id', 'N/A')}`, resolved `{v.get('resolved_entry_point_id', 'N/A')}`"
        )
        out.append(f"- Trace: {location_line(f)}")
        out.append(f"- Description (2 sentences): {short_description_two_sentences(fid, f, v)}")
        out.append(f"- Highest Impact: {infer_highest_impact(f, v)}")
        issues = v.get("issues", []) or []
        if issues:
            out.append(f"- Validation issues: `{', '.join(issues)}`")
        out.append("- PoC (Setup -> Activate -> Attack -> Verify):")
        for step in build_poc_steps(slug, f, v):
            out.append(f"  - {step}")
        out.append("")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description="Write deterministic Phase 3 markdown from gate JSON")
    ap.add_argument("slug")
    ap.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"))
    ap.add_argument("--index", type=int, default=0)
    args = ap.parse_args()

    reports_dir = Path(args.reports_dir).resolve()
    layout = build_report_layout(reports_dir).ensure()
    slug = args.slug
    gate_path = resolve_canonical_phase3_path(layout.phase3, slug)
    phase2_path = layout.phase2 / f"{slug}-phase2.json"
    phase3_dir = layout.phase3

    idx = args.index if args.index > 0 else compute_ir_index(slug, reports_dir)
    if idx <= 0:
        print(f"[ERROR] Could not resolve IR-order index for slug: {slug}")
        return 1

    out_path = phase3_dir / f"{idx}-{slug}.md"

    if gate_path is None:
        print(f"[ERROR] Phase 3 artifact missing for slug: {slug}")
        return 1

    gate = load_json(gate_path)
    if not gate:
        print(f"[ERROR] Gate JSON missing/invalid: {gate_path}")
        return 1

    phase2 = load_json(phase2_path) or {}
    findings = phase2.get("findings", []) or []
    by_id: Dict[str, dict] = {str(f.get("finding_id")): f for f in findings if f.get("finding_id")}
    validated = gate.get("validated_findings", []) or []

    rows_confirmed: List[tuple[str, dict, dict]] = []
    rows_verify: List[tuple[str, dict, dict]] = []
    rows_hallucinated: List[tuple[str, dict, dict]] = []
    rows_fp: List[tuple[str, dict, dict]] = []
    stored_rows: List[tuple[str, dict, dict]] = []

    for i, v in enumerate(validated):
        fid = str(v.get("finding_id") or f"finding_{i+1}")
        f = by_id.get(fid, {})
        status = v.get("validation_status")
        if status == "CONFIRMED":
            rows_confirmed.append((fid, f, v))
        elif status in ("PLAUSIBLE", "UNCERTAIN"):
            rows_verify.append((fid, f, v))
        elif status == "LIKELY_HALLUCINATION":
            rows_hallucinated.append((fid, f, v))
        elif status == "ACCEPTED_FP":
            rows_fp.append((fid, f, v))

        vuln_type = str(f.get("vuln_type", "")).lower()
        if "stored" in vuln_type or "second" in vuln_type or f.get("storage_key"):
            stored_rows.append((fid, f, v))

    p1 = gate.get("phase1_summary", {})
    p2 = gate.get("phase2_summary", {})
    p3 = gate.get("phase3_summary", {})

    lines: List[str] = []
    lines.append(f"# Phase 3 Gate Report - `{slug}`")
    lines.append("")
    now_utc = dt.datetime.now(dt.timezone.utc).isoformat()
    lines.append(f"_Generated: {now_utc}_")
    lines.append("")
    lines.append("## Plugin Overview")
    lines.append(f"- Plugin slug: `{slug}`")
    lines.append(
        f"- Phase 1: EPs `{p1.get('entry_points', 0)}`, anomalies `{p1.get('anomalies', 0)}`, "
        f"sources `{p1.get('sources', 0)}`, sinks `{p1.get('sinks', 0)}`"
    )
    lines.append(
        f"- Phase 2: total `{p2.get('total', 0)}`, TP `{p2.get('tp', 0)}`, FP `{p2.get('fp', 0)}`, REVIEW `{p2.get('review', 0)}`"
    )
    lines.append(
        f"- Phase 3: confirmed `{p3.get('confirmed', 0)}`, plausible `{p3.get('plausible', 0)}`, "
        f"uncertain `{p3.get('uncertain', 0)}`, likely_hallucination `{p3.get('likely_hallucination', 0)}`"
    )
    lines.append("")
    lines.append("## Tool Signals")
    lines.append(f"- Semgrep: `{semgrep_signal(reports_dir, slug)}`")
    lines.append(f"- Psalm: `{psalm_signal(reports_dir, slug)}`")
    lines.append("")
    lines.extend(render_status_block("Confirmed Findings", rows_confirmed, slug))
    lines.extend(render_status_block("Needs Dynamic Verification", rows_verify, slug))
    lines.extend(render_status_block("Likely Hallucinations", rows_hallucinated, slug))
    lines.extend(render_status_block("Rejected Findings (Accepted FP)", rows_fp, slug))
    lines.append("## Why Not Confirmed")
    if not rows_verify and not rows_hallucinated:
        lines.append("No unresolved findings.")
    else:
        for fid, _f, v in rows_verify + rows_hallucinated:
            issues = v.get("issues", []) or []
            if not issues:
                continue
            lines.append(f"- `{fid}`: {', '.join(issues)}")
    lines.append("")
    lines.append("## Stored/Second-order Notes")
    if not stored_rows:
        lines.append("No stored/second-order findings in this plugin.")
    else:
        for fid, f, _v in stored_rows:
            lines.append(
                f"- `{fid}`: vuln_type `{f.get('vuln_type', 'N/A')}`, "
                f"storage_key `{f.get('storage_key', 'N/A')}`"
            )
    lines.append("")
    lines.append("## Overall Assessment")
    lines.append(
        "Deterministic gate output is authoritative for status classification. "
        "If LLM skeptic review exists, use it as supplemental counter-evidence only."
    )
    lines.append("")

    for stale_path in phase3_dir.glob(f"*-{slug}.md"):
        if stale_path == out_path:
            continue
        try:
            stale_path.unlink()
        except OSError:
            pass

    out_path.write_text("\n".join(lines), encoding="utf-8")
    print(f"[OK] Gate markdown written: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
