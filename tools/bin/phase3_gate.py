#!/usr/bin/env python3
"""Phase 3a — Deterministic Gate (final authority).

Goal
----
Convert Phase 2 findings into *stable*, *evidence-bound* outcomes.

This gate is intentionally skeptical:
- It **does not** auto-reject unclear cases.
- It tries to *make uncertainty explicit* (missing evidence / mismatched EP / unresolved paths)
  so Phase 3b (LLM skeptic) and humans can converge quickly.

Key design points (v2+)
----------------------
1) **entry_point_id exact mode**
   - If finding.entry_point_id exists in IR, all EP-scoped checks run ONLY on that EP.
   - If missing/invalid, we do a controlled fuzzy resolution and surface a suggested EP id.

2) **Path matching uses suffix, not basename**
   - basename matching produces collisions (admin.php, ajax.php, etc.).

3) **Stored/second-order flows are multi-entrypoint by nature**
   - A stored XSS/SQLi can be: EP_A (store) → EP_B (load+sink)
   - We support a deterministic 2-hop validation using IR storage read/write signals.

4) **Dynamic weights with tri-state checks**
   - If a data source is unavailable (e.g. Psalm timeout/no report), its check is excluded
     from the denominator (true N/A; no bias).

Outputs
-------
Writes: reports/phase3/<slug>-phase3.json
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

from report_paths import build_report_layout

FINAL_STATES = {"CONFIRMED", "UNCERTAIN", "RISK_NOTE", "REJECTED"}
PUBLIC_ENTRY_POINT_TYPES = {"ajax_nopriv", "admin_post_nopriv"}
STRONG_CAPABILITY_HINTS = {
    "manage_options",
    "activate_plugins",
    "install_plugins",
    "update_plugins",
    "delete_plugins",
    "edit_users",
    "list_users",
    "manage_woocommerce",
    "manage_network",
}


# -----------------------------
# Utilities
# -----------------------------


def load_json(path: str) -> Optional[dict]:
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def resolve_phase2_trust_state(doc: dict) -> Optional[str]:
    for container in (doc, doc.get("consensus"), doc.get("merge_stats")):
        if not isinstance(container, dict):
            continue
        trust_state = container.get("trust_state")
        if isinstance(trust_state, str) and trust_state.strip():
            return trust_state.strip()
    return None


def _norm_path(p: str) -> str:
    if not p:
        return ""
    p = p.replace("\\", "/")
    p = p.replace("file://", "")
    # trim leading ./
    p = re.sub(r"^\./+", "", p)
    return p


def normalize_plugin_rel_path(path: str, plugin_dir: Optional[str]) -> str:
    path = _norm_path(path)
    if not path or not plugin_dir:
        return path

    slug = os.path.basename(os.path.normpath(plugin_dir))
    plugin_dir_norm = os.path.normpath(plugin_dir).replace("\\", "/")
    if os.path.isabs(path):
        abs_norm = os.path.normpath(path).replace("\\", "/")
        prefix = plugin_dir_norm.rstrip("/") + "/"
        if abs_norm.startswith(prefix):
            return abs_norm[len(prefix):]
        marker = f"/plugins/{slug}/"
        if marker in abs_norm:
            return abs_norm.split(marker, 1)[1]
        return abs_norm

    plugin_prefix = f"plugins/{slug}/"
    if path.startswith(plugin_prefix):
        return path[len(plugin_prefix):]
    slug_prefix = f"{slug}/"
    if path.startswith(slug_prefix):
        return path[len(slug_prefix):]
    marker = f"/plugins/{slug}/"
    if marker in path:
        return path.split(marker, 1)[1]
    return path


def paths_match(a: str, b: str) -> bool:
    """Robust portable match.

    We intentionally avoid basename-only matching because WordPress has many
    repeated basenames across plugins.
    """
    a = _norm_path(a)
    b = _norm_path(b)
    if not a or not b:
        return False
    return a.endswith(b) or b.endswith(a)


def safe_int(x: Any, default: int = 0) -> int:
    try:
        return int(x)
    except Exception:
        return default


def text_from_any(x: Any) -> str:
    if x is None:
        return ""
    if isinstance(x, str):
        return x
    if isinstance(x, (dict, list)):
        try:
            return json.dumps(x, ensure_ascii=False)
        except Exception:
            return str(x)
    return str(x)


def clamp01(x: float) -> float:
    return max(0.0, min(1.0, x))


def normalize_vuln_type(v: str) -> str:
    return (v or "").strip().lower()


def normalize_final_state(value: Any) -> Optional[str]:
    if value is None:
        return None
    state = str(value).strip().upper()
    return state if state in FINAL_STATES else None


# -----------------------------
# Phase 3 Gate
# -----------------------------


@dataclass
class EPResolution:
    ep: Optional[dict]
    exact: bool
    suggested_entry_point_id: Optional[str]
    notes: str
    store_ep: Optional[dict] = None  # G-05: write-leg EP for stored/cross-EP findings


class SemanticValidator:
    """Deterministic validator for Phase 2 findings."""

    USER_SOURCE_TYPES = {
        "superglobal_get",
        "superglobal_post",
        "superglobal_request",
        "superglobal_cookie",
        "superglobal_server",
        "superglobal_files",
        "rest_param",
        "rest_params",
        "rest_json",
        "rest_body",
        "rest_body_params",
        "rest_query_params",
        "rest_url_params",
        "rest_header",
        "rest_headers",
        "rest_array_access",
        "shortcode_attr",
        "block_attr",
    }

    STORAGE_WRITE_CATEGORIES = {"option_update", "meta_update"}
    STORAGE_READ_TYPES = {"option_read", "meta_read"}

    def __init__(
        self,
        ir: dict,
        phase2: dict,
        semgrep: Optional[dict],
        plugin_dir: Optional[str],
        psalm_sarif: Optional[dict],
        ir_supplement: Optional[dict] = None,
    ):
        self.ir = ir
        self.phase2 = phase2
        self.semgrep = semgrep or {}
        self.plugin_dir = plugin_dir

        # ---- EP index (base IR + optional supplement for resolved_dynamic EPs) ----
        self.ep_by_id: Dict[str, dict] = {ep.get("id"): ep for ep in ir.get("entry_points", []) if ep.get("id")}
        # G-05: merge supplement EPs (Agent D resolved_dynamic:<hash> entries)
        if ir_supplement:
            for ep in ir_supplement.get("entry_points", []):
                ep_id = ep.get("id")
                if ep_id and ep_id not in self.ep_by_id:
                    self.ep_by_id[ep_id] = ep

        self.sources_by_ep: Dict[str, List[dict]] = {}
        self.sinks_by_ep: Dict[str, List[dict]] = {}
        self.guards_by_ep: Dict[str, List[dict]] = {}
        for src in ir.get("sources", []):
            ep = src.get("entry_point_id")
            if ep:
                self.sources_by_ep.setdefault(ep, []).append(src)
        for sink in ir.get("sinks", []):
            ep = sink.get("entry_point_id")
            if ep:
                self.sinks_by_ep.setdefault(ep, []).append(sink)
        for guard in ir.get("guards", []):
            ep = guard.get("entry_point_id")
            if ep:
                self.guards_by_ep.setdefault(ep, []).append(guard)

        # G-05 P1 post-review: also merge supplement sources/sinks/guards so that
        # _check_path_reachable() and _check_guard_consistency() can validate
        # resolved_dynamic EP findings fully, not just resolve the ID.
        # Supplement format: {entry_points:[...], sources:[...], sinks:[...], guards:[...]}
        if ir_supplement:
            for src in ir_supplement.get("sources", []):
                ep = src.get("entry_point_id")
                if ep:
                    self.sources_by_ep.setdefault(ep, []).append(src)
            for sink in ir_supplement.get("sinks", []):
                ep = sink.get("entry_point_id")
                if ep:
                    self.sinks_by_ep.setdefault(ep, []).append(sink)
            for guard in ir_supplement.get("guards", []):
                ep = guard.get("entry_point_id")
                if ep:
                    self.guards_by_ep.setdefault(ep, []).append(guard)

        # ---- IR file list ----
        self.ir_files = {_norm_path(s.get("file", "")) for s in ir.get("sources", [])}
        self.ir_files |= {_norm_path(s.get("file", "")) for s in ir.get("sinks", [])}
        self.ir_files |= {_norm_path(ep.get("file", "")) for ep in ir.get("entry_points", [])}
        # Include supplement files so _detect_hallucination() doesn't penalize Agent D findings
        if ir_supplement:
            self.ir_files |= {_norm_path(s.get("file", "")) for s in ir_supplement.get("sources", [])}
            self.ir_files |= {_norm_path(s.get("file", "")) for s in ir_supplement.get("sinks", [])}
            self.ir_files |= {_norm_path(ep.get("file", "")) for ep in ir_supplement.get("entry_points", [])}

        # ---- Semgrep ----
        self.semgrep_results = []
        try:
            self.semgrep_results = self.semgrep.get("results", []) or []
        except Exception:
            self.semgrep_results = []
        self.semgrep_available = len(self.semgrep_results) > 0

        # ---- Psalm SARIF ----
        self.psalm_sarif = psalm_sarif or {}
        self.psalm_available = False
        self.psalm_results = []
        if isinstance(self.psalm_sarif, dict) and "status" in self.psalm_sarif:
            # scan-psalm.sh writes status JSON on timeout/error/not_installed.
            self.psalm_available = False
        else:
            try:
                runs = self.psalm_sarif.get("runs", []) or []
                if runs and (runs[0].get("results") is not None):
                    self.psalm_results = runs[0].get("results", []) or []
                    self.psalm_available = True
            except Exception:
                self.psalm_available = False
                self.psalm_results = []

        # ---- Storage indexes (keyed) ----
        self.storage_writes_by_key: Dict[str, List[dict]] = {}
        self.storage_reads_by_key: Dict[str, List[dict]] = {}
        for sink in ir.get("sinks", []):
            if sink.get("category") in self.STORAGE_WRITE_CATEGORIES:
                key = sink.get("key")
                if isinstance(key, str) and key:
                    self.storage_writes_by_key.setdefault(key, []).append(sink)
        for src in ir.get("sources", []):
            if src.get("type") in self.STORAGE_READ_TYPES:
                key = src.get("key")
                if isinstance(key, str) and key:
                    self.storage_reads_by_key.setdefault(key, []).append(src)
        # Supplement storage entries (Agent D resolved EPs may have associated storage ops)
        if ir_supplement:
            for sink in ir_supplement.get("sinks", []):
                if sink.get("category") in self.STORAGE_WRITE_CATEGORIES:
                    key = sink.get("key")
                    if isinstance(key, str) and key:
                        self.storage_writes_by_key.setdefault(key, []).append(sink)
            for src in ir_supplement.get("sources", []):
                if src.get("type") in self.STORAGE_READ_TYPES:
                    key = src.get("key")
                    if isinstance(key, str) and key:
                        self.storage_reads_by_key.setdefault(key, []).append(src)

    def _read_callback_snippet(self, callback_ref: dict) -> str:
        if not callback_ref or not self.plugin_dir:
            return ""
        file_path = normalize_plugin_rel_path(callback_ref.get("file") or "", self.plugin_dir)
        if not file_path:
            return ""
        abs_path = os.path.join(self.plugin_dir, file_path)
        if not os.path.exists(abs_path):
            return ""

        start_line = safe_int(callback_ref.get("line_start") or callback_ref.get("line") or 0)
        end_line = safe_int(callback_ref.get("line_end") or start_line or 0)
        if start_line <= 0:
            return ""
        if end_line < start_line:
            end_line = start_line

        try:
            with open(abs_path, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
        except Exception:
            return ""

        start_idx = max(0, start_line - 1)
        end_idx = min(len(lines), end_line + 3)
        return "".join(lines[start_idx:end_idx])

    def _inspect_rest_permission_callback(self, ep: dict) -> Tuple[str, str]:
        permission_callback = str(ep.get("permission_callback") or "").strip()
        callback_ref = ep.get("permission_callback_ref") or {}

        if permission_callback == "__return_true":
            return "public", "__return_true permission callback"

        snippet = self._read_callback_snippet(callback_ref)
        lowered = snippet.lower()
        if "__return_true" in lowered:
            return "public", "permission callback body returns true"

        current_user_caps = re.findall(r"current_user_can\(\s*['\"]([^'\"]+)['\"]", snippet)
        if current_user_caps:
            caps = sorted(set(current_user_caps))
            if any(cap in STRONG_CAPABILITY_HINTS for cap in caps):
                return "builtin_cap", f"permission callback gates on strong capability(s): {caps}"
            return "custom_cap", f"permission callback gates on custom capability(s): {caps}"

        if permission_callback:
            return "callable_present", f"permission callback `{permission_callback}` present but strength unresolved"
        if callback_ref:
            callback_name = callback_ref.get("name") or callback_ref.get("file") or "unknown"
            return "callable_present", f"permission callback `{callback_name}` present but strength unresolved"
        return "missing", "rest route permission_callback missing or unresolved"

    def _normalize_patchstack_eligibility(self, finding: dict) -> Tuple[Optional[bool], str]:
        eligible = finding.get("patchstack_eligible")
        if eligible is None:
            return None, "patchstack eligibility not determined"
        if isinstance(eligible, bool):
            if eligible:
                return True, "patchstack eligible"
            return False, "patchstack ineligible or intentionally withheld"
        return None, "patchstack_eligible invalid; coerced to unknown"

    def _check_artifact_completeness(self, finding: dict) -> Tuple[float, List[str], str]:
        missing: List[str] = []
        if not str(finding.get("vuln_type") or "").strip():
            missing.append("missing_vuln_type")
        if not str(finding.get("sink_file_path") or finding.get("file_path") or "").strip():
            missing.append("missing_sink_file_path")
        sink_line = safe_int(finding.get("sink_line_number") or finding.get("line_number") or 0)
        if sink_line <= 0:
            missing.append("missing_sink_line_number")

        if not missing:
            return 1.0, [], "required mature fields present"
        if len(missing) == 1:
            return 0.5, missing, f"incomplete mature fields: {missing[0]}"
        return 0.0, missing, "incomplete mature fields: " + ", ".join(missing)

    def _legacy_validation_status(self, status: str, verdict: str, confidence: float) -> str:
        if status == "CONFIRMED":
            return "CONFIRMED"
        if status == "RISK_NOTE":
            return "PLAUSIBLE" if confidence >= 0.5 else "UNCERTAIN"
        if status == "UNCERTAIN":
            return "UNCERTAIN"
        if verdict == "FP":
            return "ACCEPTED_FP"
        return "LIKELY_HALLUCINATION"

    # -----------------------------
    # EP resolution
    # -----------------------------

    def _resolve_entry_point(self, finding: dict) -> EPResolution:
        ep_id = (finding.get("entry_point_id") or "").strip()

        # G-05: stored/cross-EP findings carry both store_entry_point_id (write-leg)
        # and entry_point_id (load-leg, where the sink lives).
        # Resolve BOTH legs so auth/guard checks can use each appropriately.
        store_ep_id = (finding.get("store_entry_point_id") or "").strip()
        store_ep: Optional[dict] = None
        if store_ep_id:
            store_ep = self.ep_by_id.get(store_ep_id)
            # store_ep may be None if supplement not loaded yet; gate degrades gracefully

        if ep_id and ep_id in self.ep_by_id:
            return EPResolution(
                ep=self.ep_by_id[ep_id],
                exact=True,
                suggested_entry_point_id=None,
                notes="entry_point_id exact"
                + (f"; store_entry_point_id={'resolved' if store_ep else 'unresolved'}" if store_ep_id else ""),
                store_ep=store_ep,
            )

        # Controlled fuzzy resolution: use file path + line proximity + sink match.
        f_file = normalize_plugin_rel_path(
            finding.get("sink_file_path")
            or finding.get("file_path")
            or finding.get("source_file_path")
            or "",
            self.plugin_dir,
        )
        f_line = safe_int(
            finding.get("sink_line_number")
            or finding.get("line_number")
            or finding.get("source_line_number")
            or 0
        )
        sink_fn = (finding.get("sink_function") or "").lower()
        sink_short = sink_fn.replace("$wpdb->", "").replace("()", "").strip("$")

        best: Tuple[float, Optional[dict]] = (0.0, None)
        for ep in self.ir.get("entry_points", []):
            ep_id2 = ep.get("id")
            if not ep_id2:
                continue
            ep_cb_file = _norm_path((ep.get("callback", {}) or {}).get("file", "") or ep.get("file", ""))
            if f_file and ep_cb_file and not paths_match(ep_cb_file, f_file):
                continue

            score = 0.2
            # line proximity (callback start)
            cb_line = safe_int((ep.get("callback", {}) or {}).get("line_start") or ep.get("line") or 0)
            if f_line and cb_line:
                dist = abs(f_line - cb_line)
                if dist <= 30:
                    score += 0.5
                elif dist <= 80:
                    score += 0.3
                elif dist <= 200:
                    score += 0.15

            # sink match inside EP sinks
            if sink_short:
                for s in self.sinks_by_ep.get(ep_id2, []):
                    fn = (s.get("function_called") or "").lower()
                    if sink_short == fn or sink_short in fn:
                        score += 0.35
                        break

            if score > best[0]:
                best = (score, ep)

        if best[1] is not None and best[0] >= 0.55:
            return EPResolution(
                ep=best[1],
                exact=False,
                suggested_entry_point_id=best[1].get("id"),
                notes=f"fuzzy EP resolution (score={best[0]:.2f})"
                + (f"; store_entry_point_id={'resolved' if store_ep else 'unresolved'}" if store_ep_id else ""),
                store_ep=store_ep,
            )

        return EPResolution(ep=None, exact=False, suggested_entry_point_id=None, notes="no EP resolved", store_ep=store_ep)

    # -----------------------------
    # Checks
    # -----------------------------

    def validate_finding(self, finding: dict) -> dict:
        """Return a validation record (does not mutate the finding)."""

        verdict = finding.get("verdict")
        resolution = self._resolve_entry_point(finding)
        ep = resolution.ep
        ep_id = ep.get("id") if ep else None
        review_meta = finding.get("phase3_review") if isinstance(finding.get("phase3_review"), dict) else {}
        review_final_state = normalize_final_state(review_meta.get("final_state") or review_meta.get("proposed_final_state"))
        patchstack_eligible, patchstack_notes = self._normalize_patchstack_eligibility(finding)

        check_scores: Dict[str, Optional[float]] = {}
        check_notes: Dict[str, str] = {}
        issues: List[str] = []

        # A finding with verdict=FP is not scored like a TP: it is accepted as "not a vuln".
        # G-04: validate FP evidence — populate issues[] when evidence is absent or contradicts.
        if verdict == "FP":
            fp_checks: Dict[str, Optional[float]] = {}
            fp_check_notes: Dict[str, str] = {}
            fp_issues: List[str] = []

            # Check 1: fp_reason must be present (prompt-required field)
            if not finding.get("fp_reason"):
                fp_issues.append("fp_missing_reason: FP finding has no fp_reason — evidence-free dismissal")

            # Check 2: fp_evidence.file must exist on disk (if provided)
            fp_ev = finding.get("fp_evidence") or {}
            if fp_ev.get("file"):
                fe_score, fe_notes = self._check_file_exists(
                    {"sink_file_path": fp_ev["file"], "source_file_path": fp_ev["file"]}
                )
                fp_checks["fp_evidence_file_exists"] = fe_score
                fp_check_notes["fp_evidence_file_exists"] = fe_notes
                if fe_score is not None and fe_score < 0.5:
                    fp_issues.append(f"fp_evidence_file_not_found: {fp_ev['file']}")
            else:
                fp_issues.append("fp_missing_evidence: FP finding has no fp_evidence object")

            # Check 3: run code evidence check on the finding itself (corroboration signal)
            ce_score, ce_notes = self._check_code_evidence(finding)
            fp_checks["fp_code_evidence"] = ce_score
            fp_check_notes["fp_code_evidence"] = ce_notes

            return {
                "finding_id": finding.get("finding_id"),
                "verdict": verdict,
                "validation_status": "REJECTED",
                "legacy_validation_status": "ACCEPTED_FP",
                "confidence_score": 1.0,
                "resolved_entry_point_id": ep_id,
                "entry_point_exact": resolution.exact,
                "suggested_entry_point_id": resolution.suggested_entry_point_id,
                "entry_point_resolution_notes": resolution.notes,
                "checks": fp_checks,
                "check_scores": fp_checks,
                "check_notes": fp_check_notes,
                "issues": fp_issues,
                "patchstack_eligible": patchstack_eligible,
                "reportability_notes": {"patchstack_eligible": patchstack_notes},
                "review_final_state": review_final_state,
                "reopening_condition": review_meta.get("reopening_condition"),
            }

        # --- compute checks ---
        file_exists_score, file_notes = self._check_file_exists(finding)
        check_scores["file_exists"] = file_exists_score
        check_notes["file_exists"] = file_notes
        if file_exists_score is not None and file_exists_score < 0.5:
            issues.append("file_not_found_or_unresolvable")

        path_score, path_notes = self._check_path_reachable(finding, resolution)
        check_scores["path_reachable"] = path_score
        check_notes["path_reachable"] = path_notes
        if path_score is not None and path_score < 0.5:
            issues.append("path_reachability_weak")

        auth_score, auth_notes = self._check_auth_consistency(finding, resolution)
        check_scores["auth_consistent"] = auth_score
        check_notes["auth_consistent"] = auth_notes

        guard_score, guard_notes = self._check_guard_consistency(finding, resolution)
        check_scores["guard_consistent"] = guard_score
        check_notes["guard_consistent"] = guard_notes
        if guard_score is not None and guard_score < 0.5:
            issues.append("guard_contradiction")

        sanitizer_score, sanitizer_notes = self._check_sanitizer_claim(finding)
        check_scores["sanitizer_claim"] = sanitizer_score
        check_notes["sanitizer_claim"] = sanitizer_notes

        semgrep_score, semgrep_notes = self._check_semgrep_corroboration(finding, resolution)
        check_scores["semgrep_corroborates"] = semgrep_score
        check_notes["semgrep_corroborates"] = semgrep_notes

        psalm_score, psalm_notes = self._check_psalm_corroboration(finding)
        check_scores["psalm_corroborates"] = psalm_score
        check_notes["psalm_corroborates"] = psalm_notes

        evidence_score, evidence_notes = self._check_code_evidence(finding)
        check_scores["code_evidence"] = evidence_score
        check_notes["code_evidence"] = evidence_notes
        if evidence_score is not None and evidence_score < 0.5:
            issues.append("code_evidence_missing_or_mismatch")

        reasoning_score = self._assess_reasoning_quality(finding)
        check_scores["reasoning_quality"] = reasoning_score
        check_notes["reasoning_quality"] = "evidence-binding + refute-first heuristics"
        if reasoning_score < 0.45:
            issues.append("reasoning_quality_low")

        cvss_score, cvss_notes = self._check_cvss_plausibility(finding)
        check_scores["cvss_plausible"] = cvss_score
        check_notes["cvss_plausible"] = cvss_notes

        halluc_score, halluc_notes = self._detect_hallucination(finding, file_exists_score)
        check_scores["no_hallucination"] = halluc_score
        check_notes["no_hallucination"] = halluc_notes
        if halluc_score < 0.5:
            issues.append("hallucination_signals")

        completeness_score, completeness_issues, completeness_notes = self._check_artifact_completeness(finding)
        check_scores["artifact_completeness"] = completeness_score
        check_notes["artifact_completeness"] = completeness_notes
        issues.extend(completeness_issues)

        # --- confidence scoring (dynamic weights; N/A checks excluded) ---
        confidence, used = self._compute_confidence(check_scores)
        check_notes["_confidence"] = f"weighted checks used: {', '.join(used)}"

        # --- status classification ---
        strong_path = (
            path_score is None
            or path_score >= 0.8
            or (
                resolution.exact
                and path_score >= 0.55
                and (evidence_score is None or evidence_score >= 0.9)
                and (auth_score is None or auth_score >= 0.9)
            )
        )
        # Hard constraint: cannot be CONFIRMED without strong evidence binding.
        can_confirm = (
            (file_exists_score is None or file_exists_score >= 0.9)
            and (evidence_score is None or evidence_score >= 0.9)
            and strong_path
            and (auth_score is None or auth_score >= 0.85)
            and completeness_score >= 1.0
            and halluc_score >= 0.8
        )

        deterministic_refutation = (
            (file_exists_score is not None and file_exists_score < 0.5)
            or (evidence_score is not None and evidence_score < 0.5)
            or halluc_score < 0.35
        )

        if confidence >= 0.75 and can_confirm:
            status = "CONFIRMED"
        elif confidence >= 0.30:
            status = "UNCERTAIN"
        else:
            status = "REJECTED" if deterministic_refutation else "UNCERTAIN"

        # If evidence binding is weak, cap at UNCERTAIN (avoid false CONFIRMED).
        if status == "CONFIRMED" and not can_confirm:
            status = "UNCERTAIN"
            issues.append("insufficient_evidence_to_confirm")

        if verdict == "REVIEW" and status == "CONFIRMED":
            status = "UNCERTAIN"
            issues.append("phase2_review_not_resolved")

        if (
            status == "UNCERTAIN"
            and deterministic_refutation
            and completeness_score < 1.0
            and path_score is not None
            and path_score < 0.5
        ):
            status = "REJECTED"
            issues.append("deterministic_refutation")

        if review_final_state == "REJECTED":
            status = "REJECTED"
        elif review_final_state == "RISK_NOTE":
            status = "RISK_NOTE"
        elif review_final_state == "UNCERTAIN" and status == "CONFIRMED":
            status = "UNCERTAIN"

        legacy_status = self._legacy_validation_status(status, str(verdict or ""), confidence)

        return {
            "finding_id": finding.get("finding_id"),
            "verdict": verdict,
            "validation_status": status,
            "legacy_validation_status": legacy_status,
            "confidence_score": round(confidence, 4),
            "resolved_entry_point_id": ep_id,
            "entry_point_exact": resolution.exact,
            "suggested_entry_point_id": resolution.suggested_entry_point_id,
            "entry_point_resolution_notes": resolution.notes,
            "checks": {k: (v is not None and v >= 0.5) for k, v in check_scores.items()},
            "check_scores": check_scores,
            "check_notes": check_notes,
            "issues": sorted(set(issues)),
            "patchstack_eligible": patchstack_eligible,
            "reportability_notes": {"patchstack_eligible": patchstack_notes},
            "review_final_state": review_final_state,
            "reopening_condition": review_meta.get("reopening_condition"),
            # Propagate key Phase 2 fields so downstream consumers (benchmark, MD writer)
            # have direct access without re-loading phase2.json.
            "sink_file_path": finding.get("sink_file_path") or finding.get("file_path"),
            "sink_line_number": finding.get("sink_line_number") or finding.get("line_number"),
            "sink_function": finding.get("sink_function"),
            "source_file_path": finding.get("source_file_path"),
            "source_line_number": finding.get("source_line_number"),
            "vuln_type": finding.get("vuln_type"),
        }

    def _compute_confidence(self, check_scores: Dict[str, Optional[float]]) -> Tuple[float, List[str]]:
        """Compute confidence score with dynamic weights.

        - If a check returns None, it's treated as N/A and removed from denominator.
        - For available checks, score is in [0,1].
        """

        weights: Dict[str, float] = {
            "file_exists": 0.06,
            "path_reachable": 0.20,
            "auth_consistent": 0.10,
            "guard_consistent": 0.12,
            "sanitizer_claim": 0.05,
            "semgrep_corroborates": 0.05,
            "psalm_corroborates": 0.05,
            "code_evidence": 0.18,
            "reasoning_quality": 0.10,
            "cvss_plausible": 0.04,
            "no_hallucination": 0.12,
            "artifact_completeness": 0.07,
        }

        num = 0.0
        den = 0.0
        used = []
        for name, w in weights.items():
            s = check_scores.get(name)
            if s is None:
                continue
            s = clamp01(float(s))
            num += s * w
            den += w
            used.append(name)
        if den <= 0.0:
            return 0.0, used
        return clamp01(num / den), used

    # -----------------------------
    # Individual check implementations
    # -----------------------------

    def _check_file_exists(self, finding: dict) -> Tuple[Optional[float], str]:
        if not self.plugin_dir:
            return None, "plugin_dir unavailable (N/A)"

        candidates = [
            finding.get("sink_file_path"),
            finding.get("file_path"),
            finding.get("source_file_path"),
        ]
        candidates = [_norm_path(c or "") for c in candidates if c]
        candidates = [c for c in candidates if c]
        if not candidates:
            return 0.0, "missing file_path/sink_file_path/source_file_path"

        for rel in candidates:
            abs_path = os.path.join(self.plugin_dir, rel)
            if os.path.exists(abs_path):
                return 1.0, f"exists: {rel}"

        # basename fallback (best-effort): pick unique match.
        basename = os.path.basename(candidates[0])
        hits = []
        for root, _, files in os.walk(self.plugin_dir):
            for fn in files:
                if fn == basename:
                    hits.append(os.path.join(root, fn))
                    if len(hits) > 3:
                        break
            if len(hits) > 3:
                break

        if len(hits) == 1:
            rel_hit = os.path.relpath(hits[0], self.plugin_dir)
            return 0.7, f"basename resolved uniquely → {rel_hit}"
        if len(hits) > 1:
            return 0.3, f"basename collision for {basename} (matches={len(hits)})"
        return 0.0, "file not found in plugin_dir"

    def _extract_storage_key(self, finding: dict) -> Optional[str]:
        # Preferred: explicit field in Phase 2 output
        key = finding.get("storage_key")
        if isinstance(key, str) and key.strip():
            return key.strip()

        # Best-effort extraction from reasoning (only for literal keys)
        reasoning = text_from_any(finding.get("reasoning"))
        m = re.search(r"(?:update_option|get_option)\(\s*['\"]([^'\"]+)['\"]", reasoning)
        if m:
            return m.group(1)
        m = re.search(r"(?:update_(?:post|user|term|comment)_meta|get_(?:post|user|term|comment)_meta)\(\s*[^,]+,\s*['\"]([^'\"]+)['\"]", reasoning)
        if m:
            return m.group(1)
        return None

    def _check_stored_2hop(self, key: Optional[str]) -> Tuple[float, str]:
        """Deterministically validate stored/second-order flow using IR.

        We accept that the 2-hop might not be fully resolvable (dynamic keys,
        conditional reads, etc.). In that case we return a partial score.
        """
        if not key:
            # Without a key we can only treat stored as a weak signal.
            return 0.45, "stored-mode: missing storage_key (needs explicit key or evidence)"

        writes = self.storage_writes_by_key.get(key, [])
        reads = self.storage_reads_by_key.get(key, [])
        if not writes and not reads:
            return 0.35, f"stored-mode: no storage read/write for key='{key}' in IR (might be dynamic key)"

        # Condition A: user source + storage write in some EP
        store_ok = False
        store_eps = set()
        for w in writes:
            ep = w.get("entry_point_id")
            if ep:
                store_eps.add(ep)
                if any(s.get("entry_point_id") == ep and s.get("type") in self.USER_SOURCE_TYPES for s in self.ir.get("sources", [])):
                    store_ok = True

        # Condition B: storage read + dangerous sink in some EP
        load_ok = False
        load_eps = set()
        for r in reads:
            ep = r.get("entry_point_id")
            if ep:
                load_eps.add(ep)
                sinks = self.sinks_by_ep.get(ep, [])
                if any(s.get("category") in {"output", "output_return", "sql"} for s in sinks):
                    load_ok = True

        if store_ok and load_ok:
            return 1.0, f"stored-mode: 2-hop validated for key='{key}' (store_eps={len(store_eps)}, load_eps={len(load_eps)})"
        if store_ok or load_ok:
            return 0.65, f"stored-mode: partial 2-hop for key='{key}' (store_ok={store_ok}, load_ok={load_ok})"
        return 0.4, f"stored-mode: weak 2-hop for key='{key}' (write/read present but missing sources/sinks correlation)"

    def _check_path_reachable(self, finding: dict, resolution: EPResolution) -> Tuple[Optional[float], str]:
        if finding.get("verdict") == "FP":
            return 1.0, "FP findings not evaluated for reachability"

        vuln = normalize_vuln_type(finding.get("vuln_type", ""))
        if "stored" in vuln or "second" in vuln:
            key = self._extract_storage_key(finding)
            score, note = self._check_stored_2hop(key)
            return score, note

        # Non-stored: prefer EP exact.
        ep = resolution.ep
        if ep is None:
            return 0.45, "no entry point resolved (missing/invalid entry_point_id + fuzzy resolution failed)"

        ep_id = ep.get("id")
        if not ep_id:
            return 0.45, "resolved EP missing id (unexpected)"

        sources = self.sources_by_ep.get(ep_id, [])
        sinks = self.sinks_by_ep.get(ep_id, [])

        # Sink match
        sink_fn = (finding.get("sink_function") or "").lower()
        sink_short = sink_fn.replace("$wpdb->", "").replace("()", "").strip("$")
        sink_ok = False
        if sink_short:
            for s in sinks:
                fn = (s.get("function_called") or "").lower()
                if sink_short == fn or sink_short in fn:
                    sink_ok = True
                    break
        else:
            # If no sink function given, try line match
            sink_ok = True

        # Source match (weak: Phase 2 often expresses sources as variables)
        source_claim = (finding.get("source_function") or "").lower()
        source_ok = False
        if source_claim:
            for src in sources:
                v = (src.get("variable") or "").lower()
                t = (src.get("type") or "").lower()
                if source_claim in v or source_claim in t:
                    source_ok = True
                    break
            # DI-28-01: source normalization for REST EP callbacks.
            # Agents often name the callback method itself (e.g., "start_backup",
            # "cloud_save_and_test") as source_function rather than a variable or
            # type name.  The name-match above fails because these are not variable
            # names in the IR.  If the claim looks like a bare method name (no "$"
            # prefix, no "::" class separator) and the EP already has confirmed
            # user-input sources (rest_params, superglobal_*, etc.), accept it.
            if not source_ok and "$" not in source_claim and "::" not in source_claim:
                source_ok = any(src.get("type") in self.USER_SOURCE_TYPES for src in sources)
        else:
            # If no explicit source claimed, but EP has user sources, give partial credit.
            source_ok = any(src.get("type") in self.USER_SOURCE_TYPES for src in sources)

        if sink_ok and source_ok:
            return 1.0, f"EP-scoped path plausible in {ep_id} ({'exact' if resolution.exact else 'fuzzy'})"
        if sink_ok and not source_ok:
            return 0.7, f"sink matched in EP {ep_id}, but source evidence weak/missing"
        if source_ok and not sink_ok:
            return 0.55, f"source matched in EP {ep_id}, but sink evidence weak/missing"
        return 0.25, f"neither source nor sink matched in EP {ep_id}"

    def _check_auth_consistency(self, finding: dict, resolution: EPResolution) -> Tuple[Optional[float], str]:
        # G-05: for stored/cross-EP findings, exploitability depends on write-leg auth.
        # An unauthenticated store EP (ajax_nopriv) is far more severe than an admin-only one.
        # Use store_ep (write-leg) when available; fall back to load-leg EP otherwise.
        if resolution.store_ep is not None:
            ep = resolution.store_ep
            ep_source = "store_ep (write-leg)"
        else:
            ep = resolution.ep
            ep_source = "ep (load-leg)"

        if ep is None:
            return 0.6, "EP unresolved → cannot disprove auth claim"

        claimed = (finding.get("auth_required") or "").strip().lower()
        ep_type = (ep.get("type") or "").strip()

        auth_map = {
            "ajax_nopriv": "none",
            "admin_post_nopriv": "none",
            "ajax_priv": "subscriber",
            "admin_post": "subscriber",
            "admin_init": "subscriber",
            "shortcode": "contributor",
            "block": "contributor",
            "cron": "system",
            "rest_route": None,  # depends on permission_callback
        }

        expected = auth_map.get(ep_type)
        if expected is None:
            callback_kind, callback_note = self._inspect_rest_permission_callback(ep)
            if callback_kind == "public":
                if claimed in ("none", ""):
                    return 1.0, f"{ep_source}: public REST route ({callback_note})"
                return 0.25, f"{ep_source}: REST route is public but finding claims auth `{claimed}`"
            if callback_kind == "builtin_cap":
                if claimed == "none":
                    return 0.25, f"{ep_source}: REST route is guarded by capability, not public ({callback_note})"
                return 0.9, f"{ep_source}: {callback_note}"
            if callback_kind == "custom_cap":
                if claimed == "none":
                    return 0.25, f"{ep_source}: custom capability guard contradicts unauth claim ({callback_note})"
                return 0.45, f"{ep_source}: {callback_note}; trust boundary unresolved"
            if callback_kind == "callable_present":
                return 0.55, f"{ep_source}: {callback_note}"
            return 0.35, f"{ep_source}: {callback_note}"

        if claimed == expected:
            return 1.0, f"auth matches {ep_source} type ({ep_type} → {expected})"

        # Conservative claims are okay: claiming more auth required than expected.
        order = ["none", "subscriber", "contributor", "author", "editor", "admin", "system"]
        try:
            if claimed in order and expected in order and order.index(claimed) > order.index(expected):
                return 0.9, f"conservative auth claim ({claimed} > {expected}) [{ep_source}]"
        except Exception:
            pass

        return 0.25, f"auth mismatch [{ep_source}]: EP type={ep_type} expects {expected}, finding claims {claimed}"

    def _check_guard_consistency(self, finding: dict, resolution: EPResolution) -> Tuple[Optional[float], str]:
        """If finding claims missing guards, but IR sees effective guard, that's a contradiction.

        G-05: For stored/cross-EP findings, check guards on BOTH legs:
        - Store-leg (write): checks nonce_check and capability_check guards in IR
        - Load-leg (read+sink): checks nonce_check and capability_check guards in IR

        NOTE: "load-leg needs output escaping" (gap-analysis-final.md:1126) refers to output
        sanitization at the render point, NOT to nonce/cap guard types. The Phase 1 extractor
        does not currently emit an 'output_escaping' guard type — proper load-leg escaping
        validation requires a Phase 1 extractor change (tracked as DI-19-02). Until then,
        load-leg is checked for nonce/cap only (same as store-leg). Output escaping is partially
        reflected in the separate _check_sanitizer_claim() check via finding.sanitizer_correct.
        The most permissive leg determines the overall guard score.
        """
        ep = resolution.ep
        if ep is None:
            return 0.6, "EP unresolved → cannot validate guards precisely"

        ep_id = ep.get("id")
        if not ep_id:
            return 0.6, "EP has no id"

        reasoning = text_from_any(finding.get("reasoning")).lower()
        claims_no_nonce = ("no nonce" in reasoning) or ("missing nonce" in reasoning)
        claims_no_cap = ("no capability" in reasoning) or ("missing capability" in reasoning)

        # G-01: Three-state guard classification — is True / is None / is False (E4)
        # NEVER use truthy check: None and False are both falsy but have different semantics.
        def _classify(guard_list):
            effective = [g for g in guard_list if g.get("is_effective") is True]
            unknown   = [g for g in guard_list if g.get("is_effective") is None]
            broken    = [g for g in guard_list if g.get("is_effective") is False]
            return effective, unknown, broken

        def _score_guard_leg(leg_ep_id: str, leg_label: str) -> Tuple[float, str]:
            """Score guard coverage for one EP leg."""
            guards = self.guards_by_ep.get(leg_ep_id, [])
            leg_ep = self.ep_by_id.get(leg_ep_id) or {}
            leg_type = str(leg_ep.get("type") or "").strip()
            nonce_guards = [g for g in guards if g.get("type") == "nonce_check"]
            cap_guards   = [g for g in guards if g.get("type") == "capability_check"]

            nonce_eff, nonce_unk, nonce_brk = _classify(nonce_guards)
            cap_eff,   cap_unk,   cap_brk   = _classify(cap_guards)

            has_effective_nonce = bool(nonce_eff)
            has_effective_cap   = bool(cap_eff)

            if claims_no_nonce and has_effective_nonce:
                return 0.0, f"contradiction [{leg_label}]: finding claims no nonce, IR has effective nonce guard"
            if claims_no_cap and has_effective_cap:
                return 0.0, f"contradiction [{leg_label}]: finding claims no capability, IR has effective cap guard"

            if (not claims_no_nonce and not claims_no_cap) and (has_effective_nonce or has_effective_cap):
                if leg_type in PUBLIC_ENTRY_POINT_TYPES and has_effective_nonce and not has_effective_cap:
                    return 0.75, f"[{leg_label}] public endpoint has nonce-only guard; treat as CSRF signal, not authz barrier"
                return 0.9, f"[{leg_label}] IR indicates guards present; finding does not claim missing guards"

            all_effective = nonce_eff + cap_eff
            all_unknown   = nonce_unk + cap_unk
            all_broken    = nonce_brk + cap_brk

            if all_effective:
                return 0.9, f"[{leg_label}] confirmed effective guard"
            if all_unknown:
                funcs = [g.get("function_called", "?") for g in all_unknown]
                return 0.6, f"[{leg_label}] potential custom guard (is_effective=null): {funcs}"
            if all_broken:
                return 0.2, f"[{leg_label}] guard detected but confirmed ineffective"
            return 0.1, f"[{leg_label}] no guard detected"

        # G-05: if store_ep resolved, check BOTH legs; take the minimum score
        # (a finding is only as safe as its weakest leg)
        if resolution.store_ep is not None:
            store_ep_id = resolution.store_ep.get("id")
            if store_ep_id:
                store_score, store_note = _score_guard_leg(store_ep_id, "store-leg")
                load_score,  load_note  = _score_guard_leg(ep_id, "load-leg")
                # Contradiction on either leg is a hard failure
                if store_score == 0.0:
                    return 0.0, store_note
                if load_score == 0.0:
                    return 0.0, load_note
                # Otherwise take minimum (worst-case leg determines overall guard score)
                if store_score <= load_score:
                    return store_score, f"stored/cross-EP — weakest leg: {store_note} | {load_note}"
                return load_score, f"stored/cross-EP — weakest leg: {load_note} | {store_note}"

        # Single-EP (non-stored) path — original logic
        guards = self.guards_by_ep.get(ep_id, [])
        nonce_guards = [g for g in guards if g.get("type") == "nonce_check"]
        cap_guards   = [g for g in guards if g.get("type") == "capability_check"]

        nonce_eff, nonce_unk, nonce_brk = _classify(nonce_guards)
        cap_eff,   cap_unk,   cap_brk   = _classify(cap_guards)

        has_effective_nonce = bool(nonce_eff)
        has_effective_cap   = bool(cap_eff)

        if claims_no_nonce and has_effective_nonce:
            return 0.0, "contradiction: finding claims no nonce, IR has effective nonce guard"
        if claims_no_cap and has_effective_cap:
            return 0.0, "contradiction: finding claims no capability, IR has effective capability guard"

        if (not claims_no_nonce and not claims_no_cap) and (has_effective_nonce or has_effective_cap):
            ep_type = str(ep.get("type") or "").strip()
            if ep_type in PUBLIC_ENTRY_POINT_TYPES and has_effective_nonce and not has_effective_cap:
                return 0.75, "public endpoint has nonce-only guard; treat as CSRF signal, not authz barrier"
            return 0.9, "IR indicates guards present; finding does not claim missing guards"

        all_effective = nonce_eff + cap_eff
        all_unknown   = nonce_unk + cap_unk
        all_broken    = nonce_brk + cap_brk

        if all_effective:
            return 0.9, "confirmed effective guard"
        if all_unknown:
            funcs = [g.get("function_called", "?") for g in all_unknown]
            return 0.6, f"potential custom guard detected (is_effective=null): {funcs}"
        if all_broken:
            return 0.2, "guard detected but confirmed ineffective"
        return 0.1, "no guard detected"

    def _check_sanitizer_claim(self, finding: dict) -> Tuple[Optional[float], str]:
        """Sanitizer correctness is hard to prove deterministically.

        This check only penalizes obvious self-contradictions.
        """
        sanitizer_present = finding.get("sanitizer_present")
        sanitizer_correct = finding.get("sanitizer_correct")
        if sanitizer_present is False and sanitizer_correct is True:
            return 0.3, "self-contradiction: sanitizer_present=false but sanitizer_correct=true"
        return 0.8, "sanitizer claim not contradicted"

    def _check_semgrep_corroboration(self, finding: dict, resolution: EPResolution) -> Tuple[Optional[float], str]:
        if not self.semgrep_available:
            return None, "Semgrep results not available (N/A)"

        fpath = _norm_path(
            finding.get("sink_file_path")
            or finding.get("file_path")
            or ""
        )
        line = safe_int(finding.get("sink_line_number") or finding.get("line_number") or 0)

        if not fpath:
            return 0.5, "Semgrep available but finding missing file path"

        for sr in self.semgrep_results:
            sr_file = _norm_path(sr.get("path") or "")
            sr_line = safe_int(((sr.get("start") or {})).get("line") or 0)
            if not sr_file:
                continue
            if not paths_match(sr_file, fpath):
                continue
            if line and sr_line and abs(sr_line - line) <= 20:
                return 1.0, "Semgrep corroborates (same file suffix, ±20 lines)"

        # Absence is neutral-ish (Semgrep coverage not complete)
        return 0.5, "Semgrep has data, but no corroborating hit near claimed location"

    def _check_psalm_corroboration(self, finding: dict) -> Tuple[Optional[float], str]:
        if not self.psalm_available:
            return None, "Psalm SARIF not available/valid (N/A)"

        fpath = _norm_path(
            finding.get("sink_file_path")
            or finding.get("file_path")
            or ""
        )
        line = safe_int(finding.get("sink_line_number") or finding.get("line_number") or 0)
        vuln = normalize_vuln_type(finding.get("vuln_type"))

        # Map vuln_type → expected Psalm taint categories
        psalm_category_map = {
            "sqli": ["taintedsql", "sql", "sqli"],
            "xss_stored": ["taintedhtml", "taintedtextwithoutescape", "html", "xss"],
            "xss_reflected": ["taintedhtml", "taintedtextwithoutescape", "html", "xss"],
            "ssrf": ["taintedssrf", "ssrf"],
            "lfi": ["taintedinclude", "include", "lfi"],
            "path_traversal": ["taintedfile", "file"],
            "rce": ["taintedeval", "eval", "taintedshell", "shell"],
            "file_upload": ["taintedfile", "file"],
            "object_injection": ["taintedunserialize", "unserialize"],
            "open_redirect": ["taintedheader", "header", "redirect"],
        }
        expected_patterns = psalm_category_map.get(vuln, [])
        if not expected_patterns:
            expected_patterns = [vuln]

        for result in self.psalm_results:
            rule_id = (result.get("ruleId") or "").lower()
            message = (result.get("message", {}) or {}).get("text") or ""
            message = message.lower()

            if not any(p in rule_id or p in message for p in expected_patterns):
                continue

            for loc in result.get("locations", []) or []:
                phys = (loc.get("physicalLocation") or {})
                uri = _norm_path(((phys.get("artifactLocation") or {}).get("uri") or ""))
                ps_line = safe_int(((phys.get("region") or {}).get("startLine") or 0))

                if fpath and uri and not paths_match(uri, fpath):
                    continue

                # If line is present, use proximity. If not, same file match is still useful.
                if line and ps_line and abs(ps_line - line) <= 30:
                    return 1.0, "Psalm corroborates (category + file suffix + ±30 lines)"
                if fpath and not line and uri:
                    return 0.8, "Psalm corroborates (category + file suffix; no line info)"

        # Absence is neutral (Psalm has FP/coverage limitations)
        return 0.5, "Psalm has data, but no corroboration match for this finding"

    def _find_file_in_plugin(self, rel_path: str) -> Optional[str]:
        if not self.plugin_dir:
            return None
        rel_path = normalize_plugin_rel_path(rel_path, self.plugin_dir)
        if not rel_path:
            return None

        if os.path.isabs(rel_path):
            if os.path.exists(rel_path):
                return rel_path
        else:
            abs_path = os.path.join(self.plugin_dir, rel_path)
            if os.path.exists(abs_path):
                return abs_path

        basename = os.path.basename(rel_path)
        candidates = []
        for root, _, files in os.walk(self.plugin_dir):
            for fn in files:
                if fn == basename:
                    candidates.append(os.path.join(root, fn))
                    if len(candidates) > 2:
                        break
            if len(candidates) > 2:
                break
        if len(candidates) == 1:
            return candidates[0]
        return None

    def _check_code_evidence(self, finding: dict) -> Tuple[Optional[float], str]:
        """Verify that claimed sink/source appear near claimed lines.

        This is intentionally *cheap* and *deterministic*.
        """
        if not self.plugin_dir:
            return None, "plugin_dir unavailable (N/A)"

        sink_path = normalize_plugin_rel_path(finding.get("sink_file_path") or finding.get("file_path") or "", self.plugin_dir)
        sink_line = safe_int(finding.get("sink_line_number") or finding.get("line_number") or 0)
        source_path = normalize_plugin_rel_path(finding.get("source_file_path") or "", self.plugin_dir)
        source_line = safe_int(finding.get("source_line_number") or 0)

        # At minimum, we need a sink location.
        if not sink_path or not sink_line:
            return 0.0, "missing sink_file_path/file_path or sink_line_number/line_number"

        sink_abs = self._find_file_in_plugin(sink_path)
        if not sink_abs:
            return 0.0, f"cannot resolve sink file in plugin: {sink_path}"

        try:
            with open(sink_abs, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except Exception:
            return 0.0, "failed to read sink file"

        def context_at(ln: int, window: int = 6) -> str:
            start = max(0, ln - window - 1)
            end = min(len(lines), ln + window)
            return "".join(lines[start:end]).lower()

        sink_ctx = context_at(sink_line)
        sink_fn = (finding.get("sink_function") or "").lower().strip()
        sink_short = sink_fn.replace("$wpdb->", "").replace("()", "").strip("$")
        if sink_short and sink_short not in sink_ctx:
            # DI-29-01: also try the method-name part alone (handles instance dispatch:
            # agent says "AdapterClass::method" but code says "$this->adapter->method()").
            method_name_only = sink_short.split("::")[-1] if "::" in sink_short else ""
            if not method_name_only or method_name_only not in sink_ctx:
                # Sometimes sinks are language constructs (echo/include/require)
                constructs = {"echo", "include", "require", "include_once", "require_once", "print"}
                if sink_short not in constructs:
                    return 0.25, f"sink function '{sink_short}' not found near line {sink_line}"

        # Optional: source location check
        if source_path and source_line:
            src_abs = self._find_file_in_plugin(source_path)
            if src_abs:
                try:
                    with open(src_abs, "r", encoding="utf-8", errors="replace") as f:
                        src_lines = f.readlines()
                    start = max(0, source_line - 6)
                    end = min(len(src_lines), source_line + 5)
                    src_ctx = "".join(src_lines[start:end]).lower()
                    src_claim = (finding.get("source_function") or "").lower().strip()
                    src_short = src_claim.strip("$")
                    if src_short and src_short not in src_ctx:
                        return 0.7, "sink evidence ok; source location provided but source token not found (verify)"
                except Exception:
                    return 0.7, "sink evidence ok; source file not readable"

        return 1.0, "sink evidence validated (and source evidence checked when available)"

    def _assess_reasoning_quality(self, finding: dict) -> float:
        """Score reasoning quality 0.0–1.0 with strict evidence binding."""
        reasoning = text_from_any(finding.get("reasoning"))
        rlow = reasoning.lower()
        score = 0.0

        # Minimum length (avoid template fluff)
        if len(reasoning) >= 150:
            score += 0.2
        elif len(reasoning) >= 110:
            score += 0.12

        # G-02: Cross-reference file:line against finding's claimed locations
        # Source_ref: gap-analysis-final.md:1021-1086
        # Replace keyword bonus (+0.10 for "however"/"but") — gameable.
        # Replace simple file:line presence check (+0.25/-0.15) with location matching.
        refs = re.findall(r"([\w/.-]+\.php)[:\s]+(?:line\s*)?(\d+)", reasoning)
        if refs:
            verdict = finding.get("verdict", "")
            if verdict == "FP":
                # FP findings: cross-reference against fp_evidence location (not sink)
                fp_ev = finding.get("fp_evidence") or {}
                check_file = _norm_path(fp_ev.get("file", ""))
                check_line = safe_int(fp_ev.get("line", 0))
                if not check_file:
                    pass  # FP without fp_evidence → skip cross-ref, no bonus no penalty
                else:
                    matched = any(
                        paths_match(_norm_path(rf), check_file) and abs(int(rl) - check_line) <= 10
                        for rf, rl in refs
                    )
                    score += 0.25 if matched else -0.10
            else:
                # TP/REVIEW: cross-reference against sink AND source locations
                sink_file   = _norm_path(finding.get("sink_file_path", ""))
                sink_line   = safe_int(finding.get("sink_line_number", 0))
                source_file = _norm_path(finding.get("source_file_path", ""))
                source_line = safe_int(finding.get("source_line_number", 0))

                matched = False
                for ref_file, ref_line_str in refs:
                    ref_file_norm = _norm_path(ref_file)
                    ref_line = int(ref_line_str)
                    if paths_match(ref_file_norm, sink_file) and abs(ref_line - sink_line) <= 10:
                        matched = True
                        break
                    if source_file and paths_match(ref_file_norm, source_file) and abs(ref_line - source_line) <= 10:
                        matched = True
                        break

                score += 0.25 if matched else -0.10
        else:
            # No file:line references at all
            score -= 0.15

        # entry_point_id binding (exact)
        ep_id = (finding.get("entry_point_id") or "").strip()
        if ep_id and ep_id in self.ep_by_id:
            score += 0.18
        elif ep_id:
            score += 0.06
        else:
            score -= 0.06

        # Contains source→sink trace language
        if any(w in rlow for w in ["source", "sink", "flow", "trace", "taint", "propagate"]):
            score += 0.12

        # Contains defense/guard analysis
        if any(w in rlow for w in ["nonce", "capability", "current_user_can", "permission_callback", "sanitize", "escape", "prepare"]):
            score += 0.12

        # G-02: "however"/"but" keyword bonus removed — gameable (source_ref: gap-analysis-final.md:1007-1025)

        # Penalize short generic templates
        generic = ["attacker could", "this is vulnerable because", "no sanitization is applied", "attacker can exploit"]
        if any(g in rlow for g in generic) and len(reasoning) < 140:
            score -= 0.25

        return clamp01(score)

    def _check_cvss_plausibility(self, finding: dict) -> Tuple[Optional[float], str]:
        cvss = finding.get("cvss_vector")
        if cvss is None:
            return 0.8, "cvss_vector omitted (allowed)"
        if not isinstance(cvss, str) or not cvss.startswith("CVSS:3.1/"):
            return 0.2, "invalid CVSS:3.1 vector"

        auth = (finding.get("auth_required") or "").strip().lower()
        # Quick plausibility checks
        if "PR:N" in cvss and auth not in ("none", ""):
            return 0.2, "cvss PR:N but auth_required != none"
        if "PR:L" in cvss and auth == "none":
            return 0.2, "cvss PR:L but auth_required=none"
        return 1.0, "cvss vector plausible"

    def _check_patchstack_eligibility(self, finding: dict) -> Tuple[Optional[float], str]:
        eligible = finding.get("patchstack_eligible")
        if eligible is None:
            return 0.8, "patchstack_eligible not provided (allowed)"
        if not isinstance(eligible, bool):
            return 0.3, "patchstack_eligible must be boolean"

        auth = (finding.get("auth_required") or "").strip().lower()
        severity = (finding.get("severity") or "").strip().lower()
        if eligible and auth == "admin":
            return 0.2, "admin-only marked eligible (likely wrong)"
        if eligible and severity == "informational":
            return 0.2, "informational marked eligible (likely wrong)"
        return 1.0, "patchstack_eligible plausibility ok"

    def _detect_hallucination(self, finding: dict, file_exists_score: Optional[float]) -> Tuple[float, str]:
        """Return score (1=no hallucination) and notes."""
        signals = 0
        notes = []

        # Signal 1: file not present (strong)
        if file_exists_score is not None and file_exists_score < 0.5:
            signals += 1
            notes.append("file_not_found")

        # Signal 2: file not referenced in IR at all
        fpath = normalize_plugin_rel_path(finding.get("sink_file_path") or finding.get("file_path") or "", self.plugin_dir)
        if fpath:
            in_ir = any(paths_match(fpath, irp) for irp in self.ir_files if irp)
            if not in_ir:
                signals += 1
                notes.append("file_not_in_ir")

        # Signal 3: CWE mismatch
        cwe_vuln_map = {
            "sqli": {"CWE-89"},
            "xss_stored": {"CWE-79"},
            "xss_reflected": {"CWE-79"},
            "csrf": {"CWE-352"},
            "bac": {"CWE-862", "CWE-863"},
            "lfi": {"CWE-98", "CWE-22"},
            "rce": {"CWE-94", "CWE-95"},
            "object_injection": {"CWE-502"},
            "ssrf": {"CWE-918"},
            "file_upload": {"CWE-434"},
            "open_redirect": {"CWE-601"},
        }
        vuln = normalize_vuln_type(finding.get("vuln_type"))
        cwe = (finding.get("cwe_id") or "").strip()
        expected = cwe_vuln_map.get(vuln)
        if expected and cwe and cwe not in expected:
            signals += 1
            notes.append("cwe_mismatch")

        # Signal 4: very generic reasoning
        reasoning = text_from_any(finding.get("reasoning"))
        if len(reasoning) < 90 and any(p in reasoning.lower() for p in [
            "this is vulnerable because",
            "attacker can exploit",
            "no sanitization is applied",
        ]):
            signals += 1
            notes.append("generic_reasoning")

        # Scoring
        if signals == 0:
            return 1.0, "no hallucination signals"
        if signals == 1:
            return 0.75, "1 hallucination signal: " + ",".join(notes)
        if signals == 2:
            return 0.35, "2 hallucination signals: " + ",".join(notes)
        return 0.0, f"{signals} hallucination signals: " + ",".join(notes)


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: python3 phase3_gate.py <plugin-slug> [--reports-dir reports] [--plugins-dir plugins]")
        return 1

    _script_dir = Path(__file__).resolve().parent
    _root_dir = _script_dir.parent.parent  # tools/bin -> tools -> root

    slug = sys.argv[1]
    reports_dir = str(_root_dir / "reports")
    plugins_dir = str(_root_dir / "plugins")
    for i, arg in enumerate(sys.argv):
        if arg == "--reports-dir" and i + 1 < len(sys.argv):
            reports_dir = sys.argv[i + 1]
        if arg == "--plugins-dir" and i + 1 < len(sys.argv):
            plugins_dir = sys.argv[i + 1]

    layout = build_report_layout(reports_dir).ensure()

    ir_path = layout.phase1 / f"{slug}-ir.json"
    phase2_path = layout.phase2 / f"{slug}-phase2.json"
    semgrep_path = layout.phase1 / f"{slug}-semgrep.json"
    psalm_path = layout.phase1 / f"{slug}-psalm.sarif"

    ir = load_json(str(ir_path))
    if not ir:
        print(f"[ERROR] IR not found: {ir_path}")
        return 1
    phase2 = load_json(str(phase2_path))
    if not phase2:
        print(f"[ERROR] Phase 2 not found: {phase2_path}")
        return 1
    phase2_trust_state = resolve_phase2_trust_state(phase2)
    if phase2_trust_state != "success":
        print(
            f"[ERROR] Phase 2 canonical is not trusted for Phase 3: {phase2_path} "
            f"(trust_state={phase2_trust_state or 'missing'})"
        )
        return 1

    semgrep = load_json(str(semgrep_path))
    psalm_sarif = load_json(str(psalm_path))
    plugin_dir = f"{plugins_dir}/{slug}" if os.path.isdir(f"{plugins_dir}/{slug}") else None

    # G-05: load optional IR supplement (Agent D resolved_dynamic EP entries).
    # Supplement path: reports/phase1/<slug>-ir-supplement.json
    # Gate functions normally if supplement is absent — Agent D may not be deployed yet.
    ir_supplement_path = layout.phase1 / f"{slug}-ir-supplement.json"
    ir_supplement = load_json(str(ir_supplement_path))
    if ir_supplement:
        supp_ep_count = len(ir_supplement.get("entry_points", []))
        print(f"[INFO] IR supplement loaded: {ir_supplement_path} ({supp_ep_count} EPs)")

    validator = SemanticValidator(ir, phase2, semgrep, plugin_dir, psalm_sarif, ir_supplement)

    findings = phase2.get("findings", []) or []
    validated = [validator.validate_finding(f) for f in findings]

    tp_findings = [f for f in findings if f.get("verdict") == "TP"]
    confirmed = [v for v in validated if v["validation_status"] == "CONFIRMED"]
    uncertain = [v for v in validated if v["validation_status"] == "UNCERTAIN"]
    risk_notes = [v for v in validated if v["validation_status"] == "RISK_NOTE"]
    rejected = [v for v in validated if v["validation_status"] == "REJECTED"]

    actionable = []
    actionable_not_patchstack = []
    actionable_reportability_unknown = []
    for i, v in enumerate(validated):
        if findings[i].get("verdict") == "TP" and v["validation_status"] == "CONFIRMED":
            merged = {**findings[i], "confidence_score": v["confidence_score"]}
            patchstack_eligible = v.get("patchstack_eligible")
            if patchstack_eligible is False:
                actionable_not_patchstack.append(merged)
            elif patchstack_eligible is None:
                actionable_reportability_unknown.append(merged)
            else:
                actionable.append(merged)

    legacy_summary = {
        "confirmed": sum(1 for v in validated if v.get("legacy_validation_status") == "CONFIRMED"),
        "plausible": sum(1 for v in validated if v.get("legacy_validation_status") == "PLAUSIBLE"),
        "uncertain": sum(1 for v in validated if v.get("legacy_validation_status") == "UNCERTAIN"),
        "accepted_fp": sum(1 for v in validated if v.get("legacy_validation_status") == "ACCEPTED_FP"),
        "likely_hallucination": sum(1 for v in validated if v.get("legacy_validation_status") == "LIKELY_HALLUCINATION"),
    }

    output = {
        "plugin_slug": slug,
        "phase1_summary": {
            "entry_points": len(ir.get("entry_points", []) or []),
            "anomalies": len(ir.get("anomalies", []) or []),
            "sources": len(ir.get("sources", []) or []),
            "sinks": len(ir.get("sinks", []) or []),
        },
        "phase2_summary": {
            "total": len(findings),
            "tp": len(tp_findings),
            "fp": sum(1 for f in findings if f.get("verdict") == "FP"),
            "review": sum(1 for f in findings if f.get("verdict") == "REVIEW"),
        },
        "phase3_summary": {
            "confirmed": len(confirmed),
            "uncertain": len(uncertain),
            "risk_note": len(risk_notes),
            "rejected": len(rejected),
        },
        "phase3_summary_legacy": legacy_summary,
        "validated_findings": validated,
        "actionable_findings": actionable,
        "actionable_not_patchstack": actionable_not_patchstack,
        "actionable_reportability_unknown": actionable_reportability_unknown,
        "reportability_summary": {
            "confirmed_patchstack_eligible": len(actionable),
            "confirmed_patchstack_ineligible": len(actionable_not_patchstack),
            "confirmed_patchstack_unknown": len(actionable_reportability_unknown),
        },
    }

    output_path = layout.phase3 / f"{slug}-phase3.json"
    tmp_path = output_path.with_suffix(output_path.suffix + ".tmp")
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)
    os.replace(tmp_path, output_path)

    print(f"=== Phase 3 Validation (Gate): {slug} ===")
    print(f"[INFO] Phase 1: {output['phase1_summary']['entry_points']} EPs, {output['phase1_summary']['anomalies']} anomalies")
    print(f"[INFO] Phase 2: {output['phase2_summary']['total']} findings ({output['phase2_summary']['tp']} TP)")
    print(
        f"[INFO] Phase 3: {len(confirmed)} confirmed, {len(uncertain)} uncertain, "
        f"{len(risk_notes)} risk_note, {len(rejected)} rejected"
    )
    print(f"[INFO] Actionable: {len(actionable)} (patchstack-eligible) + {len(actionable_not_patchstack)} (not patchstack-eligible)")
    print(f"[OK] Output: {output_path}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
