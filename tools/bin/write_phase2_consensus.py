#!/usr/bin/env python3
"""
write_phase2_consensus.py — deterministic Phase 2 consensus writer
"""

from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import shutil
from pathlib import Path

import jsonschema


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


def validate_local_phase2_doc(local_doc: dict) -> None:
    if not isinstance(local_doc.get("plugin_slug"), str) or not local_doc["plugin_slug"]:
        raise ValueError("phase2.local missing plugin_slug")
    if not isinstance(local_doc.get("findings"), list):
        raise ValueError("phase2.local missing findings[]")


def synthetic_merge_stats(local_doc: dict) -> dict:
    findings = local_doc.get("findings") or []
    phase2_loop = local_doc.get("phase2_loop") or {}
    worker_provider = str(phase2_loop.get("worker_provider") or "worker")
    worker_round = int(phase2_loop.get("completed_worker_rounds") or 0)
    derived_agent = f"worker-r{worker_round:02d}-{worker_provider}"
    agents = sorted({
        str(agent)
        for finding in findings
        for agent in (finding.get("source_agents") or [])
        if str(agent)
    })
    if not agents:
        agents = [derived_agent]
    return {
        "total_raw": len(findings),
        "total_deduplicated": len(findings),
        "agents_included": agents,
        "agents_missing": [],
        "tp_count": int(local_doc.get("true_positives") or 0),
        "fp_count": int(local_doc.get("false_positives") or 0),
        "review_count": int(local_doc.get("needs_review") or 0),
        "synthetic": True,
    }


def normalize_local_doc(local_doc: dict) -> dict:
    normalized = copy.deepcopy(local_doc)
    merge_stats = normalized.get("merge_stats")
    required = {"total_raw", "total_deduplicated", "agents_included"}
    if not isinstance(merge_stats, dict) or not required.issubset(set(merge_stats.keys())):
        normalized["merge_stats"] = synthetic_merge_stats(normalized)
    return normalized


def is_closure_complete(local_doc: dict) -> bool:
    needs_review_value = local_doc.get("needs_review")
    if isinstance(needs_review_value, int):
        return needs_review_value == 0
    findings = local_doc.get("findings")
    if isinstance(findings, list):
        return all(str((finding or {}).get("verdict") or "").upper() != "REVIEW" for finding in findings if isinstance(finding, dict))
    return False


def cluster_summary_entry(cluster: dict, slug: str, phase2_dir: Path) -> tuple[dict, bool, bool]:
    cluster_id = cluster["cluster_id"]
    synth_path = phase2_dir / f"{slug}-{cluster_id}.synth.json"
    challenge_path = phase2_dir / f"{slug}-{cluster_id}.challenge.json"

    synth_exists = synth_path.exists()
    challenge_exists = challenge_path.exists()

    synth = load_json(synth_path) if synth_exists else {}
    challenge = load_json(challenge_path) if challenge_exists else {}
    open_questions = len(synth.get("open_questions", [])) + len(challenge.get("open_questions", []))
    missing_evidence = len(synth.get("missing_evidence", [])) + len(challenge.get("missing_evidence", []))
    closure_packets = len(synth.get("closure_packets", [])) + len(challenge.get("closure_packets", []))
    statuses = {
        str(value)
        for value in (
            synth.get("status") if synth_exists else None,
            challenge.get("status") if challenge_exists else None,
        )
        if str(value or "")
    }
    routing_required = any(status in {"needs_followup", "mixed"} for status in statuses)
    routing_missing = routing_required and closure_packets == 0
    return ({
        "cluster_id": cluster_id,
        "member_count": cluster.get("member_count", 0),
        "pack_path": cluster.get("pack_path"),
        "synth_path": str(synth_path) if synth_exists else None,
        "challenge_path": str(challenge_path) if challenge_exists else None,
        "synth_status": synth.get("status") if synth_exists else None,
        "challenge_status": challenge.get("status") if challenge_exists else None,
        "closure_packets_count": closure_packets,
        "open_questions_count": open_questions,
        "missing_evidence_count": missing_evidence,
        "routing_required": routing_required,
        "routing_missing": routing_missing,
    }, synth_exists, challenge_exists)


