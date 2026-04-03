#!/usr/bin/env python3
"""Phase 2 postprocess — make findings evidence-bound and stable.

Why this exists
---------------
Reducing FP is not about rejecting "unclear" findings late.
It's about forcing clarity *early* so Phase 3 gating is stable and cheap.

This script:
- Normalizes Phase 2 output fields (sink/source locations, aliases)
- Adds deterministic code snippets (sink_snippet/source_snippet)
- Downgrades TP → REVIEW when critical evidence is missing or file cannot be resolved
  (NOT a rejection — it makes uncertainty explicit).

It is intentionally deterministic and fast.
"""

from __future__ import annotations

import argparse
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root


def load_json(path: str) -> Optional[dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def save_json(path: str, obj: dict) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2)
    os.replace(tmp, path)


def norm_path(p: str) -> str:
    return (p or "").replace("\\", "/").lstrip("./")


def normalize_plugin_rel_path(path: str, slug: str, plugin_root: str) -> str:
    raw = (path or "").replace("\\", "/")
    p = norm_path(raw)
    if not p:
        return ""

    plugin_root_norm = os.path.normpath(plugin_root).replace("\\", "/")
    if os.path.isabs(path):
        abs_norm = os.path.normpath(path).replace("\\", "/")
        root_prefix = plugin_root_norm.rstrip("/") + "/"
        if abs_norm.startswith(root_prefix):
            return abs_norm[len(root_prefix):]
        marker = f"/plugins/{slug}/"
        if marker in abs_norm:
            return abs_norm.split(marker, 1)[1]
        return abs_norm

    plugin_prefix = f"plugins/{slug}/"
    if p.startswith(plugin_prefix):
        return p[len(plugin_prefix):]
    slug_prefix = f"{slug}/"
    if p.startswith(slug_prefix):
        return p[len(slug_prefix):]

    marker = f"/plugins/{slug}/"
    if marker in p:
        return p.split(marker, 1)[1]
    return p


def is_within_plugin_root(path: str, plugin_root: str) -> bool:
    try:
        return os.path.commonpath([os.path.realpath(path), os.path.realpath(plugin_root)]) == os.path.realpath(plugin_root)
    except Exception:
        return False


def resolve_plugin_path(candidate: str, plugin_root: str) -> Tuple[str, Optional[str], Optional[str]]:
    candidate = (candidate or "").replace("\\", "/")
    if not candidate:
        return "", None, None

    if os.path.isabs(candidate):
        candidate_abs = candidate
    else:
        candidate_abs = os.path.join(plugin_root, candidate)

    if os.path.exists(candidate_abs):
        if is_within_plugin_root(candidate_abs, plugin_root):
            rel = os.path.relpath(candidate_abs, plugin_root).replace("\\", "/")
            return rel, candidate_abs, None
        return candidate, None, "outside_plugin_root"

    alt = find_unique_by_basename(plugin_root, candidate)
    if alt:
        rel = os.path.relpath(alt, plugin_root).replace("\\", "/")
        return rel, alt, "basename"
    return candidate, None, None


