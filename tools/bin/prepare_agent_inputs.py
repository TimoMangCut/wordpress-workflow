#!/usr/bin/env python3
"""
prepare_agent_inputs.py — candidate-based multi-agent prep

New behaviour:
- normalizes IR / Semgrep / Psalm signals into candidate hypotheses
- classifies candidates by bug family, sink family, surface, auth boundary
- chunks candidates into bounded worker bundles for multi-agent Phase 2
- writes prep artifacts under reports/phase2/prep/<slug>/
- dispatch now prefers dynamic worker agents (agent-wNN) and can optionally
  include legacy support agents (agent-b/c/d)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

import jsonschema

try:
    from .phase2_dispatch_manifest import (
        build_dispatch_manifest,
        dispatch_input_entry,
        repo_relative_path,
    )
    from .report_paths import build_report_layout
except ImportError:  # pragma: no cover - direct script execution
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from phase2_dispatch_manifest import build_dispatch_manifest, dispatch_input_entry, repo_relative_path
    from report_paths import build_report_layout


EP_GROUPS = [
    ("ajax-unauth", {"ajax_nopriv", "admin_post_nopriv"}),
    ("ajax-auth", {"ajax_priv", "admin_post"}),
    ("rest", {"rest_route"}),
    ("shortcode", {"shortcode", "block"}),
    ("other", {"cron", "init", "template_redirect", "filters", "rest_api_init"}),
]

BUG_FAMILY_BUDGETS = {
    "authorization": {"max_candidates": 5, "max_complexity": 18},
    "state_change": {"max_candidates": 4, "max_complexity": 14},
    "xss": {"max_candidates": 6, "max_complexity": 18},
    "sqli": {"max_candidates": 4, "max_complexity": 14},
    "file_ops": {"max_candidates": 3, "max_complexity": 12},
    "ssrf": {"max_candidates": 2, "max_complexity": 10},
    "redirect": {"max_candidates": 4, "max_complexity": 12},
    "generic": {"max_candidates": 4, "max_complexity": 10},
}

PRIORITY_WEIGHTS = {
    "authorization": 8,
    "file_ops": 7,
    "ssrf": 7,
    "sqli": 6,
    "xss": 5,
    "redirect": 4,
    "state_change": 4,
    "generic": 3,
}

SEVERITY_WEIGHTS = {"critical": 3, "high": 2, "medium": 1, "low": 0, "warning": 1}

LOW_PRIV_AUTH = {"none", "subscriber", "contributor", "author", "editor", "unknown"}
STATE_CHANGE_SINKS = {"option_update", "meta_update", "file_delete", "file_write"}
HIGH_COMPLEXITY_SINKS = {"remote_request", "include", "sql", "file_read", "file_delete", "file_write"}


def env_bool(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() not in {"0", "false", "no", "off", ""}


def load_schema(schema_file: str) -> dict:
    script_dir = Path(__file__).resolve().parent
    schema_path = (script_dir / ".." / ".." / "contracts" / schema_file).resolve()
    if not schema_path.is_file():
        sys.exit(f"ERROR: Schema not found at {schema_path}")
    with open(schema_path, encoding="utf-8") as fh:
        return json.load(fh)


def validate_slice(slice_data: dict, schema: dict, label: str) -> None:
    try:
        jsonschema.validate(instance=slice_data, schema=schema)
    except jsonschema.ValidationError as exc:
        sys.exit(
            f"ERROR: Slice '{label}' failed schema validation.\n"
            f"  Path: {list(exc.absolute_path)}\n"
            f"  Message: {exc.message}"
        )


def validate_bundle(bundle_data: dict, schema: dict, label: str) -> None:
    try:
        jsonschema.validate(instance=bundle_data, schema=schema)
    except jsonschema.ValidationError as exc:
        sys.exit(
            f"ERROR: Candidate bundle '{label}' failed schema validation.\n"
            f"  Path: {list(exc.absolute_path)}\n"
            f"  Message: {exc.message}"
        )


def write_json(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path) if os.path.dirname(path) else ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def plugin_relative_path(path: str | None, slug: str) -> str:
    if not path:
        return ""
    marker = f"plugins/{slug}/"
    idx = path.find(marker)
    if idx != -1:
        return path[idx + len(marker):]
    return path.lstrip("./")


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "-", (value or "").lower()).strip("-")
    return slug or "generic"


def auth_bucket(auth_level: str | None) -> str:
    auth = (auth_level or "unknown").lower()
    if auth in {"none", "unknown"}:
        return auth
    if auth in {"subscriber", "contributor", "author", "editor"}:
        return "low-priv"
    return "admin+"


def severity_to_weight(severity: str | None) -> int:
    return SEVERITY_WEIGHTS.get((severity or "").lower(), 0)


def semgrep_bug_family(result: dict) -> str:
    check_id = (result.get("check_id") or "").lower()
    message = (result.get("extra", {}).get("message") or "").lower()
    haystack = f"{check_id} {message}"
    if "xss" in haystack or "escape" in haystack or "unescaped" in haystack:
        return "xss"
    if "sql" in haystack:
        return "sqli"
    if "ssrf" in haystack or "remote" in haystack or "curl" in haystack:
        return "ssrf"
    if "redirect" in haystack:
        return "redirect"
    if "file" in haystack or "path" in haystack or "include" in haystack:
        return "file_ops"
    if "capab" in haystack or "permission" in haystack or "nonce" in haystack:
        return "authorization"
    return "generic"


def anomaly_bug_family(anomaly: dict) -> str:
    anomaly_type = (anomaly.get("type") or "").lower()
    description = (anomaly.get("description") or "").lower()
    haystack = f"{anomaly_type} {description}"
    if "return_true" in haystack or "permission" in haystack or "capab" in haystack or "nonce" in haystack:
        return "authorization"
    if "sql" in haystack:
        return "sqli"
    if "xss" in haystack or "output" in haystack:
        return "xss"
    if "redirect" in haystack:
        return "redirect"
    if "file" in haystack or "include" in haystack or "path" in haystack:
        return "file_ops"
    if "remote" in haystack or "http" in haystack:
        return "ssrf"
    return "generic"


def sink_bug_family(entry_point: dict, sink: dict, anomalies: list[dict]) -> str:
    category = (sink.get("category") or "").lower()
    auth = (entry_point.get("auth_level") or "unknown").lower()
    anomaly_families = {anomaly_bug_family(a) for a in anomalies}
    if "authorization" in anomaly_families:
        return "authorization"
    if category in {"sql"}:
        return "sqli"
    if category in {"output", "output_return"}:
        return "xss"
    if category in {"remote_request"}:
        return "ssrf"
    if category in {"redirect"}:
        return "redirect"
    if category in {"file_read", "file_delete", "file_write", "include"}:
        return "file_ops"
    if category in STATE_CHANGE_SINKS and auth in LOW_PRIV_AUTH:
        return "authorization"
    if category in {"option_update", "meta_update"}:
        return "state_change"
    return "generic"


def normalize_semgrep_results(semgrep: dict, slug: str) -> list[dict]:
    hits = []
    for idx, result in enumerate(semgrep.get("results", [])):
        rel_path = plugin_relative_path(result.get("path"), slug)
        if not rel_path:
            continue
        extra = result.get("extra", {})
        fingerprint = extra.get("fingerprint") or f"semgrep-{idx}"
        hits.append(
            {
                "key": fingerprint,
                "path": rel_path,
                "line": result.get("start", {}).get("line"),
                "check_id": result.get("check_id"),
                "message": extra.get("message"),
                "severity": extra.get("severity") or result.get("severity"),
                "bug_family": semgrep_bug_family(result),
            }
        )
    return hits


def normalize_psalm_results(psalm_data: dict, slug: str) -> list[dict]:
    normalized = []
    for run in psalm_data.get("runs", []):
        for idx, result in enumerate(run.get("results", [])):
            locations = result.get("locations", [])
            if not locations:
                continue
            physical = locations[0].get("physicalLocation", {})
            artifact = physical.get("artifactLocation", {})
            rel_path = plugin_relative_path(artifact.get("uri"), slug)
            if not rel_path:
                continue
            rule_id = result.get("ruleId") or f"psalm-{idx}"
            message = result.get("message", {}).get("text")
            normalized.append(
                {
                    "key": f"{rule_id}:{rel_path}:{physical.get('region', {}).get('startLine', 0)}",
                    "path": rel_path,
                    "line": physical.get("region", {}).get("startLine"),
                    "rule_id": rule_id,
                    "message": message,
                    "level": result.get("level"),
                    "bug_family": semgrep_bug_family({"check_id": rule_id, "extra": {"message": message or ""}}),
                }
            )
    return normalized


def slice_ir_for_group(ir: dict, ep_types: set) -> dict:
    eps = [ep for ep in ir["entry_points"] if ep["type"] in ep_types]
    ep_ids = {ep["id"] for ep in eps}
    return {
        "metadata": ir["metadata"],
        "entry_points": eps,
        "sources": [s for s in ir["sources"] if s.get("entry_point_id") in ep_ids],
        "sinks": [s for s in ir["sinks"] if s.get("entry_point_id") in ep_ids],
        "guards": [g for g in ir["guards"] if g.get("entry_point_id") in ep_ids],
        "anomalies": [a for a in ir["anomalies"] if a.get("entry_point_id") in ep_ids],
        "unresolved_hooks": [],
        "coverage_gaps": [],
    }


def filter_semgrep_for_group(semgrep: dict, ep_files: set, slug: str) -> dict:
    filtered_results = [
        r for r in semgrep.get("results", [])
        if plugin_relative_path(r.get("path", ""), slug) in ep_files
    ]
    return {**semgrep, "results": filtered_results}


def compute_complexity(sink_category: str, source_count: int, guard_count: int, anomaly_count: int, corroboration_count: int, auth_level: str) -> int:
    score = 1
    score += min(source_count, 2)
    score += 1 if guard_count else 0
    score += 1 if anomaly_count else 0
    score += 1 if corroboration_count else 0
    score += 1 if sink_category in HIGH_COMPLEXITY_SINKS else 0
    score += 1 if auth_bucket(auth_level) == "unknown" else 0
    return min(score, 6)


def compute_priority(bug_family: str, auth_level: str, anomaly_severities: list[str], corroboration_count: int, surface: str) -> int:
    score = PRIORITY_WEIGHTS.get(bug_family, PRIORITY_WEIGHTS["generic"])
    if (auth_level or "unknown").lower() in {"none", "unknown"}:
        score += 2
    elif (auth_level or "").lower() in {"subscriber", "contributor", "author", "editor"}:
        score += 1
    score += sum(severity_to_weight(sev) for sev in anomaly_severities[:2])
    score += min(corroboration_count, 2)
    if surface in {"rest_route", "ajax_nopriv", "admin_post_nopriv"}:
        score += 1
    return score


def build_candidate(
    *,
    candidate_id: str,
    kind: str,
    bug_family: str,
    sink_family: str,
    surface: str,
    auth_level: str,
    complexity_score: int,
    priority_score: int,
    rationale: str,
    entry_point_ids: list[str],
    sink_ids: list[str],
    anomaly_ids: list[str],
    semgrep_keys: list[str],
    psalm_keys: list[str],
    source_focus_files: list[str],
) -> dict:
    return {
        "candidate_id": candidate_id,
        "kind": kind,
        "bug_family": bug_family,
        "sink_family": sink_family,
        "surface": surface,
        "auth_boundary": (auth_level or "unknown").lower(),
        "complexity_score": complexity_score,
        "priority_score": priority_score,
        "entry_point_ids": entry_point_ids,
        "sink_ids": sink_ids,
        "anomaly_ids": anomaly_ids,
        "semgrep_keys": semgrep_keys,
        "psalm_keys": psalm_keys,
        "source_focus_files": source_focus_files,
        "rationale": rationale,
    }


def build_candidates(ir: dict, semgrep_hits: list[dict], psalm_hits: list[dict]) -> list[dict]:
    ep_index = {ep["id"]: ep for ep in ir.get("entry_points", [])}
    sources_by_ep = defaultdict(list)
    sinks_by_ep = defaultdict(list)
    guards_by_ep = defaultdict(list)
    anomalies_by_ep = defaultdict(list)
    semgrep_by_file = defaultdict(list)
    psalm_by_file = defaultdict(list)

    for item in ir.get("sources", []):
        sources_by_ep[item.get("entry_point_id")].append(item)
    for item in ir.get("sinks", []):
        sinks_by_ep[item.get("entry_point_id")].append(item)
    for item in ir.get("guards", []):
        guards_by_ep[item.get("entry_point_id")].append(item)
    for item in ir.get("anomalies", []):
        anomalies_by_ep[item.get("entry_point_id")].append(item)
    for hit in semgrep_hits:
        semgrep_by_file[hit["path"]].append(hit)
    for hit in psalm_hits:
        psalm_by_file[hit["path"]].append(hit)

    candidates = []
    used_semgrep = set()
    used_psalm = set()

    for ep in ir.get("entry_points", []):
        ep_id = ep["id"]
        ep_identity = slugify(f"{ep_id}-{ep.get('file') or (ep.get('callback') or {}).get('file') or 'unknown'}")
        ep_sources = sources_by_ep.get(ep_id, [])
        ep_sinks = sinks_by_ep.get(ep_id, [])
        ep_guards = guards_by_ep.get(ep_id, [])
        ep_anomalies = anomalies_by_ep.get(ep_id, [])
        ep_files = {
            path
            for path in [
                ep.get("file"),
                (ep.get("callback") or {}).get("file"),
                *[s.get("file") for s in ep_sources],
            ]
            if path
        }

        if ep_sinks:
            grouped_sinks = defaultdict(list)
            for sink in ep_sinks:
                bug_family = sink_bug_family(ep, sink, ep_anomalies)
                sink_family = (sink.get("category") or "unknown").lower()
                grouped_sinks[(bug_family, sink_family)].append(sink)

            for (bug_family, sink_family), sink_group in grouped_sinks.items():
                source_focus_files = {
                    *ep_files,
                    *[sink.get("file") for sink in sink_group],
                    *[(anom.get("evidence") or {}).get("file") for anom in ep_anomalies],
                }
                source_focus_files = sorted(path for path in source_focus_files if path)
                semgrep_matches = [hit for path in source_focus_files for hit in semgrep_by_file.get(path, [])]
                psalm_matches = [hit for path in source_focus_files for hit in psalm_by_file.get(path, [])]
                used_semgrep.update(hit["key"] for hit in semgrep_matches)
                used_psalm.update(hit["key"] for hit in psalm_matches)
                complexity = compute_complexity(
                    sink_family,
                    len(ep_sources),
                    len(ep_guards),
                    len(ep_anomalies),
                    len(semgrep_matches) + len(psalm_matches) + min(len(sink_group), 2),
                    ep.get("auth_level") or "unknown",
                )
                priority = compute_priority(
                    bug_family,
                    ep.get("auth_level") or "unknown",
                    [(anom.get("severity") or "").lower() for anom in ep_anomalies],
                    len(semgrep_matches) + len(psalm_matches) + min(len(sink_group), 1),
                    ep.get("type") or "unknown",
                )
                group_suffix = slugify(f"{sink_family}-{len(sink_group)}")
                candidates.append(
                    build_candidate(
                        candidate_id=f"cand-{ep_identity}-{group_suffix}",
                        kind="ir_sink",
                        bug_family=bug_family,
                        sink_family=sink_family,
                        surface=ep.get("type") or "unknown",
                        auth_level=ep.get("auth_level") or "unknown",
                        complexity_score=complexity,
                        priority_score=priority,
                        rationale=f"IR sink-cluster hypothesis across {len(sink_group)} sink(s) in the same entry point/family.",
                        entry_point_ids=[ep_id],
                        sink_ids=[sink.get("id") for sink in sink_group if sink.get("id")],
                        anomaly_ids=[a.get("id") for a in ep_anomalies if a.get("id")],
                        semgrep_keys=[hit["key"] for hit in semgrep_matches],
                        psalm_keys=[hit["key"] for hit in psalm_matches],
                        source_focus_files=source_focus_files,
                    )
                )
        elif ep_anomalies:
            source_focus_files = sorted(
                {
                    *ep_files,
                    *[(anom.get("evidence") or {}).get("file") for anom in ep_anomalies],
                }
                - {None, ""}
            )
            semgrep_matches = [hit for path in source_focus_files for hit in semgrep_by_file.get(path, [])]
            psalm_matches = [hit for path in source_focus_files for hit in psalm_by_file.get(path, [])]
            used_semgrep.update(hit["key"] for hit in semgrep_matches)
            used_psalm.update(hit["key"] for hit in psalm_matches)
            family = anomaly_bug_family(ep_anomalies[0])
            candidates.append(
                build_candidate(
                    candidate_id=f"cand-{ep_identity}-anomaly",
                    kind="ir_anomaly",
                    bug_family=family,
                    sink_family=(ep_anomalies[0].get("type") or "anomaly").lower(),
                    surface=ep.get("type") or "unknown",
                    auth_level=ep.get("auth_level") or "unknown",
                    complexity_score=compute_complexity(
                        "anomaly",
                        len(ep_sources),
                        len(ep_guards),
                        len(ep_anomalies),
                        len(semgrep_matches) + len(psalm_matches),
                        ep.get("auth_level") or "unknown",
                    ),
                    priority_score=compute_priority(
                        family,
                        ep.get("auth_level") or "unknown",
                        [(anom.get("severity") or "").lower() for anom in ep_anomalies],
                        len(semgrep_matches) + len(psalm_matches),
                        ep.get("type") or "unknown",
                    ),
                    rationale="High-signal IR anomaly without direct sink mapping.",
                    entry_point_ids=[ep_id],
                    sink_ids=[],
                    anomaly_ids=[a.get("id") for a in ep_anomalies if a.get("id")],
                    semgrep_keys=[hit["key"] for hit in semgrep_matches],
                    psalm_keys=[hit["key"] for hit in psalm_matches],
                    source_focus_files=source_focus_files,
                )
            )
        else:
            source_focus_files = sorted(ep_files)
            semgrep_matches = [hit for path in source_focus_files for hit in semgrep_by_file.get(path, [])]
            psalm_matches = [hit for path in source_focus_files for hit in psalm_by_file.get(path, [])]
            used_semgrep.update(hit["key"] for hit in semgrep_matches)
            used_psalm.update(hit["key"] for hit in psalm_matches)
            bug_family = semgrep_matches[0]["bug_family"] if semgrep_matches else "generic"
            sink_family = semgrep_matches[0]["check_id"] if semgrep_matches else "recon"
            candidates.append(
                build_candidate(
                    candidate_id=f"cand-{ep_identity}-recon",
                    kind="entry_point_recon",
                    bug_family=bug_family,
                    sink_family=slugify(sink_family),
                    surface=ep.get("type") or "unknown",
                    auth_level=ep.get("auth_level") or "unknown",
                    complexity_score=compute_complexity(
                        "recon",
                        len(ep_sources),
                        len(ep_guards),
                        0,
                        len(semgrep_matches) + len(psalm_matches),
                        ep.get("auth_level") or "unknown",
                    ),
                    priority_score=compute_priority(
                        bug_family,
                        ep.get("auth_level") or "unknown",
                        [],
                        len(semgrep_matches) + len(psalm_matches),
                        ep.get("type") or "unknown",
                    ),
                    rationale="Low-signal entry point kept for coverage to avoid blind spots.",
                    entry_point_ids=[ep_id],
                    sink_ids=[],
                    anomaly_ids=[],
                    semgrep_keys=[hit["key"] for hit in semgrep_matches],
                    psalm_keys=[hit["key"] for hit in psalm_matches],
                    source_focus_files=source_focus_files,
                )
            )

    orphan_semgrep_groups = defaultdict(list)
    for hit in semgrep_hits:
        if hit["key"] not in used_semgrep:
            orphan_semgrep_groups[(hit["path"], hit["bug_family"])].append(hit)
    for (path, bug_family), hits in orphan_semgrep_groups.items():
        candidates.append(
            build_candidate(
                candidate_id=f"cand-sg-{slugify(path)}-{bug_family}",
                kind="semgrep_orphan",
                bug_family=bug_family,
                sink_family=slugify(hits[0]["check_id"] or "semgrep"),
                surface="unknown",
                auth_level="unknown",
                complexity_score=min(1 + len(hits), 4),
                priority_score=PRIORITY_WEIGHTS.get(bug_family, 3) + min(len(hits), 2),
                rationale="Semgrep-only security signal not yet covered by IR-linked candidates.",
                entry_point_ids=[],
                sink_ids=[],
                anomaly_ids=[],
                semgrep_keys=[hit["key"] for hit in hits],
                psalm_keys=[],
                source_focus_files=[path],
            )
        )

    orphan_psalm_groups = defaultdict(list)
    for hit in psalm_hits:
        if hit["key"] not in used_psalm:
            orphan_psalm_groups[(hit["path"], hit["bug_family"])].append(hit)
    for (path, bug_family), hits in orphan_psalm_groups.items():
        candidates.append(
            build_candidate(
                candidate_id=f"cand-psalm-{slugify(path)}-{bug_family}",
                kind="psalm_orphan",
                bug_family=bug_family,
                sink_family=slugify(hits[0]["rule_id"] or "psalm"),
                surface="unknown",
                auth_level="unknown",
                complexity_score=min(1 + len(hits), 4),
                priority_score=PRIORITY_WEIGHTS.get(bug_family, 3) + min(len(hits), 1),
                rationale="Psalm-only corroboration signal not yet covered by IR-linked candidates.",
                entry_point_ids=[],
                sink_ids=[],
                anomaly_ids=[],
                semgrep_keys=[],
                psalm_keys=[hit["key"] for hit in hits],
                source_focus_files=[path],
            )
        )

    candidates.sort(key=lambda c: (-c["priority_score"], -c["complexity_score"], c["candidate_id"]))
    return candidates


def candidate_stream_key(candidate: dict) -> tuple:
    return (
        candidate.get("bug_family") or "generic",
        candidate.get("surface") or "unknown",
        auth_bucket(candidate.get("auth_boundary") or "unknown"),
    )


def budget_for_candidate(candidate: dict) -> dict:
    return BUG_FAMILY_BUDGETS.get(candidate.get("bug_family"), BUG_FAMILY_BUDGETS["generic"])


def packing_profile(total_candidates: int) -> str:
    if total_candidates >= 240:
        return "high-volume"
    if total_candidates >= 120:
        return "medium-volume"
    return "default"


def scaled_bundle_budget(candidate: dict, total_candidates: int, stream_size: int) -> dict:
    budget = dict(budget_for_candidate(candidate))
    profile = packing_profile(total_candidates)
    bug_family = candidate.get("bug_family") or "generic"

    if profile == "medium-volume":
        budget["max_candidates"] += 1
        budget["max_complexity"] += 4
    elif profile == "high-volume":
        budget["max_candidates"] += 2
        budget["max_complexity"] += 6

    if bug_family == "generic":
        if profile == "medium-volume":
            budget["max_candidates"] += 2
            budget["max_complexity"] += 6
        elif profile == "high-volume":
            budget["max_candidates"] += 4
            budget["max_complexity"] += 10
    elif bug_family in {"authorization", "xss"} and profile == "high-volume":
        budget["max_candidates"] += 2
        budget["max_complexity"] += 6

    if stream_size >= 24:
        budget["max_candidates"] += 2
        budget["max_complexity"] += 6
    elif stream_size >= 12:
        budget["max_candidates"] += 1
        budget["max_complexity"] += 3

    if bug_family == "generic":
        budget["max_candidates"] = min(budget["max_candidates"], 12)
        budget["max_complexity"] = min(budget["max_complexity"], 32)
    elif bug_family in {"authorization", "xss"}:
        budget["max_candidates"] = min(budget["max_candidates"], 10)
        budget["max_complexity"] = min(budget["max_complexity"], 30)
    else:
        budget["max_candidates"] = min(budget["max_candidates"], 8)
        budget["max_complexity"] = min(budget["max_complexity"], 24)

    return budget


def pack_candidate_bundles(candidates: list[dict]) -> list[dict]:
    streams = defaultdict(list)
    for candidate in candidates:
        streams[candidate_stream_key(candidate)].append(candidate)

    ordered_streams = sorted(
        streams.items(),
        key=lambda item: (
            -max(c["priority_score"] for c in item[1]),
            item[0][0],
            item[0][1],
            item[0][2],
        ),
    )

    bundles = []
    total_candidates = len(candidates)
    stream_bundle_queues = []
    for (bug_family, surface, auth), stream_candidates in ordered_streams:
        current = []
        complexity_used = 0
        budget = scaled_bundle_budget(stream_candidates[0], total_candidates, len(stream_candidates))
        stream_bundles = []
        for candidate in stream_candidates:
            candidate_cost = max(1, int(candidate.get("complexity_score", 1)))
            exceeds_count = len(current) >= budget["max_candidates"]
            exceeds_complexity = current and complexity_used + candidate_cost > budget["max_complexity"]
            if exceeds_count or exceeds_complexity:
                stream_bundles.append(
                    {
                        "bug_family": bug_family,
                        "primary_surface": surface,
                        "auth_boundary": auth,
                        "candidates": current,
                        "budget": budget,
                    }
                )
                current = []
                complexity_used = 0
            current.append(candidate)
            complexity_used += candidate_cost
        if current:
            stream_bundles.append(
                {
                    "bug_family": bug_family,
                    "primary_surface": surface,
                    "auth_boundary": auth,
                    "candidates": current,
                    "budget": budget,
                }
            )
        if stream_bundles:
            stream_bundle_queues.append(stream_bundles)

    bundle_index = 1
    while any(stream_bundle_queues):
        next_round = []
        for queue in stream_bundle_queues:
            if not queue:
                continue
            bundle = queue.pop(0)
            bundle["agent_id"] = f"agent-w{bundle_index:02d}"
            bundle["bundle_id"] = f"bundle-w{bundle_index:02d}"
            bundles.append(bundle)
            bundle_index += 1
            if queue:
                next_round.append(queue)
        stream_bundle_queues = next_round
    return bundles


def build_bundle_document(bundle: dict, ir: dict, semgrep_hits: list[dict], psalm_hits: list[dict]) -> dict:
    semgrep_by_key = {hit["key"]: hit for hit in semgrep_hits}
    psalm_by_key = {hit["key"]: hit for hit in psalm_hits}
    ep_ids = {ep_id for candidate in bundle["candidates"] for ep_id in candidate.get("entry_point_ids", [])}
    sink_ids = {sink_id for candidate in bundle["candidates"] for sink_id in candidate.get("sink_ids", [])}
    anomaly_ids = {anom_id for candidate in bundle["candidates"] for anom_id in candidate.get("anomaly_ids", [])}
    semgrep_keys = {key for candidate in bundle["candidates"] for key in candidate.get("semgrep_keys", [])}
    psalm_keys = {key for candidate in bundle["candidates"] for key in candidate.get("psalm_keys", [])}
    source_focus_files = sorted({path for candidate in bundle["candidates"] for path in candidate.get("source_focus_files", [])})

    entry_points = [ep for ep in ir.get("entry_points", []) if ep.get("id") in ep_ids]
    sources = [src for src in ir.get("sources", []) if src.get("entry_point_id") in ep_ids]
    guards = [guard for guard in ir.get("guards", []) if guard.get("entry_point_id") in ep_ids]
    sinks = [
        sink
        for sink in ir.get("sinks", [])
        if sink.get("entry_point_id") in ep_ids and (not sink_ids or sink.get("id") in sink_ids or sink.get("file") in source_focus_files)
    ]
    anomalies = [
        anomaly
        for anomaly in ir.get("anomalies", [])
        if anomaly.get("entry_point_id") in ep_ids or anomaly.get("id") in anomaly_ids
    ]

    return {
        "metadata": ir.get("metadata", {}),
        "bundle": {
            "bundle_id": bundle["bundle_id"],
            "agent_id": bundle["agent_id"],
            "worker_strategy": "candidate_chunk_v2",
            "bug_family": bundle["bug_family"],
            "primary_surface": bundle["primary_surface"],
            "auth_boundary": bundle["auth_boundary"],
            "candidate_count": len(bundle["candidates"]),
            "complexity_budget": sum(int(candidate.get("complexity_score", 1)) for candidate in bundle["candidates"]),
            "max_candidate_complexity": max(int(candidate.get("complexity_score", 1)) for candidate in bundle["candidates"]),
        },
        "candidate_hypotheses": bundle["candidates"],
        "entry_points": entry_points,
        "sources": sources,
        "sinks": sinks,
        "guards": guards,
        "anomalies": anomalies,
        "unresolved_hooks": [],
        "coverage_gaps": [],
        "semgrep_results": [semgrep_by_key[key] for key in sorted(semgrep_keys) if key in semgrep_by_key],
        "psalm_results": [psalm_by_key[key] for key in sorted(psalm_keys) if key in psalm_by_key],
        "source_focus_files": source_focus_files,
    }


def remove_stale_candidate_bundles(bundle_dir: Path) -> None:
    for path in bundle_dir.glob("agent-w*.input.json"):
        try:
            path.unlink()
        except OSError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Prepare multi-agent Phase 2 inputs with candidate-based chunking."
    )
    parser.add_argument("slug", nargs="?", help="Plugin slug shorthand (uses reports/phase1/<slug>-*.json and writes into reports/phase2/prep/<slug>/)")
    parser.add_argument("--ir", help="Path to <slug>-ir.json")
    parser.add_argument("--semgrep", help="Path to <slug>-semgrep.json (missing path falls back to empty results)")
    parser.add_argument("--psalm", help="Path to <slug>-psalm.sarif (missing path falls back to empty results)")
    parser.add_argument("--output-dir", dest="output_dir", help="Directory to write output files into")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent.parent

    if args.slug:
        phase1_dir = root_dir / "reports" / "phase1"
        args.ir = args.ir or str(phase1_dir / f"{args.slug}-ir.json")
        args.semgrep = args.semgrep or str(phase1_dir / f"{args.slug}-semgrep.json")
        args.psalm = args.psalm or str(phase1_dir / f"{args.slug}-psalm.sarif")
        args.output_dir = args.output_dir or str(root_dir / "reports")

    if not args.ir or not args.semgrep or not args.output_dir:
        parser.error("Provide either <slug> shorthand or all of --ir, --semgrep, and --output-dir")

    if not os.path.isfile(args.ir):
        sys.exit(f"ERROR: IR file not found: {args.ir}")

    with open(args.ir, encoding="utf-8") as fh:
        ir = json.load(fh)

    semgrep_missing = not os.path.isfile(args.semgrep)
    if semgrep_missing:
        semgrep = {"results": []}
    else:
        with open(args.semgrep, encoding="utf-8") as fh:
            semgrep = json.load(fh)

    psalm_missing = not args.psalm or not os.path.isfile(args.psalm)
    if psalm_missing:
        psalm_data = {"runs": []}
    else:
        with open(args.psalm, encoding="utf-8") as fh:
            psalm_data = json.load(fh)

    reports_root = Path(args.output_dir).resolve()
    layout = build_report_layout(reports_root).ensure()

    slug = ir["metadata"]["plugin_slug"]
    prep_dir = layout.phase2_prep(slug)
    bundle_dir = layout.phase2_prep_candidate_bundles(slug)
    legacy_slices_dir = layout.phase2_prep_legacy_slices(slug)
    agents_dir = layout.phase2_agents(slug)
    for path in (prep_dir, bundle_dir, legacy_slices_dir, agents_dir, layout.phase2_agent_attempts(slug)):
        path.mkdir(parents=True, exist_ok=True)

    ir_slice_schema = load_schema("ir-slice.schema.json")
    bundle_schema = load_schema("phase2-candidate-bundle.schema.json")
    threat_context_rel = os.path.join("reports", "context", f"{slug}-threat-context.json")

    print(
        f"IR: {args.ir} (slug={slug}, "
        f"eps={len(ir['entry_points'])}, sources={len(ir['sources'])}, "
        f"sinks={len(ir['sinks'])}, guards={len(ir['guards'])}, "
        f"anomalies={len(ir['anomalies'])})"
    )
    print(f"Semgrep: {args.semgrep} ({'missing -> using empty results' if semgrep_missing else str(len(semgrep.get('results', []))) + ' results'})")
    print(f"Psalm: {args.psalm or '(not set)'} ({'missing -> using empty results' if psalm_missing else str(sum(len(run.get('results', [])) for run in psalm_data.get('runs', []))) + ' results'})")
    print(f"Reports root: {reports_root}")
    print(f"Prep dir: {prep_dir}")
    print()

    for group_name, ep_types in EP_GROUPS:
        slice_data = slice_ir_for_group(ir, ep_types)
        validate_slice(slice_data, ir_slice_schema, group_name)

        ir_out = layout.phase2_legacy_ir_slice(slug, group_name)
        write_json(str(ir_out), slice_data)

        ep_files = set()
        for ep in slice_data["entry_points"]:
            if ep.get("file"):
                ep_files.add(ep["file"])
            cb = ep.get("callback") or {}
            if cb.get("file"):
                ep_files.add(cb["file"])

        semgrep_slice = filter_semgrep_for_group(semgrep, ep_files, slug)
        sg_out = layout.phase2_legacy_semgrep_slice(slug, group_name)
        write_json(str(sg_out), semgrep_slice)

        print(
            f"  [{group_name}] eps={len(slice_data['entry_points'])} "
            f"sources={len(slice_data['sources'])} "
            f"sinks={len(slice_data['sinks'])} "
            f"guards={len(slice_data['guards'])} "
            f"anomalies={len(slice_data['anomalies'])} "
            f"semgrep_hits={len(semgrep_slice['results'])} "
            f"→ schema OK"
        )

    normalized_semgrep = normalize_semgrep_results(semgrep, slug)
    normalized_psalm = normalize_psalm_results(psalm_data, slug)
    candidates = build_candidates(ir, normalized_semgrep, normalized_psalm)
    bundles = pack_candidate_bundles(candidates)

    profile = packing_profile(len(candidates))
    inventory = {
        "plugin_slug": slug,
        "strategy": "candidate_chunk_v2",
        "packing_profile": profile,
        "total_candidates": len(candidates),
        "total_bundles": len(bundles),
        "candidate_hypotheses": candidates,
        "bundle_plan": [
            {
                "agent_id": bundle["agent_id"],
                "bundle_id": bundle["bundle_id"],
                "bug_family": bundle["bug_family"],
                "primary_surface": bundle["primary_surface"],
                "auth_boundary": bundle["auth_boundary"],
                "candidate_ids": [candidate["candidate_id"] for candidate in bundle["candidates"]],
            }
            for bundle in bundles
        ],
    }
    inventory_out = layout.phase2_candidate_inventory(slug)
    write_json(str(inventory_out), inventory)

    remove_stale_candidate_bundles(bundle_dir)
    worker_agent_ids = []
    for bundle in bundles:
        bundle_doc = build_bundle_document(bundle, ir, normalized_semgrep, normalized_psalm)
        validate_bundle(bundle_doc, bundle_schema, bundle["bundle_id"])
        bundle_out = layout.phase2_candidate_bundle(slug, bundle["agent_id"])
        write_json(str(bundle_out), bundle_doc)
        worker_agent_ids.append(bundle["agent_id"])
        print(
            f"  [bundle {bundle['agent_id']}] family={bundle['bug_family']} "
            f"surface={bundle['primary_surface']} auth={bundle['auth_boundary']} "
            f"candidates={len(bundle['candidates'])}"
        )

    print()
    print(f"Done. Wrote {len(EP_GROUPS) * 2} legacy slice files to {legacy_slices_dir}")
    print(f"Packing profile: {profile}")
    print(f"Candidate inventory written → {inventory_out}")
    print(f"Candidate worker bundles: {len(worker_agent_ids)}")

    worker_provider = os.environ.get("PHASE2_WORKER_PROVIDER", "codex")
    if worker_provider == "codex":
        worker_model = os.environ.get("PHASE2_WORKER_CODEX_MODEL", "gpt-5.4")
    else:
        worker_model = os.environ.get("PHASE2_WORKER_CLAUDE_MODEL", "claude-sonnet-4.6")
    reviewer_provider = os.environ.get("PHASE2_REVIEWER_PROVIDER", "codex")
    reviewer_model = ""
    if reviewer_provider == "codex":
        reviewer_model = os.environ.get("PHASE2_REVIEWER_CODEX_MODEL", "gpt-5.4")
    elif reviewer_provider == "claude":
        reviewer_model = os.environ.get("PHASE2_REVIEWER_CLAUDE_MODEL", "claude-opus-4.6")
    cluster_synth_provider = os.environ.get("PHASE2_CLUSTER_SYNTH_PROVIDER", "codex")
    if cluster_synth_provider == "codex":
        cluster_synth_model = os.environ.get("PHASE2_CLUSTER_SYNTH_CODEX_MODEL", "gpt-5.4")
    else:
        cluster_synth_model = os.environ.get("PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL", "claude-sonnet-4.6")
        if "opus" in cluster_synth_model.lower():
            cluster_synth_model = "claude-sonnet-4.6"
    cluster_challenger_provider = os.environ.get("PHASE2_CLUSTER_CHALLENGER_PROVIDER", "codex")
    if cluster_challenger_provider == "codex":
        cluster_challenger_model = os.environ.get("PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL", "gpt-5.4")
    else:
        cluster_challenger_model = os.environ.get("PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL", "claude-sonnet-4.6")
        if "opus" in cluster_challenger_model.lower():
            cluster_challenger_model = "claude-sonnet-4.6"
    default_provider = os.environ.get("PHASE2_PRIMARY_PROVIDER", "codex")
    timeout_seconds = int(os.environ.get("PHASE2_PROVIDER_TIMEOUT_SECONDS", "600"))
    bundle_review_enabled = env_bool("PHASE2_BUNDLE_REVIEW_ENABLED", True)
    support_agents_enabled = env_bool("PHASE2_SUPPORT_AGENTS_ENABLED", True)
    review_rounds = int(os.environ.get("PHASE2_MAX_REVIEW_ROUNDS", "1"))
    if not bundle_review_enabled:
        review_rounds = 0

    inputs = {}
    provider_map = {}
    model_map = {}
    for agent_id in worker_agent_ids:
        inputs[agent_id] = repo_relative_path(layout.phase2_candidate_bundle(slug, agent_id), root_dir)
        provider_map[agent_id] = worker_provider
        if worker_provider == "claude" and worker_model:
            model_map[agent_id] = worker_model

    agents_list = list(worker_agent_ids)
    if support_agents_enabled:
        ir_rel = repo_relative_path(Path(args.ir).resolve(), root_dir)
        inputs["agent-b"] = ir_rel
        inputs["agent-c"] = ir_rel
        inputs["agent-d"] = ir_rel
        agents_list.extend(["agent-b", "agent-c", "agent-d"])

    dispatch = {
        "slug": slug,
        "strategy": "candidate_chunk_v2",
        "agents": agents_list,
        "inputs": inputs,
        "source_dir": f"plugins/{slug}/",
        "threat_context_path": threat_context_rel,
        "timeout_seconds": timeout_seconds,
        "quota_account": os.environ.get("CODEX_QUOTA_ACCOUNT", ""),
        "provider_map": provider_map,
        "default_provider": default_provider,
        "model_map": model_map,
        "bundle_inventory": repo_relative_path(layout.phase2_candidate_inventory(slug), root_dir),
        "agent_output_dir": repo_relative_path(layout.phase2_agents(slug), root_dir),
        "phase2_state_path": repo_relative_path(layout.phase2_state(slug), root_dir),
        "bundle_review_enabled": bundle_review_enabled,
        "support_agents_enabled": support_agents_enabled,
        "reviewer_provider": reviewer_provider,
        "reviewer_model": reviewer_model,
        "review_rounds": review_rounds,
        "cluster_synth_provider": cluster_synth_provider,
        "cluster_synth_model": cluster_synth_model,
        "cluster_challenger_provider": cluster_challenger_provider,
        "cluster_challenger_model": cluster_challenger_model,
    }
    dispatch_out = layout.phase2_dispatch(slug)
    write_json(str(dispatch_out), dispatch)
    manifest_inputs = []
    for agent_id in agents_list:
        rel_path = inputs.get(agent_id)
        if not rel_path:
            continue
        manifest_inputs.append(
            dispatch_input_entry(
                root_dir,
                agent_id,
                root_dir / rel_path,
                origin="bundle" if agent_id.startswith("agent-w") else "support_ir",
            )
        )
    manifest = build_dispatch_manifest(
        repo_root=root_dir,
        slug=slug,
        source_dir=dispatch["source_dir"],
        run_id=os.environ.get("AUDIT_RUN_ID"),
        dispatch_path=dispatch_out,
        inventory_path=inventory_out,
        ir_path=Path(args.ir).resolve(),
        semgrep_path=Path(args.semgrep).resolve() if not semgrep_missing else None,
        psalm_path=Path(args.psalm).resolve() if args.psalm else None,
        threat_context_path=((root_dir / threat_context_rel).resolve() if threat_context_rel and (root_dir / threat_context_rel).is_file() else None),
        provider_policy_path=layout.phase2_provider_policy(slug) if layout.phase2_provider_policy(slug).is_file() else None,
        dispatch_inputs=manifest_inputs,
    )
    manifest_out = layout.phase2_dispatch_manifest(slug)
    write_json(str(manifest_out), manifest)
    print(f"Dispatch config written → {dispatch_out}")
    print(f"Dispatch manifest written → {manifest_out}")
    print(f"  Support agents enabled: {support_agents_enabled}")
    print(f"  Agents ({len(agents_list)}): {', '.join(agents_list)}")


if __name__ == "__main__":
    main()