def build_consensus(local_doc: dict, slug: str, phase2_dir: Path, local_phase2_path: Path) -> dict:
    plan_path = phase2_dir / f"{slug}-cluster-plan.json"
    global_exploration_path = phase2_dir / f"{slug}-global-exploration.json"
    cluster_entries = []
    synth_ok = 0
    challenge_ok = 0
    open_questions_total = 0
    missing_evidence_total = 0
    closure_packets_total = 0
    unresolved_cluster_ids: list[str] = []
    notes: list[str] = []

    if plan_path.exists():
        plan = load_json(plan_path)
        for cluster in plan.get("clusters", []):
            entry, has_synth, has_challenge = cluster_summary_entry(cluster, slug, phase2_dir)
            cluster_entries.append(entry)
            synth_ok += int(has_synth)
            challenge_ok += int(has_challenge)
            closure_packets_total += entry["closure_packets_count"]
            open_questions_total += entry["open_questions_count"]
            missing_evidence_total += entry["missing_evidence_count"]
            if not has_synth or not has_challenge or entry["routing_missing"]:
                unresolved_cluster_ids.append(entry["cluster_id"])
    else:
        notes.append("cluster_plan_missing")

    if global_exploration_path.exists():
        notes.append("global_exploration_present")

    consensus = {
        "strategy": "phase2_consensus_v1",
        "generated_timestamp": dt.datetime.utcnow().isoformat() + "Z",
        "local_phase2_path": str(local_phase2_path),
        "cluster_plan_path": str(plan_path) if plan_path.exists() else None,
        "global_exploration_path": str(global_exploration_path) if global_exploration_path.exists() else None,
        "clusters_total": len(cluster_entries),
        "synth_ok_count": synth_ok,
        "challenge_ok_count": challenge_ok,
        "closure_packets_total": closure_packets_total,
        "open_questions_total": open_questions_total,
        "missing_evidence_total": missing_evidence_total,
        "unresolved_cluster_ids": unresolved_cluster_ids,
        "clusters": cluster_entries,
        "notes": notes,
    }

    result = copy.deepcopy(local_doc)
    closure_complete = is_closure_complete(result)
    degradation_signals: list[str] = []
    local_merge_stats = result.get("merge_stats") if isinstance(result.get("merge_stats"), dict) else {}
    if isinstance(local_merge_stats.get("degradation_signals"), list):
        degradation_signals.extend(str(item) for item in local_merge_stats["degradation_signals"] if str(item))
    if not closure_complete:
        degradation_signals.append("closure_incomplete")
    if unresolved_cluster_ids:
        degradation_signals.append("unresolved_clusters")
    if plan_path.exists() and synth_ok < len(cluster_entries):
        degradation_signals.append("cluster_synthesis_incomplete")
    if plan_path.exists() and challenge_ok < len(cluster_entries):
        degradation_signals.append("cluster_challenge_incomplete")
    if any(entry.get("routing_missing") for entry in cluster_entries):
        degradation_signals.append("cluster_closure_routing_missing")
    if not plan_path.exists():
        degradation_signals.append("cluster_plan_missing")
    degradation_signals = sorted(set(degradation_signals))
    trust_state = "degraded_success" if degradation_signals else "success"

    consensus["closure_complete"] = closure_complete
    consensus["trust_state"] = trust_state
    consensus["degradation_signals"] = degradation_signals
    result["consensus"] = consensus
    result.setdefault("merge_stats", {})
    result["merge_stats"]["consensus_applied"] = True
    result["merge_stats"]["closure_complete"] = closure_complete
    result["merge_stats"]["consensus_unresolved_clusters"] = len(unresolved_cluster_ids)
    result["merge_stats"]["degradation_signals"] = degradation_signals
    result["merge_stats"]["trust_state"] = trust_state
    result["closure_complete"] = closure_complete
    result["trust_state"] = trust_state
    result["degradation_signals"] = degradation_signals
    return result


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Write deterministic Phase 2 consensus and update canonical phase2.json.")
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--reports-dir", default=None, help="Reports directory (default: <root>/reports)")
    return parser.parse_args()


def resolve_local_phase2_source(phase2_dir: Path, slug: str) -> Path:
    local_path = phase2_dir / f"{slug}-phase2.local.json"
    if not local_path.exists():
        raise FileNotFoundError(f"No local Phase 2 file found for slug: {slug}")
    return local_path


def main() -> int:
    args = parse_args()
    root = find_project_root()
    reports_dir = Path(args.reports_dir) if args.reports_dir else (root / "reports")
    phase2_dir = reports_dir / "phase2"
    canonical_path = phase2_dir / f"{args.slug}-phase2.json"
    try:
        local_path = resolve_local_phase2_source(phase2_dir, args.slug)
    except FileNotFoundError as exc:
        print(f"[ERROR] {exc}")
        return 1

    consensus_schema = load_schema(root, "phase2-consensus.schema.json")

    local_doc = normalize_local_doc(load_json(local_path))
    validate_local_phase2_doc(local_doc)
    consensus_doc = build_consensus(local_doc, args.slug, phase2_dir, local_path)
    validate(consensus_doc, consensus_schema, "phase2.consensus")

    consensus_path = phase2_dir / f"{args.slug}-phase2.consensus.json"
    consensus_path.write_text(json.dumps(consensus_doc, indent=2) + "\n", encoding="utf-8")
    shutil.copy2(consensus_path, canonical_path)
    print(f"[OK] Consensus written: {consensus_path}")
    print(f"[OK] Canonical updated: {canonical_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
