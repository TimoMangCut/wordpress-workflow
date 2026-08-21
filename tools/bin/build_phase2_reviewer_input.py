#!/usr/bin/env python3
"""
build_phase2_reviewer_input.py — deterministic JSON-first reviewer input builder for Phase 2
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

import jsonschema


MAX_RELATED_ENTRY_POINTS = 12
MAX_TOP_ANOMALIES = 12
MAX_UNRESOLVED_HOOKS = 12
SNIPPET_RADIUS = 6
MAX_PRIMARY_SNIPPETS = 18
MAX_OPTIONAL_SNIPPETS = 12
MAX_PACKET_OPTIONAL_SNIPPETS = 6
MAX_ATOMIC_PACKET_GROUPS = 6
MAX_EXPLORE_PRIMARY_SNIPPETS = 8
MAX_EXPLORE_OPTIONAL_SNIPPETS = 4
MAX_EXPLORE_OPTIONAL_ANCHORS = 6

ANCHOR_COLON_RE = re.compile(r"(?P<file>[A-Za-z0-9_./-]+\.php):(?P<line>\d+)")
ANCHOR_LINE_RE = re.compile(r"(?P<file>[A-Za-z0-9_./-]+\.php)\s+line\s+(?P<line>\d+)", re.IGNORECASE)
CLASS_LINES_RE = re.compile(r"(?P<class>[A-Z][A-Za-z0-9_]+)\s*\((?P<lines>\d+(?:\s*,\s*\d+)*)\)")
AGGREGATE_HINT_RE = re.compile(r"\b(multiple|various|batch|multi(?:-| )surface)\b", re.IGNORECASE)
CLASS_FILE_CACHE: dict[tuple[str, str], str | None] = {}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def normalize_review_mode(review_mode: str) -> str:
    mapping = {
        "skeptical": "core",
        "forced_exploration": "explore",
        "core": "core",
        "explore": "explore",
        "terminal_core": "terminal_core",
    }
    normalized = mapping.get(str(review_mode).strip().lower())
    if not normalized:
        raise ValueError(f"Unsupported review mode: {review_mode}")
    return normalized


def find_project_root() -> Path:
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        if (candidate / "contracts").is_dir():
            return candidate
    return Path.cwd()


def relative_to_root(path: Path, root: Path) -> str:
    try:
        return str(path.resolve().relative_to(root.resolve()))
    except Exception:
        return str(path)


def review_output_schema_path(root: Path, review_mode: str) -> Path:
    review_mode = normalize_review_mode(review_mode)
    if review_mode == "terminal_core":
        return root / "contracts" / "phase2-review-terminal-core-output.schema.json"
    if review_mode == "core":
        return root / "contracts" / "phase2-review-core-output.schema.json"
    return root / "contracts" / "phase2-review-explore-output.schema.json"


def anchor(file_path: str | None, line_number: int | None, fallback_file: str | None = None, fallback_line: int | None = None) -> str:
    rel = file_path or fallback_file or "<unknown>"
    line = line_number or fallback_line
    if isinstance(line, int) and line > 0:
        return f"{rel}:{line}"
    return rel


def optional_string(value: object) -> str | None:
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return str(value)
    text = str(value).strip()
    return text or None


def parse_anchor(anchor_value: str | None) -> tuple[str | None, int | None]:
    if not anchor_value or anchor_value == "<unknown>":
        return None, None
    path, sep, tail = anchor_value.rpartition(":")
    if sep and tail.isdigit():
        return path, int(tail)
    return anchor_value, None


def iter_text_fragments(value: object) -> list[str]:
    fragments: list[str] = []
    if value is None:
        return fragments
    if isinstance(value, str):
        text = value.strip()
        if text:
            fragments.append(text)
        return fragments
    if isinstance(value, dict):
        for item in value.values():
            fragments.extend(iter_text_fragments(item))
        return fragments
    if isinstance(value, list):
        for item in value:
            fragments.extend(iter_text_fragments(item))
        return fragments
    return fragments


def anchor_item(kind: str, anchor_value: str | None, note: str | None = None) -> dict | None:
    anchor_value = optional_string(anchor_value)
    if not anchor_value:
        return None
    return {"kind": kind, "anchor": anchor_value, "note": optional_string(note)}


def extract_text_anchor_items(text: str) -> list[dict]:
    items: list[dict] = []
    for pattern in (ANCHOR_COLON_RE, ANCHOR_LINE_RE):
        for match in pattern.finditer(text):
            items.append(
                {
                    "kind": "aggregate_reference",
                    "anchor": f"{match.group('file')}:{match.group('line')}",
                    "note": None,
                }
            )
    return items


def resolve_class_file(root: Path, slug: str, class_name: str) -> str | None:
    cache_key = (slug, class_name)
    if cache_key in CLASS_FILE_CACHE:
        return CLASS_FILE_CACHE[cache_key]

    plugin_root = root / "plugins" / slug
    matches = sorted(plugin_root.rglob(f"{class_name}.php"))
    if not matches:
        CLASS_FILE_CACHE[cache_key] = None
        return None

    best = min(matches, key=lambda path: (len(path.parts), str(path)))
    rel = str(best.relative_to(plugin_root))
    CLASS_FILE_CACHE[cache_key] = rel
    return rel


def extract_class_anchor_items(root: Path, slug: str, text: str) -> list[dict]:
    items: list[dict] = []
    for match in CLASS_LINES_RE.finditer(text):
        file_path = resolve_class_file(root, slug, match.group("class"))
        if not file_path:
            continue
        for raw_line in match.group("lines").split(","):
            line = raw_line.strip()
            if not line.isdigit():
                continue
            items.append(
                {
                    "kind": "aggregate_reference",
                    "anchor": f"{file_path}:{line}",
                    "note": match.group("class"),
                }
            )
    return items


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def extract_snippet(repo_root: Path, plugin_slug: str, anchor_value: str, kind: str) -> dict | None:
    rel_path, focus_line = parse_anchor(anchor_value)
    if not rel_path or focus_line is None:
        return None
    file_path = repo_root / "plugins" / plugin_slug / rel_path
    if not file_path.exists():
        return None
    lines = read_lines(file_path)
    if not lines:
        return None
    start = max(1, focus_line - SNIPPET_RADIUS)
    end = min(len(lines), focus_line + SNIPPET_RADIUS)
    return {
        "file": rel_path,
        "anchor": anchor_value,
        "focus_line": focus_line,
        "line_start": start,
        "line_end": end,
        "kind": kind,
        "code": "\n".join(f"{lineno:>6}\t{lines[lineno - 1]}" for lineno in range(start, end + 1)),
    }


def dedupe_snippets(snippets: list[dict], max_items: int) -> list[dict]:
    deduped: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for snippet in snippets:
        key = (snippet["file"], snippet["anchor"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(snippet)
        if len(deduped) >= max_items:
            break
    return deduped


def dedupe_anchor_items(items: list[dict]) -> list[dict]:
    deduped: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for item in items:
        key = (str(item.get("kind")), str(item.get("anchor")))
        if key in seen:
            continue
        seen.add(key)
        deduped.append(item)
    return deduped


def simplify_entry_point(entry_point: dict) -> dict:
    callback = entry_point.get("callback") or {}
    return {
        "id": entry_point.get("id"),
        "type": entry_point.get("type"),
        "hook_name": entry_point.get("hook_name"),
        "auth_level": entry_point.get("auth_level"),
        "file": entry_point.get("file"),
        "line": entry_point.get("line"),
        "callback_name": callback.get("name"),
        "callback_class": callback.get("class"),
    }


def simplify_anomaly(anomaly: dict) -> dict:
    evidence = anomaly.get("evidence") or {}
    return {
        "id": anomaly.get("id"),
        "type": anomaly.get("type"),
        "severity": anomaly.get("severity"),
        "entry_point_id": anomaly.get("entry_point_id"),
        "description": anomaly.get("description"),
        "file": evidence.get("file"),
        "line": evidence.get("line"),
    }


def simplify_unresolved_hook(item: dict) -> dict:
    return {
        "file": item.get("file"),
        "line": item.get("line"),
        "function": item.get("function"),
        "hook_arg_type": item.get("hook_arg_type"),
    }


def summarize_worker_findings(worker_output: dict) -> tuple[list[dict], set[str]]:
    findings = []
    entry_point_ids: set[str] = set()
    for finding in worker_output.get("findings", []):
        entry_point_id = finding.get("entry_point_id")
        if entry_point_id:
            entry_point_ids.add(entry_point_id)
        findings.append(
            {
                "finding_id": finding.get("finding_id"),
                "verdict": optional_string(finding.get("verdict")) or "UNKNOWN",
                "vuln_type": optional_string(finding.get("vuln_type")) or "unknown",
                "severity": optional_string(finding.get("severity")),
                "auth_required": optional_string(finding.get("auth_required")),
                "confidence": finding.get("confidence"),
                "entry_point_id": optional_string(entry_point_id),
                "source_anchor": anchor(
                    finding.get("source_file_path"),
                    finding.get("source_line_number"),
                    fallback_file=finding.get("file_path"),
                    fallback_line=finding.get("line_number"),
                ),
                "sink_anchor": anchor(
                    finding.get("sink_file_path"),
                    finding.get("sink_line_number"),
                    fallback_file=finding.get("file_path"),
                    fallback_line=finding.get("line_number"),
                ),
                "patchstack_eligible": finding.get("patchstack_eligible"),
            }
        )
    return findings, entry_point_ids


def worker_findings_by_id(worker_output: dict) -> dict[str, dict]:
    findings: dict[str, dict] = {}
    for finding in worker_output.get("findings", []):
        finding_id = optional_string(finding.get("finding_id"))
        if finding_id:
            findings[finding_id] = finding
    return findings


def worker_summary(worker_output: dict) -> dict:
    findings = worker_output.get("findings", [])
    tp = sum(1 for item in findings if item.get("verdict") == "TP")
    fp = sum(1 for item in findings if item.get("verdict") == "FP")
    review = sum(1 for item in findings if item.get("verdict") == "REVIEW")
    negative = len(worker_output.get("negative_findings", []))
    return {
        "total_findings": len(findings),
        "true_positive_count": tp,
        "false_positive_count": fp,
        "needs_review_count": review,
        "negative_findings_count": negative,
        "overall_risk": worker_output.get("overall_risk"),
        "analysis_summary": worker_output.get("analysis_summary"),
    }


def summarized_worker_summary(findings_summary: list[dict], worker_output: dict) -> dict:
    tp = sum(1 for item in findings_summary if str(item.get("verdict") or "").upper() == "TP")
    fp = sum(1 for item in findings_summary if str(item.get("verdict") or "").upper() == "FP")
    review = sum(1 for item in findings_summary if str(item.get("verdict") or "").upper() == "REVIEW")
    return {
        "total_findings": len(findings_summary),
        "true_positive_count": tp,
        "false_positive_count": fp,
        "needs_review_count": review,
        "negative_findings_count": 0,
        "overall_risk": worker_output.get("overall_risk"),
        "analysis_summary": worker_output.get("analysis_summary"),
    }


def unresolved_review_targets(review_doc: dict) -> tuple[set[str], set[str]]:
    packet_ids: set[str] = set()
    parent_finding_ids: set[str] = set()
    for item in review_doc.get("finding_reviews") or []:
        assessment = optional_string(item.get("assessment"))
        if not assessment:
            continue
        if assessment.lower() in {"keep", "field_fix"}:
            continue
        packet_id = optional_string(item.get("packet_id")) or optional_string(item.get("finding_id"))
        parent_finding_id = optional_string(item.get("parent_finding_id")) or optional_string(item.get("finding_id"))
        if packet_id:
            packet_ids.add(packet_id)
        if parent_finding_id:
            parent_finding_ids.add(parent_finding_id)
    return packet_ids, parent_finding_ids


def current_review_finding_targets(worker_output: dict) -> set[str]:
    finding_ids: set[str] = set()
    for item in worker_output.get("findings") or []:
        if not isinstance(item, dict):
            continue
        finding_id = optional_string(item.get("finding_id"))
        verdict = optional_string(item.get("verdict"))
        if finding_id and verdict and verdict.upper() == "REVIEW":
            finding_ids.add(finding_id)
    return finding_ids


def phase1_context(ir_doc: dict, related_entry_point_ids: set[str], review_mode: str) -> dict:
    review_mode = normalize_review_mode(review_mode)
    entry_points = ir_doc.get("entry_points", [])
    anomalies = ir_doc.get("anomalies", [])
    unresolved_hooks = ir_doc.get("unresolved_hooks", [])

    related = [simplify_entry_point(item) for item in entry_points if item.get("id") in related_entry_point_ids]
    if not related:
        related = [simplify_entry_point(item) for item in entry_points[:MAX_RELATED_ENTRY_POINTS]]
    else:
        related = related[:MAX_RELATED_ENTRY_POINTS]

    prioritized_anomalies = []
    for item in anomalies:
        severity = (item.get("severity") or "").lower()
        if item.get("entry_point_id") in related_entry_point_ids or severity in {"critical", "high"}:
            prioritized_anomalies.append(simplify_anomaly(item))
    if review_mode == "explore" and len(prioritized_anomalies) < MAX_TOP_ANOMALIES:
        seen_ids = {item.get("id") for item in prioritized_anomalies}
        for item in anomalies:
            if item.get("id") in seen_ids:
                continue
            prioritized_anomalies.append(simplify_anomaly(item))
            if len(prioritized_anomalies) >= MAX_TOP_ANOMALIES:
                break
    prioritized_anomalies = prioritized_anomalies[:MAX_TOP_ANOMALIES]

    related_files = {
        item.get("file")
        for item in entry_points
        if item.get("id") in related_entry_point_ids and item.get("file")
    }
    filtered_hooks = []
    for item in unresolved_hooks:
        file_path = item.get("file")
        if review_mode == "explore" or not related_files or file_path in related_files:
            filtered_hooks.append(item)
        if len(filtered_hooks) >= MAX_UNRESOLVED_HOOKS:
            break
    simplified_hooks = [simplify_unresolved_hook(item) for item in filtered_hooks]
    return {
        "entry_point_count": len(entry_points),
        "anomaly_count": len(anomalies),
        "unresolved_hook_count": len(unresolved_hooks),
        "related_entry_points": related,
        "top_anomalies": prioritized_anomalies,
        "unresolved_hooks": simplified_hooks,
    }


def threat_context_summary(threat_context_doc: dict | None) -> dict | None:
    if not threat_context_doc:
        return None
    matched_categories = threat_context_doc.get("matched_categories") or []
    priority_vulns = threat_context_doc.get("priority_vulns") or []
    notes = threat_context_doc.get("notes")
    if isinstance(notes, list):
        notes = "; ".join(str(item) for item in notes[:3]) or None
    elif notes is not None:
        notes = str(notes)
    return {
        "matched_categories": [str(item) for item in matched_categories[:8]],
        "priority_vulns": [str(item) for item in priority_vulns[:8]],
        "notes": notes,
    }


def capped_explore_lead_count(max_candidates: int | None, ceiling: int) -> int:
    if max_candidates is None:
        return min(ceiling, 6)
    return max(4, min(ceiling, max_candidates * 3))


def capped_explore_hook_count(max_candidates: int | None, ceiling: int) -> int:
    if max_candidates is None:
        return min(ceiling, 4)
    return max(2, min(ceiling, max_candidates + 1))


def summarize_claimed_impact(finding_summary: dict, raw_finding: dict | None) -> str | None:
    raw_finding = raw_finding or {}
    for key in ("impact", "impact_summary", "impact_detail", "exploit_impact", "impact_reason"):
        value = optional_string(raw_finding.get(key))
        if value:
            return value
    vuln_type = optional_string(finding_summary.get("vuln_type")) or "unknown issue"
    auth_required = optional_string(finding_summary.get("auth_required")) or "unknown"
    sink_anchor = optional_string(finding_summary.get("sink_anchor")) or "<unknown>"
    return f"Worker claims {vuln_type} is materially exploitable with auth boundary `{auth_required}` and impact reachable at {sink_anchor}."


def compact_text_list(values: object, limit: int = 3) -> list[str]:
    result: list[str] = []
    for item in values or []:
        text = optional_string(item)
        if text:
            result.append(text)
        if len(result) >= limit:
            break
    return result


def extract_reasoning_object(raw_finding: dict | None) -> dict:
    if not isinstance(raw_finding, dict):
        return {}
    reasoning = raw_finding.get("reasoning")
    return reasoning if isinstance(reasoning, dict) else {}


def extract_reasoning_fallback(raw_finding: dict | None) -> str | None:
    if not isinstance(raw_finding, dict):
        return None
    return optional_string(raw_finding.get("reasoning"))


def build_worker_context(raw_finding: dict | None) -> dict:
    raw_finding = raw_finding or {}
    reasoning = extract_reasoning_object(raw_finding)
    reasoning_fallback = extract_reasoning_fallback(raw_finding)
    return {
        "source_function": optional_string(raw_finding.get("source_function")),
        "sink_function": optional_string(raw_finding.get("sink_function")),
        "fp_reason": optional_string(raw_finding.get("fp_reason")),
        "reasoning_excerpt": {
            "hypothesis": optional_string(reasoning.get("hypothesis")),
            "trace": optional_string(reasoning.get("trace")),
            "defenses": compact_text_list(reasoning.get("defenses")),
            "refutation": compact_text_list(reasoning.get("refutation")),
            "conclusion": optional_string(reasoning.get("conclusion")) or reasoning_fallback,
        },
    }


def classify_sink_semantics(
    *,
    sink_function: str | None,
    sink_anchor: str | None,
    claimed_impact: str | None,
) -> str:
    text = " ".join(
        part
        for part in (
            optional_string(sink_function),
            optional_string(sink_anchor),
            optional_string(claimed_impact),
        )
        if part
    ).lower()

    if any(token in text for token in ("do_action", "apply_filters")):
        return "hook_dispatch"
    if any(token in text for token in ("wp_send_json", "wp_json_encode", "wp_rest_response", "rest response", "json")):
        return "json_response"
    if any(token in text for token in ("echo", "print", "render", "wp_die", "innerhtml", "outerhtml")):
        return "local_output"
    if any(token in text for token in ("wp_remote_", "remote api", "outbound api", "request body", "post_contact")):
        return "network_side_effect"
    if any(token in text for token in ("filter_var", "str_contains", "validate_boolean", "boolean", "bool")):
        return "boolean_guard"
    if any(token in text for token in ("set_transient", "update_option", "delete_option", "add_option", "update_post_meta", "update_user_meta")):
        return "state_change"
    return "unknown"


def packet_surface_label(focus_file: str | None) -> str:
    if not focus_file or focus_file == "<unknown>":
        return "current surface"
    stem = Path(focus_file).stem
    return stem or focus_file


def packet_anchor_strings(grouped_items: list[dict], limit: int = 4) -> list[str]:
    anchors: list[str] = []
    seen: set[str] = set()
    for item in grouped_items:
        anchor_value = optional_string(item.get("anchor"))
        if not anchor_value or anchor_value in seen:
            continue
        seen.add(anchor_value)
        anchors.append(anchor_value)
        if len(anchors) >= limit:
            break
    return anchors


def build_packet_claimed_impact(
    *,
    finding_summary: dict,
    raw_finding: dict | None,
    aggregate: bool,
    focus_file: str | None,
    focus_anchor: str | None,
) -> str | None:
    if not aggregate:
        return summarize_claimed_impact(finding_summary, raw_finding)

    vuln_type = optional_string(finding_summary.get("vuln_type")) or "unknown issue"
    auth_required = optional_string(finding_summary.get("auth_required")) or "unknown"
    surface_label = packet_surface_label(focus_file)
    return (
        f"Review only the {surface_label} surface for {vuln_type}. "
        f"Confirm whether the path around {focus_anchor or '<unknown>'} has concrete impact "
        f"for auth boundary `{auth_required}` without inheriting conclusions from sibling surfaces."
    )


def build_review_focus(
    *,
    packet_kind: str,
    focus_file: str | None,
    focus_anchor: str | None,
    entry_point_anchor: str | None,
    primary_files: list[str],
    optional_files: list[str],
    sink_semantics: str,
) -> dict:
    scope_statement = (
        f"Review only the packet-local claim centered on {focus_anchor or '<unknown>'} "
        f"in {focus_file or '<unknown>'}. Start from the listed packet evidence, not from a plugin-wide hypothesis."
    )
    stop_conditions = [
        "Once packet-local reachability, authorization, dataflow, impact, and missing evidence are answered with file:line support, stop and write critique JSON.",
        "Do not reopen unrelated plugin surfaces just because the parent finding or worker narrative mentions them.",
    ]
    disallowed_drift = [
        "whole_plugin_reaudit",
        "translation_or_asset_search",
        "sibling_surface_expansion_without_evidence",
    ]
    default_resolution = "needs_more_evidence"

    if sink_semantics == "hook_dispatch":
        stop_conditions.append(
            "If the packet ends at a hook dispatch and no downstream consumer is already evidenced in this packet, mark the missing downstream consumer explicitly instead of tracing every consumer in the plugin."
        )
        disallowed_drift.append("shared_hook_consumer_enumeration")
    elif sink_semantics == "json_response":
        stop_conditions.append(
            "If packet-local evidence ends in JSON/REST response handling and no browser sink is shown, prefer field_fix, retract, or needs_more_evidence over plugin-wide rendering hunts."
        )
        default_resolution = "field_fix_or_retract"
    elif sink_semantics == "boolean_guard":
        stop_conditions.append(
            "If the packet-local code resolves to boolean/guard logic rather than a concrete impact sink, keep the critique local and do not expand into unrelated callers unless required by one explicit expansion attempt."
        )
        default_resolution = "field_fix_or_retract"
    elif sink_semantics == "network_side_effect":
        stop_conditions.append(
            "If packet-local evidence shows only outbound API forwarding, require a concrete local security impact before keeping the worker's original claim."
        )

    return {
        "scope_statement": scope_statement,
        "sink_semantics": sink_semantics,
        "default_resolution_on_missing_terminal_evidence": default_resolution,
        "stop_conditions": stop_conditions,
        "disallowed_drift": disallowed_drift,
        "primary_scope_files": primary_files,
        "optional_scope_files": optional_files,
        "entry_point_anchor": entry_point_anchor,
    }


def build_packet_worker_context(
    *,
    raw_finding: dict | None,
    aggregate: bool,
    focus_file: str | None,
    focus_anchor: str | None,
    grouped_items: list[dict],
    entry_point_anchor: str | None,
    primary_files: list[str],
    sink_semantics: str,
) -> dict:
    base_context = build_worker_context(raw_finding)

    anchor_list = packet_anchor_strings(grouped_items)
    surface_label = packet_surface_label(focus_file)
    focus_value = focus_anchor or (anchor_list[0] if anchor_list else "<unknown>")
    reasoning_excerpt = base_context.get("reasoning_excerpt") or {}
    defenses = compact_text_list(reasoning_excerpt.get("defenses"), limit=2)
    if not defenses:
        defenses = compact_text_list(extract_reasoning_object(raw_finding).get("defenses"), limit=2)
    if not defenses:
        fallback_reasoning = extract_reasoning_fallback(raw_finding)
        if fallback_reasoning:
            defenses = [fallback_reasoning]
    extra_defense = "Keep critique packet-local; do not reuse sibling-surface defenses or conclusions without code evidence in this packet."
    if sink_semantics == "hook_dispatch":
        extra_defense = "Treat downstream hook consumers as missing evidence unless a concrete consumer is already shown in the packet."
    elif sink_semantics == "json_response":
        extra_defense = "JSON/REST response handling is not a browser sink by itself; require packet-local output evidence before keeping an XSS-style claim."
    elif sink_semantics == "boolean_guard":
        extra_defense = "Boolean/guard logic is not a terminal impact sink by itself; prefer field fixes or missing-evidence notes over caller hunts."
    defenses.append(extra_defense)

    scope_note = (
        f"Packet-local reviewer scope: {surface_label} at {focus_value}. "
        f"Primary files: {', '.join(primary_files) or surface_label}."
    )
    if aggregate:
        scope_note = (
            f"Aggregate worker finding was atomized for reviewer_core. "
            f"This packet is limited to {surface_label} and anchors {', '.join(anchor_list) or focus_value}."
        )

    return {
        "source_function": optional_string(base_context.get("source_function")) if not aggregate else surface_label,
        "sink_function": optional_string(base_context.get("sink_function")) or f"packet-local handling near {focus_value}",
        "fp_reason": scope_note,
        "original_fp_reason": optional_string(base_context.get("fp_reason")),
        "reasoning_excerpt": {
            "hypothesis": (
                f"Validate only the packet-local claim for {surface_label}. "
                f"Determine whether anchors {', '.join(anchor_list) or focus_value} actually support the worker's claim without widening to other surfaces."
            ),
            "trace": (
                f"Packet-local review only. Focus file: {focus_file or '<unknown>'}. "
                f"Focus anchors: {', '.join(anchor_list) or focus_value}. "
                f"Primary files: {', '.join(primary_files) or '<unknown>'}. "
                f"Entry point: {entry_point_anchor or '<unknown>'}. "
                f"Treat unrelated callers, consumers, and sibling surfaces as out of scope unless an explicit expansion attempt is justified."
            ),
            "defenses": defenses,
            "refutation": [
                (
                    f"Refute or keep this packet on {surface_label} alone. "
                    f"Do not carry over conclusions from plugin-wide traces without packet-local code evidence."
                )
            ],
            "conclusion": (
                f"Keep, downgrade, retract, or mark needs_more_evidence "
                f"based only on packet-local evidence for {surface_label}."
            ),
        },
        "original_reasoning_excerpt": reasoning_excerpt,
    }


def build_review_questions(finding_summary: dict, entry_point_anchor: str | None) -> dict:
    source_anchor = optional_string(finding_summary.get("source_anchor")) or "<unknown>"
    sink_anchor = optional_string(finding_summary.get("sink_anchor")) or "<unknown>"
    auth_required = optional_string(finding_summary.get("auth_required")) or "unknown"
    vuln_type = optional_string(finding_summary.get("vuln_type")) or "unknown issue"
    entry_point_label = entry_point_anchor or optional_string(finding_summary.get("entry_point_id")) or source_anchor
    return {
        "reachability": f"Can an attacker really reach the claimed path from {entry_point_label} without hidden preconditions or workflow assumptions?",
        "authorization": f"Does the path have a stronger guard than the worker claims, including capability, permission_callback, nonce semantics, or trust-boundary limits for auth `{auth_required}`?",
        "dataflow": f"Does attacker-controlled data actually flow from {source_anchor} to {sink_anchor} for the claimed {vuln_type}, without a refuting guard, sanitizer, or broken hop?",
        "impact": f"Assuming the path reaches {sink_anchor}, is the worker's claimed impact concrete and not overstated for this plugin context?",
        "missing_evidence": "What exact file:line evidence is still missing before this finding can be kept, downgraded, or retracted with confidence?",
    }


def collect_packet_anchor_candidates(
    root: Path,
    slug: str,
    finding_summary: dict,
    raw_finding: dict | None,
    entry_point_anchor: str | None,
    top_anomalies: list[dict],
    unresolved_hooks: list[dict],
) -> list[dict]:
    raw_finding = raw_finding or {}
    entry_point_id = optional_string(finding_summary.get("entry_point_id"))
    source_anchor = optional_string(finding_summary.get("source_anchor"))
    sink_anchor = optional_string(finding_summary.get("sink_anchor"))

    candidates: list[dict] = []
    for item in (
        anchor_item("entry_point", entry_point_anchor),
        anchor_item("finding_source", source_anchor, finding_summary.get("vuln_type")),
        anchor_item("finding_sink", sink_anchor, finding_summary.get("vuln_type")),
        anchor_item(
            "fp_evidence",
            anchor(
                raw_finding.get("fp_evidence", {}).get("file") if isinstance(raw_finding.get("fp_evidence"), dict) else None,
                raw_finding.get("fp_evidence", {}).get("line") if isinstance(raw_finding.get("fp_evidence"), dict) else None,
            ),
            raw_finding.get("fp_evidence", {}).get("defense") if isinstance(raw_finding.get("fp_evidence"), dict) else None,
        ),
    ):
        if item:
            candidates.append(item)

    for item in top_anomalies:
        if entry_point_id and item.get("entry_point_id") == entry_point_id and item.get("file") and item.get("line"):
            candidates.append(
                {
                    "kind": "anomaly",
                    "anchor": f"{item['file']}:{item['line']}",
                    "note": optional_string(item.get("type")),
                }
            )

    related_files = {
        path
        for path in (
            parse_anchor(entry_point_anchor)[0] if entry_point_anchor else None,
            parse_anchor(source_anchor)[0] if source_anchor else None,
            parse_anchor(sink_anchor)[0] if sink_anchor else None,
        )
        if path
    }
    for item in unresolved_hooks:
        if item.get("file") and item.get("line") and (not related_files or item["file"] in related_files):
            candidates.append(
                {
                    "kind": "unresolved_hook",
                    "anchor": f"{item['file']}:{item['line']}",
                    "note": optional_string(item.get("function")),
                }
            )

    for text in iter_text_fragments(raw_finding):
        candidates.extend(extract_text_anchor_items(text))
        candidates.extend(extract_class_anchor_items(root, slug, text))

    return dedupe_anchor_items(candidates)


def aggregate_candidate_groups(review_anchor_candidates: list[dict]) -> list[tuple[str, list[dict]]]:
    groups: dict[str, list[dict]] = {}
    for item in review_anchor_candidates:
        if item.get("kind") == "entry_point":
            continue
        file_path, line_number = parse_anchor(optional_string(item.get("anchor")))
        if not file_path or line_number is None:
            continue
        groups.setdefault(file_path, []).append(item)

    ordered: list[tuple[str, list[dict]]] = []
    for file_path in sorted(groups):
        items = sorted(
            groups[file_path],
            key=lambda current: parse_anchor(optional_string(current.get("anchor")))[1] or 10**9,
        )
        ordered.append((file_path, dedupe_anchor_items(items)))
    return ordered[:MAX_ATOMIC_PACKET_GROUPS]


def is_aggregate_finding(finding_summary: dict, raw_finding: dict | None, grouped_candidates: list[tuple[str, list[dict]]]) -> bool:
    raw_finding = raw_finding or {}
    hint_fields = [
        optional_string(finding_summary.get("vuln_type")),
        optional_string(raw_finding.get("source_function")),
        optional_string(raw_finding.get("sink_function")),
        optional_string(raw_finding.get("fp_reason")),
    ]
    return any(text and AGGREGATE_HINT_RE.search(text) for text in hint_fields) and len(grouped_candidates) >= 2


def packet_focus_anchor(
    *,
    finding: dict,
    grouped_items: list[dict],
) -> str:
    source_anchor = optional_string(finding.get("source_anchor"))
    sink_anchor = optional_string(finding.get("sink_anchor"))
    grouped_anchor_values = {optional_string(item.get("anchor")) for item in grouped_items}
    if source_anchor in grouped_anchor_values:
        return source_anchor
    if sink_anchor in grouped_anchor_values:
        return sink_anchor
    return optional_string(grouped_items[0].get("anchor")) or source_anchor or sink_anchor or "<unknown>"


def packet_snippets_for_items(root: Path, slug: str, items: list[dict], max_items: int) -> list[dict]:
    snippets = [
        snippet
        for item in items
        if (snippet := extract_snippet(root, slug, optional_string(item.get("anchor")) or "", item.get("kind") or "other")) is not None
    ]
    return dedupe_snippets(snippets, max_items)


def build_reviewer_evidence(
    *,
    root: Path,
    slug: str,
    findings_summary: list[dict],
    related_entry_points: list[dict],
    top_anomalies: list[dict],
    unresolved_hooks: list[dict],
    include_optional_evidence: bool,
) -> dict:
    primary_anchors: list[dict] = []
    optional_anchors: list[dict] = []

    for finding in findings_summary:
        if finding.get("source_anchor"):
            primary_anchors.append(
                {
                    "kind": "finding_source",
                    "anchor": finding["source_anchor"],
                    "finding_id": finding.get("finding_id"),
                    "entry_point_id": finding.get("entry_point_id"),
                    "note": finding.get("vuln_type"),
                }
            )
        if finding.get("sink_anchor") and finding.get("sink_anchor") != finding.get("source_anchor"):
            primary_anchors.append(
                {
                    "kind": "finding_sink",
                    "anchor": finding["sink_anchor"],
                    "finding_id": finding.get("finding_id"),
                    "entry_point_id": finding.get("entry_point_id"),
                    "note": finding.get("vuln_type"),
                }
            )

    for item in related_entry_points:
        if item.get("file") and item.get("line"):
            primary_anchors.append(
                {
                    "kind": "entry_point",
                    "anchor": f"{item['file']}:{item['line']}",
                    "finding_id": None,
                    "entry_point_id": item.get("id"),
                    "note": item.get("hook_name"),
                }
            )

    if include_optional_evidence:
        for item in top_anomalies:
            if item.get("file") and item.get("line"):
                optional_anchors.append(
                    {
                        "kind": "anomaly",
                        "anchor": f"{item['file']}:{item['line']}",
                        "entry_point_id": item.get("entry_point_id"),
                        "note": item.get("type"),
                    }
                )

        for item in unresolved_hooks:
            if item.get("file") and item.get("line"):
                optional_anchors.append(
                    {
                        "kind": "unresolved_hook",
                        "anchor": f"{item['file']}:{item['line']}",
                        "entry_point_id": None,
                        "note": item.get("function"),
                    }
                )

    primary_snippets = [
        snippet
        for item in primary_anchors
        if (snippet := extract_snippet(root, slug, item["anchor"], item["kind"])) is not None
    ]
    optional_snippets = [
        snippet
        for item in optional_anchors
        if (snippet := extract_snippet(root, slug, item["anchor"], item["kind"])) is not None
    ]

    primary_snippets = dedupe_snippets(primary_snippets, MAX_PRIMARY_SNIPPETS)
    optional_snippets = dedupe_snippets(optional_snippets, MAX_OPTIONAL_SNIPPETS)

    return {
        "primary_anchors": primary_anchors,
        "primary_files": sorted({snippet["file"] for snippet in primary_snippets}),
        "primary_snippets": primary_snippets,
        "optional_evidence": {
            "anchors": optional_anchors,
            "files": sorted({snippet["file"] for snippet in optional_snippets}),
            "snippets": optional_snippets,
        },
    }


def build_explore_evidence(
    *,
    root: Path,
    slug: str,
    findings_summary: list[dict],
    related_entry_points: list[dict],
    top_anomalies: list[dict],
    unresolved_hooks: list[dict],
    max_candidates: int | None,
) -> dict:
    lead_cap = capped_explore_lead_count(max_candidates, MAX_TOP_ANOMALIES)
    primary_anchors: list[dict] = []
    optional_anchors: list[dict] = []

    for item in top_anomalies[:lead_cap]:
        if item.get("file") and item.get("line"):
            primary_anchors.append(
                {
                    "kind": "anomaly",
                    "anchor": f"{item['file']}:{item['line']}",
                    "finding_id": None,
                    "entry_point_id": item.get("entry_point_id"),
                    "note": item.get("type"),
                }
            )

    for item in unresolved_hooks[:lead_cap]:
        if item.get("file") and item.get("line"):
            primary_anchors.append(
                {
                    "kind": "unresolved_hook",
                    "anchor": f"{item['file']}:{item['line']}",
                    "finding_id": None,
                    "entry_point_id": None,
                    "note": item.get("function"),
                }
            )

    for item in related_entry_points[: min(4, lead_cap)]:
        if item.get("file") and item.get("line"):
            optional_anchors.append(
                {
                    "kind": "entry_point",
                    "anchor": f"{item['file']}:{item['line']}",
                    "entry_point_id": item.get("id"),
                    "note": item.get("hook_name"),
                }
            )

    coverage_finding_cap = max(1, min(len(findings_summary), (max_candidates or 1) + 1))
    for finding in findings_summary[:coverage_finding_cap]:
        for anchor_key, kind in (("source_anchor", "covered_source"), ("sink_anchor", "covered_sink")):
            anchor_value = optional_string(finding.get(anchor_key))
            if not anchor_value:
                continue
            optional_anchors.append(
                {
                    "kind": kind,
                    "anchor": anchor_value,
                    "entry_point_id": finding.get("entry_point_id"),
                    "note": finding.get("finding_id"),
                }
            )

    primary_anchors = dedupe_anchor_items(primary_anchors)[: max(4, lead_cap)]
    optional_anchors = dedupe_anchor_items(optional_anchors)[:MAX_EXPLORE_OPTIONAL_ANCHORS]

    primary_snippets = [
        snippet
        for item in primary_anchors
        if (snippet := extract_snippet(root, slug, item["anchor"], item["kind"])) is not None
    ]
    optional_snippets = [
        snippet
        for item in optional_anchors
        if (snippet := extract_snippet(root, slug, item["anchor"], item["kind"])) is not None
    ]

    primary_snippets = dedupe_snippets(primary_snippets, MAX_EXPLORE_PRIMARY_SNIPPETS)
    optional_snippets = dedupe_snippets(optional_snippets, MAX_EXPLORE_OPTIONAL_SNIPPETS)

    return {
        "primary_anchors": primary_anchors,
        "primary_files": sorted({snippet["file"] for snippet in primary_snippets}),
        "primary_snippets": primary_snippets,
        "optional_evidence": {
            "anchors": optional_anchors,
            "files": sorted({snippet["file"] for snippet in optional_snippets}),
            "snippets": optional_snippets,
        },
    }


def build_finding_packets(
    *,
    root: Path,
    slug: str,
    findings_summary: list[dict],
    raw_findings: dict[str, dict],
    related_entry_points: list[dict],
    top_anomalies: list[dict],
    unresolved_hooks: list[dict],
) -> list[dict]:
    entry_point_by_id = {
        optional_string(item.get("id")): item
        for item in related_entry_points
        if optional_string(item.get("id"))
    }
    packets: list[dict] = []

    for finding in findings_summary:
        finding_id = optional_string(finding.get("finding_id")) or "unknown-finding"
        raw_finding = raw_findings.get(finding_id)
        entry_point_id = optional_string(finding.get("entry_point_id"))
        entry_point = entry_point_by_id.get(entry_point_id)
        entry_point_anchor = None
        if entry_point and entry_point.get("file") and entry_point.get("line"):
            entry_point_anchor = f"{entry_point['file']}:{entry_point['line']}"
        review_anchor_candidates = collect_packet_anchor_candidates(
            root,
            slug,
            finding,
            raw_finding,
            entry_point_anchor,
            top_anomalies,
            unresolved_hooks,
        )

        grouped_candidates = aggregate_candidate_groups(review_anchor_candidates)
        aggregate = is_aggregate_finding(finding, raw_finding, grouped_candidates)

        packet_groups: list[tuple[str, list[dict], str]] = []
        if aggregate:
            for index, (focus_file, grouped_items) in enumerate(grouped_candidates, start=1):
                packet_groups.append((f"{finding_id}__p{index:02d}", grouped_items, focus_file))
        else:
            packet_groups.append((finding_id, review_anchor_candidates, parse_anchor(optional_string(finding.get("source_anchor")))[0] or "<unknown>"))

        for packet_id, grouped_items, focus_file in packet_groups:
            focus_anchor = packet_focus_anchor(finding=finding, grouped_items=grouped_items)
            source_anchor = optional_string(finding.get("source_anchor")) or focus_anchor
            sink_anchor = optional_string(finding.get("sink_anchor")) or focus_anchor
            if aggregate:
                source_path, _ = parse_anchor(source_anchor)
                sink_path, _ = parse_anchor(sink_anchor)
                if source_path != focus_file:
                    source_anchor = focus_anchor
                if sink_path != focus_file:
                    sink_anchor = focus_anchor

            primary_anchor_items = []
            if source_anchor:
                primary_anchor_items.append({"kind": "finding_source", "anchor": source_anchor})
            if sink_anchor and sink_anchor != source_anchor:
                primary_anchor_items.append({"kind": "finding_sink", "anchor": sink_anchor})
            if focus_anchor not in {item.get("anchor") for item in primary_anchor_items}:
                primary_anchor_items.append({"kind": "packet_focus", "anchor": focus_anchor})
            if entry_point_anchor:
                primary_anchor_items.append({"kind": "entry_point", "anchor": entry_point_anchor})

            primary_snippets = packet_snippets_for_items(root, slug, primary_anchor_items, MAX_PRIMARY_SNIPPETS)
            optional_snippets = packet_snippets_for_items(root, slug, grouped_items, MAX_PACKET_OPTIONAL_SNIPPETS)

            packet_vuln_type = finding.get("vuln_type")
            if aggregate and focus_file and focus_file != "<unknown>":
                packet_vuln_type = f"{packet_vuln_type} [{focus_file}]"

            primary_files = sorted({snippet["file"] for snippet in primary_snippets})
            optional_files = sorted({snippet["file"] for snippet in optional_snippets})
            claimed_impact = build_packet_claimed_impact(
                finding_summary=finding,
                raw_finding=raw_finding,
                aggregate=aggregate,
                focus_file=focus_file,
                focus_anchor=focus_anchor,
            )
            sink_semantics = classify_sink_semantics(
                sink_function=optional_string((raw_finding or {}).get("sink_function")),
                sink_anchor=sink_anchor,
                claimed_impact=claimed_impact,
            )

            packet = {
                "packet_id": packet_id,
                "parent_finding_id": finding_id,
                "packet_kind": "atomic_surface" if aggregate else "base",
                "focus_anchor": focus_anchor,
                "finding_id": finding_id,
                "verdict": finding.get("verdict"),
                "vuln_type": packet_vuln_type,
                "severity": finding.get("severity"),
                "auth_required": finding.get("auth_required"),
                "confidence": finding.get("confidence"),
                "entry_point_id": entry_point_id,
                "patchstack_eligible": finding.get("patchstack_eligible"),
                "claimed_impact": claimed_impact,
                "worker_context": build_packet_worker_context(
                    raw_finding=raw_finding,
                    aggregate=aggregate,
                    focus_file=focus_file,
                    focus_anchor=focus_anchor,
                    grouped_items=grouped_items,
                    entry_point_anchor=entry_point_anchor,
                    primary_files=primary_files,
                    sink_semantics=sink_semantics,
                ),
                "review_focus": build_review_focus(
                    packet_kind="atomic_surface" if aggregate else "base",
                    focus_file=focus_file,
                    focus_anchor=focus_anchor,
                    entry_point_anchor=entry_point_anchor,
                    primary_files=primary_files,
                    optional_files=optional_files,
                    sink_semantics=sink_semantics,
                ),
                "scope_policy": {
                    "allowed_primary_files": primary_files,
                    "allowed_optional_files": optional_files,
                    "max_out_of_band_files": 1,
                },
                "anchors": {
                    "entry_point_anchor": entry_point_anchor,
                    "source_anchor": source_anchor,
                    "sink_anchor": sink_anchor,
                    "review_anchor_candidates": grouped_items,
                },
                "primary_files": primary_files,
                "primary_snippets": primary_snippets,
                "optional_files": optional_files,
                "optional_snippets": optional_snippets,
                "review_questions": build_review_questions(
                    {
                        **finding,
                        "vuln_type": packet_vuln_type,
                        "source_anchor": source_anchor,
                        "sink_anchor": sink_anchor,
                    },
                    entry_point_anchor,
                ),
            }
            packets.append(packet)

    return packets


def build_reviewer_input(
    *,
    root: Path,
    slug: str,
    review_round: int,
    review_mode: str,
    worker_output_path: Path,
    review_output_path: Path,
    input_output_path: Path,
    max_candidates: int | None = None,
    threat_context_path: Path | None = None,
    source_review_path: Path | None = None,
) -> dict:
    review_mode = normalize_review_mode(review_mode)
    reports_dir = root / "reports"
    worker_output = load_json(worker_output_path)
    ir_path = reports_dir / "phase1" / f"{slug}-ir.json"
    ir_doc = load_json(ir_path)

    semgrep_path = reports_dir / "phase1" / f"{slug}-semgrep.json"
    psalm_path = reports_dir / "phase1" / f"{slug}-psalm.sarif"

    threat_doc = None
    if threat_context_path and threat_context_path.exists():
        threat_doc = load_json(threat_context_path)

    findings_summary, related_entry_point_ids = summarize_worker_findings(worker_output)
    raw_findings = worker_findings_by_id(worker_output)
    terminal_review_packet_ids: set[str] = set()
    terminal_review_finding_ids: set[str] = set()
    if review_mode == "terminal_core":
        if source_review_path is None or not source_review_path.exists():
            raise ValueError("terminal_core review requires an existing source review artifact")
        source_review_doc = load_json(source_review_path)
        current_review_targets = current_review_finding_targets(worker_output)
        if current_review_targets:
            terminal_review_packet_ids = set(current_review_targets)
            terminal_review_finding_ids = set(current_review_targets)
        else:
            raise ValueError("terminal_core review has no current REVIEW findings to close")
        if not terminal_review_packet_ids and not terminal_review_finding_ids:
            raise ValueError("terminal_core review has no unresolved packets to close")
        findings_summary = [
            item for item in findings_summary
            if optional_string(item.get("finding_id")) in terminal_review_finding_ids
        ]
        related_entry_point_ids = {
            optional_string(item.get("entry_point_id"))
            for item in findings_summary
            if optional_string(item.get("entry_point_id"))
        }
    if review_mode in {"core", "terminal_core"}:
        goal = "Challenge the worker output packet-by-packet with concrete counter-evidence, field corrections, and explicit missing-evidence notes."
        constraints = [
            "Treat each finding packet as the unit of review; do not restart whole-plugin auditing.",
            "Answer reachability, authorization, dataflow, impact, and missing-evidence questions for each packet before finalizing finding_reviews.",
            "Start from finding_packets, worker_findings, and phase1_context before opening other artifacts.",
            "Refute before confirm; keep objections evidence-bound with file:line anchors.",
            "Do not rewrite the full findings set; produce critique JSON only.",
        ]
        if review_mode == "terminal_core":
            goal = "Close each surviving unresolved finding packet as TP or FP using bounded packet-local evidence, without preserving REVIEW ambiguity."
            constraints.append("Terminal core review is final-round packet closure only; do not broad-explore or relitigate already-closed packets.")
            constraints.append("You must emit one finding_reviews item per terminal packet and every item must carry closure_verdict=TP or closure_verdict=FP.")
            constraints.append("Do not emit needs_more_evidence in terminal_core mode. If exploitability is still unproven after bounded packet-local review, close the packet as FP and use missing_evidence as reopen conditions.")
            constraints.append("Do not preserve a REVIEW packet with assessment=keep unless closure_verdict=TP.")
        else:
            constraints.append("Default to packet-local critique only. Focus on finding_reviews plus field corrections for the existing finding packets.")
            constraints.append("Treat finding_packets as the reviewer core evidence pack. If packet-local evidence is insufficient, prefer needs_more_evidence over broad exploration.")
    else:
        goal = "Search for uncovered high-value candidates outside the worker's current coverage after the core review, without relitigating already-reviewed packets."
        constraints = [
            "Treat worker_findings as the current coverage map; do not rebuild packet-local core critique in this round.",
            "Start from phase1_context.top_anomalies, phase1_context.unresolved_hooks, and evidence.primary_* before opening other artifacts.",
            "Use worker_findings only to avoid duplicate coverage and to explain why a new candidate is already covered.",
            "Refute before confirm; keep objections and new candidates evidence-bound with file:line anchors.",
            "Do not rewrite the full findings set; produce critique JSON only.",
        ]
        constraints.append("Prefer uncovered-path search bounded by anomalies, unresolved hooks, threat-context priority vulns, and nearby code.")
        constraints.append("Do not regenerate or relitigate finding_packets in this round; this stage is for bounded coverage expansion only.")

    packet_phase1_context = phase1_context(ir_doc, related_entry_point_ids, review_mode)
    payload_phase1_context = dict(packet_phase1_context)
    if review_mode in {"core", "terminal_core"}:
        payload_phase1_context["top_anomalies"] = []
        payload_phase1_context["unresolved_hooks"] = []
    else:
        anomaly_cap = capped_explore_lead_count(max_candidates, MAX_TOP_ANOMALIES)
        hook_cap = capped_explore_hook_count(max_candidates, MAX_UNRESOLVED_HOOKS)
        payload_phase1_context["top_anomalies"] = payload_phase1_context["top_anomalies"][:anomaly_cap]
        payload_phase1_context["unresolved_hooks"] = payload_phase1_context["unresolved_hooks"][:hook_cap]

    output_schema_path = review_output_schema_path(root, review_mode)

    payload = {
        "plugin_slug": slug,
        "review_round": review_round,
        "review_mode": review_mode,
        "task": {
            "role": (
                "phase2_reviewer_terminal_core"
                if review_mode == "terminal_core"
                else "phase2_reviewer_core"
                if review_mode == "core"
                else "phase2_reviewer_explore"
            ),
            "goal": goal,
            "output_schema": relative_to_root(output_schema_path, root),
            "output_path": relative_to_root(review_output_path, root),
            "packet_schema": relative_to_root(root / "contracts" / "phase2-reviewer-packet.schema.json", root),
            "allow_missed_findings": review_mode == "explore",
            "constraints": constraints,
            "max_candidates": max_candidates if review_mode == "explore" else None,
        },
        "artifacts": {
            "worker_output_path": relative_to_root(worker_output_path, root),
            "ir_path": relative_to_root(ir_path, root),
            "semgrep_path": relative_to_root(semgrep_path, root) if semgrep_path.exists() else None,
            "psalm_path": relative_to_root(psalm_path, root) if psalm_path.exists() else None,
            "threat_context_path": relative_to_root(threat_context_path, root) if threat_context_path and threat_context_path.exists() else None,
            "source_root": f"plugins/{slug}",
        },
        "worker_summary": worker_summary(worker_output),
        "worker_findings": findings_summary,
        "finding_packets": [],
        "phase1_context": payload_phase1_context,
        "evidence": None,
        "threat_context_summary": threat_context_summary(threat_doc),
    }
    if review_mode in {"core", "terminal_core"}:
        payload["evidence"] = build_reviewer_evidence(
            root=root,
            slug=slug,
            findings_summary=payload["worker_findings"],
            related_entry_points=packet_phase1_context["related_entry_points"],
            top_anomalies=packet_phase1_context["top_anomalies"],
            unresolved_hooks=packet_phase1_context["unresolved_hooks"],
            include_optional_evidence=False,
        )
        payload["finding_packets"] = build_finding_packets(
            root=root,
            slug=slug,
            findings_summary=payload["worker_findings"],
            raw_findings=raw_findings,
            related_entry_points=packet_phase1_context["related_entry_points"],
            top_anomalies=packet_phase1_context["top_anomalies"],
            unresolved_hooks=packet_phase1_context["unresolved_hooks"],
        )
        if review_mode == "terminal_core":
            payload["finding_packets"] = [
                item for item in payload["finding_packets"]
                if optional_string(item.get("packet_id")) in terminal_review_packet_ids
                or optional_string(item.get("parent_finding_id")) in terminal_review_finding_ids
            ]
            finding_ids_in_packets = {
                optional_string(item.get("parent_finding_id"))
                for item in payload["finding_packets"]
                if optional_string(item.get("parent_finding_id"))
            }
            payload["worker_findings"] = [
                item for item in payload["worker_findings"]
                if optional_string(item.get("finding_id")) in finding_ids_in_packets
            ]
            payload["worker_summary"] = summarized_worker_summary(payload["worker_findings"], worker_output)
            if not payload["finding_packets"]:
                raise ValueError("terminal_core review built no unresolved packets")
    else:
        payload["evidence"] = build_explore_evidence(
            root=root,
            slug=slug,
            findings_summary=payload["worker_findings"],
            related_entry_points=packet_phase1_context["related_entry_points"],
            top_anomalies=payload_phase1_context["top_anomalies"],
            unresolved_hooks=payload_phase1_context["unresolved_hooks"],
            max_candidates=max_candidates,
        )
        payload["finding_packets"] = []

    schema = load_json(root / "contracts" / "phase2-reviewer-input.schema.json")
    jsonschema.validate(instance=payload, schema=schema)
    input_output_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build JSON-first reviewer input for Phase 2 review rounds.")
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--round", type=int, required=True, help="Review round number")
    parser.add_argument("--review-mode", choices=["core", "terminal_core", "explore", "skeptical", "forced_exploration"], required=True)
    parser.add_argument("--worker-output", required=True, help="Path to worker output JSON")
    parser.add_argument("--review-output", required=True, help="Path to review output JSON")
    parser.add_argument("--output", required=True, help="Path to reviewer input JSON")
    parser.add_argument("--source-review", default=None, help="Optional prior review JSON path for terminal_core mode")
    parser.add_argument("--threat-context", default=None, help="Optional threat context JSON path")
    parser.add_argument("--max-candidates", type=int, default=None, help="Exploration candidate cap")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = find_project_root()
    build_reviewer_input(
        root=root,
        slug=args.slug,
        review_round=args.round,
        review_mode=args.review_mode,
        worker_output_path=Path(args.worker_output),
        review_output_path=Path(args.review_output),
        input_output_path=Path(args.output),
        max_candidates=args.max_candidates,
        threat_context_path=Path(args.threat_context) if args.threat_context else None,
        source_review_path=Path(args.source_review) if args.source_review else None,
    )
    print(f"[OK] Reviewer input written: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
