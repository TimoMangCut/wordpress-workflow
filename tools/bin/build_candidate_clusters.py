#!/usr/bin/env python3
"""
build_candidate_clusters.py — deterministic cross-bundle cluster planning

Builds bounded cluster artifacts from merged Phase 2 findings so later LLM
stages can reason across related bundles without reopening the whole plugin.
"""

from __future__ import annotations

import argparse
import json
import os
from collections import Counter
from pathlib import Path

import jsonschema


FAMILY_MAP = {
    "broken_access_control": "authorization",
    "missing_authorization": "authorization",
    "privilege_escalation": "authorization",
    "sensitive_information_disclosure": "authorization",
    "arbitrary_options_update": "state_change",
    "arbitrary_meta_update": "state_change",
    "sql_injection": "sqli",
    "stored_xss": "xss",
    "reflected_xss": "xss",
    "dom_xss": "xss",
    "arbitrary_file_upload": "file_ops",
    "arbitrary_file_read": "file_ops",
    "arbitrary_file_delete": "file_ops",
    "arbitrary_file_write": "file_ops",
    "path_traversal": "file_ops",
    "remote_code_execution": "file_ops",
    "open_redirect": "redirect",
    "server_side_request_forgery": "ssrf",
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def find_project_root() -> Path:
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        if (candidate / "contracts").is_dir():
            return candidate
    return Path.cwd()


def load_schema(root: Path, name: str) -> dict:
    return load_json(root / "contracts" / name)


def validate(instance: dict, schema: dict, label: str) -> None:
    jsonschema.validate(instance=instance, schema=schema)


def derive_bug_family(vuln_type: str | None) -> str:
    key = (vuln_type or "").lower()
    if key in FAMILY_MAP:
        return FAMILY_MAP[key]
    if "xss" in key:
        return "xss"
    if "sql" in key:
        return "sqli"
    if "redirect" in key:
        return "redirect"
    if "file" in key or "travers" in key or "deserial" in key:
        return "file_ops"
    if "request forgery" in key or "ssrf" in key or "http" in key:
        return "ssrf"
    if "access" in key or "capab" in key or "auth" in key:
        return "authorization"
    if "option" in key or "meta" in key or "state" in key:
        return "state_change"
    return "generic"


def auth_bucket(auth_required: str | None) -> str:
    auth = (auth_required or "unknown").lower()
    if auth in {"none", "unknown"}:
        return auth
    if auth in {"subscriber", "contributor", "author", "editor"}:
        return "low-priv"
    return "admin+"


def normalized_source_agents(finding: dict, phase2_doc: dict | None = None) -> list[str]:
    agents = [str(agent) for agent in (finding.get("source_agents") or []) if str(agent)]
    if agents:
        return sorted(dict.fromkeys(agents))

    loop = (phase2_doc or {}).get("phase2_loop") or {}
    provider = (loop.get("worker_provider") or "worker").lower()
    round_id = int(loop.get("completed_worker_rounds") or 1)
    return [f"worker-r{round_id:02d}-{provider}"]


def finding_entry_ids(finding: dict) -> set[str]:
    return {
        value
        for value in [
            finding.get("entry_point_id"),
            finding.get("store_entry_point_id"),
            finding.get("load_entry_point_id"),
        ]
        if value
    }


def finding_files(finding: dict) -> set[str]:
    files = {
        value
        for value in [
            finding.get("source_file_path"),
            finding.get("sink_file_path"),
            (finding.get("fp_evidence") or {}).get("file"),
        ]
        if value
    }
    review = finding.get("phase3_review") or {}
    for item in review.get("counter_evidence", []):
        if item.get("file"):
            files.add(item["file"])
    return files


def format_anchor(path: str | None, line: int | None) -> str:
    if not path:
        return "<unknown>"
    if isinstance(line, int) and line > 0:
        return f"{path}:{line}"
    return path


def anchor_path(anchor: str | None) -> str | None:
    if not anchor or anchor == "<unknown>":
        return None
    path, sep, tail = anchor.rpartition(":")
    if sep and tail.isdigit():
        return path
    return anchor


def guard_anchors(finding: dict) -> list[str]:
    anchors: list[str] = []
    fp_evidence = finding.get("fp_evidence") or {}
    if fp_evidence.get("file"):
        anchors.append(format_anchor(fp_evidence.get("file"), fp_evidence.get("line")))

    review = finding.get("phase3_review") or {}
    for item in review.get("counter_evidence", []):
        file_path = item.get("file")
        if file_path:
            anchors.append(format_anchor(file_path, item.get("line")))

    deduped: list[str] = []
    seen: set[str] = set()
    for anchor in anchors:
        if anchor in seen:
            continue
        seen.add(anchor)
        deduped.append(anchor)
    return deduped[:6]


def shared_signal_labels(component: list[dict]) -> list[str]:
    labels: list[str] = []
    entry_sets = [finding_entry_ids(item) for item in component]
    shared_entries = set.intersection(*entry_sets) if entry_sets and all(entry_sets) else set()
    if shared_entries:
        labels.append("shared_entry_point")

    sink_paths = [item.get("sink_file_path") for item in component if item.get("sink_file_path")]
    if sink_paths and len(set(sink_paths)) == 1 and len(sink_paths) > 1:
        labels.append("shared_sink_file")

    bug_families = {derive_bug_family(item.get("vuln_type")) for item in component}
    if len(bug_families) == 1:
        labels.append("shared_bug_family")

    auth_boundaries = {auth_bucket(item.get("auth_required")) for item in component}
    if len(auth_boundaries) == 1:
        labels.append("shared_auth_boundary")

    file_sets = [finding_files(item) for item in component]
    shared_files = set.intersection(*file_sets) if file_sets and all(file_sets) else set()
    if shared_files:
        labels.append("shared_supporting_file")

    return labels or ["cross_bundle_proximity"]


def compact_finding_summary(finding: dict, cluster_meta: dict) -> dict:
    entry_ids = sorted(finding_entry_ids(finding))
    bug_family = cluster_meta["bug_family"]
    auth_boundary = cluster_meta["auth_boundary"]
    source_anchor = format_anchor(finding.get("source_file_path"), finding.get("source_line_number"))
    sink_anchor = format_anchor(finding.get("sink_file_path"), finding.get("sink_line_number"))
    local_files = sorted(finding_files(finding))
    why_parts = [bug_family]
    if entry_ids:
        why_parts.append(f"entry={entry_ids[0]}")
    if auth_boundary != "unknown":
        why_parts.append(f"auth={auth_boundary}")
    why_parts.append(f"sink={sink_anchor}")
    return {
        "finding_id": finding.get("finding_id") or "",
        "verdict": finding.get("verdict") or "",
        "vuln_type": finding.get("vuln_type") or "generic",
        "confidence": float(finding.get("confidence") or 0.0),
        "severity": finding.get("severity"),
        "auth_required": finding.get("auth_required") or "unknown",
        "entry_point_ids": entry_ids,
        "source_agents": sorted(finding.get("source_agents") or []),
        "source_anchor": source_anchor,
        "sink_anchor": sink_anchor,
        "supporting_files": local_files[:6],
        "guard_anchors": guard_anchors(finding),
        "why_this_might_connect": "; ".join(why_parts),
    }


def build_cluster_input(cluster_doc: dict) -> dict:
    cluster_meta = {
        "bug_family": cluster_doc["bug_family"],
        "auth_boundary": cluster_doc["auth_boundary"],
    }
    member_findings = [compact_finding_summary(item, cluster_meta) for item in cluster_doc.get("member_findings", [])]
    file_scores: Counter[str] = Counter()
    primary_anchor_candidates: list[str] = []
    for item in member_findings:
        for anchor in [item.get("source_anchor"), item.get("sink_anchor")]:
            if anchor and anchor != "<unknown>":
                primary_anchor_candidates.append(anchor)
                path = anchor_path(anchor)
                if path:
                    file_scores[path] += 3
        for anchor in item.get("guard_anchors", [])[:2]:
            if anchor and anchor != "<unknown>":
                primary_anchor_candidates.append(anchor)
                path = anchor_path(anchor)
                if path:
                    file_scores[path] += 1
        for path in item.get("supporting_files", []):
            file_scores[path] += 1

    supporting_files = cluster_doc.get("supporting_files", [])
    ranked_files = [path for path, _ in file_scores.most_common() if path in supporting_files]
    primary_files: list[str] = []
    for path in ranked_files:
        if path in primary_files:
            continue
        primary_files.append(path)
        if len(primary_files) >= min(3, max(1, len(supporting_files))):
            break
    if not primary_files and supporting_files:
        primary_files = supporting_files[:1]
    optional_files = [path for path in supporting_files if path not in primary_files]

    primary_anchors: list[str] = []
    seen_anchors: set[str] = set()
    for anchor in primary_anchor_candidates:
        if anchor in seen_anchors:
            continue
        path = anchor_path(anchor)
        if path and path in primary_files:
            seen_anchors.add(anchor)
            primary_anchors.append(anchor)
    if len(primary_anchors) < 4:
        for anchor in primary_anchor_candidates:
            if anchor in seen_anchors:
                continue
            seen_anchors.add(anchor)
            primary_anchors.append(anchor)
            if len(primary_anchors) >= 8:
                break

    return {
        "plugin_slug": cluster_doc["plugin_slug"],
        "cluster_id": cluster_doc["cluster_id"],
        "cluster_strategy": cluster_doc["cluster_strategy"],
        "cluster_summary": {
            "bug_family": cluster_doc["bug_family"],
            "dominant_vuln_types": cluster_doc.get("dominant_vuln_types", []),
            "auth_boundary": cluster_doc["auth_boundary"],
            "priority_score": cluster_doc["priority_score"],
            "synthesis_scope": cluster_doc.get("synthesis_scope", "single_bundle"),
            "member_count": len(member_findings),
        },
        "shared_context": {
            "entry_point_ids": cluster_doc.get("entry_point_ids", []),
            "supporting_files": supporting_files,
            "primary_files": primary_files,
            "optional_files": optional_files,
            "primary_anchors": primary_anchors[:12],
            "source_agents": cluster_doc.get("source_agents", []),
            "shared_signals": shared_signal_labels(cluster_doc.get("member_findings", [])),
        },
        "member_findings": member_findings,
        "questions_to_answer": [
            "Which member findings should remain separate because the chain between them is speculative?",
            "Which links are justified by a shared trust boundary, entry point, guard model, or sink family?",
            "What evidence is still missing before treating this cluster as one stronger claim?",
        ],
        "exploration_budget": {
            "max_optional_files": min(2, len(optional_files)),
            "max_out_of_band_files": 1,
            "max_new_links": 3,
            "max_open_questions": 3,
        },
        "constraints": [
            "Start from primary_anchors and primary_files before expanding.",
            "Use optional_files only when the primary set is insufficient.",
            "If you inspect files outside primary_files and optional_files, record them in expansion_attempts.",
            "Prefer refutation over inflation.",
            "Use only CONFIRMED, UNCERTAIN, RISK_NOTE, or REJECTED when describing mature outcomes.",
            "Do not restate the full worker reasoning prose.",
        ],
        "recommended_models": cluster_doc.get("recommended_models", {}),
    }


def link_findings(a: dict, b: dict) -> bool:
    a_entries = finding_entry_ids(a)
    b_entries = finding_entry_ids(b)
    if a_entries & b_entries:
        return True

    a_files = finding_files(a)
    b_files = finding_files(b)
    if a_files & b_files and derive_bug_family(a.get("vuln_type")) == derive_bug_family(b.get("vuln_type")):
        return True

    if (
        (a.get("sink_file_path") or "") == (b.get("sink_file_path") or "")
        and (a.get("vuln_type") or "") == (b.get("vuln_type") or "")
    ):
        return True

    a_agents = set(a.get("source_agents") or [])
    b_agents = set(b.get("source_agents") or [])
    if a_agents & b_agents:
        if derive_bug_family(a.get("vuln_type")) == derive_bug_family(b.get("vuln_type")):
            return True
        if auth_bucket(a.get("auth_required")) == auth_bucket(b.get("auth_required")) and (finding_files(a) & finding_files(b)):
            return True

    return False


def connected_components(findings: list[dict]) -> list[list[dict]]:
    if not findings:
        return []
    visited: set[int] = set()
    components: list[list[dict]] = []

    for idx in range(len(findings)):
        if idx in visited:
            continue
        queue = [idx]
        visited.add(idx)
        component = []
        while queue:
            current = queue.pop()
            component.append(findings[current])
            for other in range(len(findings)):
                if other in visited:
                    continue
                if link_findings(findings[current], findings[other]):
                    visited.add(other)
                    queue.append(other)
        components.append(component)
    return components


def resolve_model(provider: str, role: str, dispatch: dict | None = None) -> str:
    provider = (provider or "codex").lower()
    dispatch = dispatch or {}
    if provider == "codex":
        dispatch_model = dispatch.get(f"cluster_{role.lower()}_model", "")
        return dispatch_model or os.environ.get(f"PHASE2_CLUSTER_{role}_CODEX_MODEL", "gpt-5.4")
    requested = os.environ.get(f"PHASE2_CLUSTER_{role}_CLAUDE_MODEL", "claude-sonnet-4.6")
    dispatch_model = dispatch.get(f"cluster_{role.lower()}_model", "")
    if dispatch_model:
        requested = dispatch_model
    if "opus" in requested.lower():
        return "claude-sonnet-4.6"
    return requested


def summarize_cluster(component: list[dict], cluster_id: str, synth_provider: str, challenger_provider: str, dispatch: dict | None = None) -> dict:
    vuln_types = [item.get("vuln_type") or "generic" for item in component]
    bug_families = [derive_bug_family(item.get("vuln_type")) for item in component]
    auth_boundaries = [auth_bucket(item.get("auth_required")) for item in component]
    source_agents = sorted({agent for item in component for agent in (item.get("source_agents") or [])})
    entry_point_ids = sorted({ep for item in component for ep in finding_entry_ids(item)})
    supporting_files = sorted({path for item in component for path in finding_files(item)})
    family_counter = Counter(bug_families)
    auth_counter = Counter(auth_boundaries)
    vuln_counter = Counter(vuln_types)
    priority_score = sum(int(round((item.get("confidence") or 0.0) * 10)) for item in component) + len(entry_point_ids)

    return {
        "plugin_slug": component[0].get("plugin_slug") or "",
        "cluster_id": cluster_id,
        "cluster_strategy": "cross_bundle_cluster_v1",
        "bug_family": family_counter.most_common(1)[0][0] if family_counter else "generic",
        "dominant_vuln_types": [name for name, _ in vuln_counter.most_common(3)],
        "auth_boundary": auth_counter.most_common(1)[0][0] if auth_counter else "unknown",
        "entry_point_ids": entry_point_ids,
        "supporting_files": supporting_files,
        "source_agents": source_agents,
        "member_finding_ids": [item.get("finding_id") for item in component if item.get("finding_id")],
        "member_findings": component,
        "priority_score": priority_score,
        "synthesis_scope": "cross_bundle" if len(source_agents) > 1 or len(component) > 1 else "single_bundle",
        "recommended_models": {
            "synthesizer": {
                "provider": synth_provider,
                "model": resolve_model(synth_provider, "SYNTH", dispatch),
            },
            "challenger": {
                "provider": challenger_provider,
                "model": resolve_model(challenger_provider, "CHALLENGER", dispatch),
            },
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build deterministic Phase 2 clusters from merged findings.")
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--reports-dir", default=None, help="Reports directory (default: <root>/reports)")
    parser.add_argument("--phase2-json", default=None, help="Override canonical phase2 json path")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = find_project_root()
    reports_dir = Path(args.reports_dir) if args.reports_dir else (root / "reports")
    phase2_dir = reports_dir / "phase2"
    phase2_json = Path(args.phase2_json) if args.phase2_json else (phase2_dir / f"{args.slug}-phase2.json")
    dispatch_path = reports_dir / f"{args.slug}-dispatch.json"
    if not phase2_json.exists():
        print(f"[ERROR] Phase 2 canonical file not found: {phase2_json}")
        return 1

    merged = load_json(phase2_json)
    dispatch = load_json(dispatch_path) if dispatch_path.exists() else {}
    findings = merged.get("findings", [])
    active_findings = [finding for finding in findings if finding.get("verdict") != "FP"]
    for finding in active_findings:
        finding.setdefault("plugin_slug", args.slug)
        finding["source_agents"] = normalized_source_agents(finding, merged)

    cluster_schema = load_schema(root, "phase2-cluster.schema.json")
    cluster_input_schema = load_schema(root, "phase2-cluster-input.schema.json")
    synth_provider = (dispatch.get("cluster_synth_provider") or os.environ.get("PHASE2_CLUSTER_SYNTH_PROVIDER", "codex")).lower()
    challenger_provider = (dispatch.get("cluster_challenger_provider") or os.environ.get("PHASE2_CLUSTER_CHALLENGER_PROVIDER", "claude")).lower()

    components = connected_components(active_findings)
    components.sort(
        key=lambda component: (
            -sum(item.get("confidence") or 0.0 for item in component),
            -len(component),
            min(item.get("finding_id") or "" for item in component),
        )
    )

    phase2_dir.mkdir(parents=True, exist_ok=True)
    cluster_paths = []
    cluster_input_paths = []
    cluster_documents = []
    for index, component in enumerate(components, start=1):
        cluster_id = f"cluster-c{index:02d}"
        cluster_doc = summarize_cluster(component, cluster_id, synth_provider, challenger_provider, dispatch)
        validate(cluster_doc, cluster_schema, cluster_id)
        cluster_path = phase2_dir / f"{args.slug}-{cluster_id}.json"
        cluster_path.write_text(json.dumps(cluster_doc, indent=2) + "\n", encoding="utf-8")
        cluster_input = build_cluster_input(cluster_doc)
        validate(cluster_input, cluster_input_schema, f"{cluster_id}.input")
        cluster_input_path = phase2_dir / f"{args.slug}-{cluster_id}.input.json"
        cluster_input_path.write_text(json.dumps(cluster_input, indent=2) + "\n", encoding="utf-8")
        cluster_paths.append(cluster_path)
        cluster_input_paths.append(cluster_input_path)
        cluster_documents.append(cluster_doc)

    inventory_path = reports_dir / f"{args.slug}-candidate-inventory.json"
    uncovered_worker_agents: list[str] = []
    if inventory_path.exists():
        inventory = load_json(inventory_path)
        active_agents = {agent for cluster in cluster_documents for agent in cluster["source_agents"]}
        for bundle in inventory.get("bundle_plan", []):
            agent_id = bundle.get("agent_id")
            if agent_id and agent_id not in active_agents:
                uncovered_worker_agents.append(agent_id)

    cluster_plan = {
        "plugin_slug": args.slug,
        "cluster_strategy": "cross_bundle_cluster_v1",
        "generated_from": str(phase2_json),
        "total_input_findings": len(findings),
        "total_active_findings": len(active_findings),
        "total_clusters": len(cluster_documents),
        "recommended_models": {
            "synthesizer": {
                "provider": synth_provider,
                "model": resolve_model(synth_provider, "SYNTH", dispatch),
            },
            "challenger": {
                "provider": challenger_provider,
                "model": resolve_model(challenger_provider, "CHALLENGER", dispatch),
            },
        },
        "clusters": [
            {
                "cluster_id": cluster["cluster_id"],
                "bug_family": cluster["bug_family"],
                "auth_boundary": cluster["auth_boundary"],
                "member_count": len(cluster["member_findings"]),
                "source_agents": cluster["source_agents"],
                "entry_point_ids": cluster["entry_point_ids"],
                "priority_score": cluster["priority_score"],
                "path": str(path),
                "input_path": str(input_path),
            }
            for cluster, path, input_path in zip(cluster_documents, cluster_paths, cluster_input_paths)
        ],
        "uncovered_worker_agents": uncovered_worker_agents,
    }
    cluster_plan_path = phase2_dir / f"{args.slug}-cluster-plan.json"
    cluster_plan_path.write_text(json.dumps(cluster_plan, indent=2) + "\n", encoding="utf-8")
    print(f"[OK] Cluster plan written: {cluster_plan_path}")
    print(f"[OK] Cluster docs written: {len(cluster_paths)}")
    print(f"[OK] Cluster input docs written: {len(cluster_input_paths)}")
    if uncovered_worker_agents:
        print(f"[INFO] Uncovered worker bundles: {', '.join(uncovered_worker_agents)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