def excerpt(file_path: str, line: int, window: int = 5) -> Optional[str]:
    try:
        with open(file_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
        if line <= 0 or line > len(lines):
            return None
        start = max(1, line - window)
        end = min(len(lines), line + window)
        out = []
        for ln in range(start, end + 1):
            out.append(f"{ln:>5}  {lines[ln-1].rstrip()}\n")
        return "".join(out)
    except Exception:
        return None


def find_unique_by_basename(root: str, rel_path: str) -> Optional[str]:
    """Best-effort resolve when rel_path is wrong but basename exists uniquely."""
    basename = os.path.basename(rel_path)
    hits: List[str] = []
    for r, _, files in os.walk(root):
        for fn in files:
            if fn == basename:
                hits.append(os.path.join(r, fn))
                if len(hits) > 2:
                    return None
    if len(hits) == 1:
        return hits[0]
    return None


def reasoning_to_text(reasoning: Any) -> str:
    if reasoning is None:
        return ""
    if isinstance(reasoning, str):
        return reasoning
    if isinstance(reasoning, (dict, list)):
        try:
            return json.dumps(reasoning, ensure_ascii=False)
        except Exception:
            return str(reasoning)
    return str(reasoning)


def infer_storage_key(reasoning: Any) -> Optional[str]:
    text = reasoning_to_text(reasoning)
    if not text:
        return None
    m = re.search(r"(?:update_option|get_option)\(\s*['\"]([^'\"]+)['\"]", text)
    if m:
        return m.group(1)
    m = re.search(r"(?:update_(?:post|user|term|comment)_meta|get_(?:post|user|term|comment)_meta)\(\s*[^,]+,\s*['\"]([^'\"]+)['\"]", text)
    if m:
        return m.group(1)
    return None


def is_stored(vuln_type: str) -> bool:
    v = (vuln_type or "").lower()
    return ("stored" in v) or ("second" in v)


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Postprocess Phase 2 JSON for evidence binding")
    p.add_argument("slug", help="Plugin slug")
    p.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"))
    p.add_argument("--plugins-dir", default=str(_ROOT_DIR / "plugins"))
    p.add_argument("--phase2-path", default="", help="Override path to phase2 JSON file")
    p.add_argument("--in-place", action="store_true", help="Overwrite reports/phase2/<slug>-phase2.json")
    return p.parse_args()


def main() -> int:
    args = parse_args()
    layout = build_report_layout(args.reports_dir).ensure()
    phase2_path = args.phase2_path or str(layout.phase2 / f"{args.slug}-phase2.json")
    data = load_json(phase2_path)
    if not data:
        print(f"[ERROR] Missing/invalid phase2 json: {phase2_path}")
        return 1

    plugin_root = os.path.join(args.plugins_dir, args.slug)
    if not os.path.isdir(plugin_root):
        print(f"[ERROR] Plugin dir not found: {plugin_root}")
        return 1

    findings = data.get("findings", []) or []
    downgraded = 0

    for f in findings:
        issues: List[str] = []

        # Normalize sink/source location fields.
        if not f.get("sink_file_path") and f.get("file_path"):
            f["sink_file_path"] = f.get("file_path")
        if not f.get("sink_line_number") and f.get("line_number"):
            f["sink_line_number"] = f.get("line_number")

        source_abs = None
        sink_abs = None

        source_path = normalize_plugin_rel_path(str(f.get("source_file_path") or ""), args.slug, plugin_root)
        if source_path:
            if source_path != norm_path(str(f.get("source_file_path") or "")):
                issues.append("source_path_normalized")
            resolved_source_path, resolved_source_abs, source_resolution = resolve_plugin_path(source_path, plugin_root)
            f["source_file_path"] = resolved_source_path
            source_abs = resolved_source_abs
            if source_resolution == "basename":
                issues.append("source_path_fixed_by_basename")
            elif source_resolution == "outside_plugin_root":
                issues.append("source_file_outside_plugin_root")
            elif source_abs is None:
                issues.append("source_file_not_found")

        sink_path = normalize_plugin_rel_path(str(f.get("sink_file_path") or ""), args.slug, plugin_root)
        if sink_path:
            if sink_path != norm_path(str(f.get("sink_file_path") or "")):
                issues.append("sink_path_normalized")
            resolved_sink_path, resolved_sink_abs, sink_resolution = resolve_plugin_path(sink_path, plugin_root)
            f["sink_file_path"] = resolved_sink_path
            sink_abs = resolved_sink_abs
            if sink_resolution == "basename":
                issues.append("sink_path_fixed_by_basename")
            elif sink_resolution == "outside_plugin_root":
                issues.append("sink_file_outside_plugin_root")
            elif sink_abs is None:
                issues.append("sink_file_not_found")

        # Backcompat aliases for downstream tooling.
        if f.get("sink_file_path") and not f.get("file_path"):
            f["file_path"] = f.get("sink_file_path")
        if f.get("sink_line_number") and not f.get("line_number"):
            f["line_number"] = f.get("sink_line_number")
        if f.get("sink_file_path"):
            f["file_path"] = f.get("sink_file_path")
        if f.get("sink_line_number"):
            f["line_number"] = f.get("sink_line_number")

        # Stored: infer storage key if missing
        if is_stored(f.get("vuln_type", "")) and not f.get("storage_key"):
            key = infer_storage_key(f.get("reasoning"))
            if key:
                f["storage_key"] = key
            else:
                issues.append("stored_missing_storage_key")

        # Critical evidence requirements (for TP only)
        if f.get("verdict") == "TP":
            if not f.get("entry_point_id"):
                issues.append("missing_entry_point_id")
            if not f.get("sink_file_path") or not f.get("sink_line_number"):
                issues.append("missing_sink_location")
            if not f.get("sink_function"):
                issues.append("missing_sink_function")

            # Add sink snippet (deterministic)
            if f.get("sink_file_path") and sink_abs and os.path.exists(sink_abs):
                snip = excerpt(sink_abs, int(f.get("sink_line_number") or 0))
                if snip:
                    f["sink_snippet"] = snip
                else:
                    issues.append("sink_snippet_unavailable")

            # Optional: source snippet
            if f.get("source_file_path") and f.get("source_line_number") and source_abs and os.path.exists(source_abs):
                ss = excerpt(source_abs, int(f.get("source_line_number") or 0))
                if ss:
                    f["source_snippet"] = ss
                else:
                    issues.append("source_snippet_unavailable")

            # Downgrade TP→REVIEW if critical evidence missing (do not reject)
            critical = {"missing_entry_point_id", "missing_sink_location", "missing_sink_function", "sink_file_not_found"}
            if any(i in critical for i in issues):
                f["verdict"] = "REVIEW"
                f["postprocess_downgrade_reason"] = "critical evidence missing/unresolvable; needs clarification"
                downgraded += 1

        if issues:
            f["postprocess_issues"] = sorted(set(issues))

    data["postprocess"] = {
        "version": "v2-evidence-bind",
        "downgraded_tp_to_review": downgraded,
    }

    # Recompute top-level counters for consistency (LLM may have provided stale counts).
    tp = sum(1 for f in findings if f.get("verdict") == "TP")
    fp = sum(1 for f in findings if f.get("verdict") == "FP")
    rv = sum(1 for f in findings if f.get("verdict") == "REVIEW")
    data["total_findings_analyzed"] = len(findings)
    data["true_positives"] = tp
    data["false_positives"] = fp
    data["needs_review"] = rv

    # Best-effort overall_risk recompute (stable + deterministic)
    sev_order = {"informational": 0, "low": 1, "medium": 2, "high": 3, "critical": 4}
    max_tp = -1
    for f in findings:
        if f.get("verdict") != "TP":
            continue
        s = (f.get("severity") or "").strip().lower()
        max_tp = max(max_tp, sev_order.get(s, -1))
    if max_tp >= 0:
        inv = {v: k for k, v in sev_order.items()}
        data["overall_risk"] = inv.get(max_tp, "medium")
    elif rv > 0:
        data["overall_risk"] = "review"
    else:
        data["overall_risk"] = "none"

    out_path = phase2_path
    if not args.in_place:
        # Keep original as .raw if not already present, then overwrite phase2.json
        raw_path = str(layout.phase2 / f"{args.slug}-phase2.raw.json")
        if not os.path.exists(raw_path):
            try:
                os.replace(phase2_path, raw_path)
            except Exception:
                # If rename fails, fall back to copy
                with open(raw_path, "w", encoding="utf-8") as f:
                    json.dump(data, f, indent=2)
            # After moving, write normalized version to original path.
        out_path = phase2_path

    save_json(out_path, data)
    print(f"[OK] Phase2 postprocess done: {args.slug} (downgraded={downgraded})")
    print(f"  - output: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
