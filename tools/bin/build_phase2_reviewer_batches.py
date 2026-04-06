#!/usr/bin/env python3
"""
build_phase2_reviewer_batches.py — deterministic reviewer_core batch planner
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import sys
from collections import Counter
from pathlib import Path

import jsonschema

if __package__ in {None, ""}:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.bin.build_phase2_reviewer_input import find_project_root, load_json, normalize_review_mode, relative_to_root


def dedupe_items(items: list[dict], keys: tuple[str, ...]) -> list[dict]:
    deduped: list[dict] = []
    seen: set[tuple[object, ...]] = set()
    for item in items:
        marker = tuple(item.get(key) for key in keys)
        if marker in seen:
            continue
        seen.add(marker)
        deduped.append(item)
    return deduped


def packet_identity(packet: dict) -> str:
    return str(packet.get("packet_id") or packet.get("finding_id") or "unknown-packet")


def parent_finding_id(packet: dict) -> str:
    return str(packet.get("parent_finding_id") or packet.get("finding_id") or "unknown-finding")


def packet_local_score(packet: dict, entry_point_freq: Counter, file_freq: Counter) -> int:
    score = 1
    if len(packet.get("primary_snippets") or []) >= 3:
        score += 1
    if len(packet.get("optional_snippets") or []) >= 2:
        score += 1
    if len(packet.get("primary_files") or []) >= 2:
        score += 1
    if str(packet.get("verdict") or "").upper() in {"TP", "REVIEW", "UNCERTAIN"}:
        score += 1
    entry_point_id = packet.get("entry_point_id")
    if entry_point_id and entry_point_freq[entry_point_id] > 1:
        score += 1
    elif any(file_freq[file_path] > 1 for file_path in packet.get("primary_files") or []):
        score += 1
    return score


def total_load_score(packets: list[dict]) -> int:
    primary_snippets = sum(len(packet.get("primary_snippets") or []) for packet in packets)
    optional_snippets = sum(len(packet.get("optional_snippets") or []) for packet in packets)
    anchor_counter: Counter[str] = Counter()
    file_counter: Counter[str] = Counter()
    for packet in packets:
        anchors = packet.get("anchors") or {}
        for value in (anchors.get("entry_point_anchor"), anchors.get("source_anchor"), anchors.get("sink_anchor")):
            if value:
                anchor_counter[str(value)] += 1
        for file_path in packet.get("primary_files") or []:
            file_counter[str(file_path)] += 1

    reused_anchor_count = sum(1 for count in anchor_counter.values() if count > 1)
    repeated_file_instances = sum(count - 1 for count in file_counter.values() if count > 1)
    total = len(packets)
    total += math.ceil(primary_snippets / 4)
    total += math.ceil(optional_snippets / 4)
    if reused_anchor_count:
        total += math.ceil(reused_anchor_count / 3)
    if repeated_file_instances:
        total += math.ceil(repeated_file_instances / 3)
    return total


def batch_similarity(packet_a: dict, packet_b: dict) -> int:
    score = 0
    if packet_a.get("entry_point_id") and packet_a.get("entry_point_id") == packet_b.get("entry_point_id"):
        score += 4
    score += 2 * len(set(packet_a.get("primary_files") or []) & set(packet_b.get("primary_files") or []))
    anchors_a = {
        (packet_a.get("anchors") or {}).get("entry_point_anchor"),
        (packet_a.get("anchors") or {}).get("source_anchor"),
        (packet_a.get("anchors") or {}).get("sink_anchor"),
    }
    anchors_b = {
        (packet_b.get("anchors") or {}).get("entry_point_anchor"),
        (packet_b.get("anchors") or {}).get("source_anchor"),
        (packet_b.get("anchors") or {}).get("sink_anchor"),
    }
    score += 3 * len({anchor for anchor in anchors_a & anchors_b if anchor})
    return score


def connected_components(packets: list[dict]) -> list[list[dict]]:
    graph: dict[str, set[str]] = {packet_identity(packet): set() for packet in packets}
    packet_by_id = {packet_identity(packet): packet for packet in packets}
    for idx, left in enumerate(packets):
        left_id = packet_identity(left)
        for right in packets[idx + 1 :]:
            right_id = packet_identity(right)
            if batch_similarity(left, right) > 0:
                graph[left_id].add(right_id)
                graph[right_id].add(left_id)

    components: list[list[dict]] = []
    seen: set[str] = set()
    for packet_id in graph:
        if packet_id in seen:
            continue
        queue = [packet_id]
        seen.add(packet_id)
        component_ids: list[str] = []
        while queue:
            current = queue.pop()
            component_ids.append(current)
            for neighbor in graph[current]:
                if neighbor not in seen:
                    seen.add(neighbor)
                    queue.append(neighbor)
        components.append([packet_by_id[item] for item in sorted(component_ids)])
    return components


def cluster_reasons(component: list[dict]) -> list[str]:
    reasons: list[str] = []
    entry_points = {packet.get("entry_point_id") for packet in component if packet.get("entry_point_id")}
    if len(entry_points) == 1 and entry_points:
        reasons.append(f"shared_entry_point:{next(iter(entry_points))}")
    file_counter: Counter[str] = Counter()
    for packet in component:
        for file_path in packet.get("primary_files") or []:
            file_counter[file_path] += 1
    reasons.extend(f"shared_primary_file:{path}" for path, count in file_counter.items() if count > 1)
    return reasons or ["semantic_singleton"]


def component_load(component: list[dict], packet_scores: dict[str, int]) -> int:
    return sum(packet_scores[packet_identity(packet)] for packet in component)


def split_component(component: list[dict], packet_scores: dict[str, int]) -> tuple[list[dict], list[dict]] | None:
    if len(component) <= 1:
        return None
    ordered = sorted(component, key=lambda packet: (-packet_scores[packet_identity(packet)], packet_identity(packet)))
    left = [ordered[0]]
    right = [ordered[1]]
    for packet in ordered[2:]:
        left_score = sum(batch_similarity(packet, item) for item in left)
        right_score = sum(batch_similarity(packet, item) for item in right)
        left_load = component_load(left, packet_scores)
        right_load = component_load(right, packet_scores)
        if left_score > right_score:
            left.append(packet)
        elif right_score > left_score:
            right.append(packet)
        elif left_load <= right_load:
            left.append(packet)
        else:
            right.append(packet)
    return left, right


def plan_batches(packets: list[dict]) -> dict:
    entry_point_freq: Counter[str] = Counter(
        str(packet.get("entry_point_id"))
        for packet in packets
        if packet.get("entry_point_id")
    )
    primary_file_freq: Counter[str] = Counter()
    for packet in packets:
        for file_path in packet.get("primary_files") or []:
            primary_file_freq[str(file_path)] += 1

    packet_scores = {
        packet_identity(packet): packet_local_score(packet, entry_point_freq, primary_file_freq)
        for packet in packets
    }

    total_score = total_load_score(packets)
    target_batch_count = max(1, min(len(packets), math.ceil(total_score / 3)))
    target_batch_load = max(2, math.ceil(sum(packet_scores.values()) / target_batch_count))

    batches = connected_components(packets)
    batches.sort(key=lambda component: (-component_load(component, packet_scores), packet_identity(component[0])))

    while len(batches) < target_batch_count:
        candidate_index = None
        candidate_split = None
        candidate_load = -1
        for index, component in enumerate(batches):
            current_load = component_load(component, packet_scores)
            if len(component) <= 1 or current_load <= target_batch_load:
                continue
            split_result = split_component(component, packet_scores)
            if not split_result:
                continue
            if current_load > candidate_load:
                candidate_index = index
                candidate_split = split_result
                candidate_load = current_load
        if candidate_index is None or candidate_split is None:
            break
        batches.pop(candidate_index)
        left, right = candidate_split
        batches.extend([left, right])
        batches.sort(key=lambda component: (-component_load(component, packet_scores), packet_identity(component[0])))

    return {
        "total_load_score": total_score,
        "target_batch_count": target_batch_count,
        "target_batch_load": target_batch_load,
        "packet_scores": packet_scores,
        "batches": batches,
    }


def subset_phase1_context(data: dict, batch_packets: list[dict]) -> dict:
    phase1_context = copy.deepcopy(data.get("phase1_context") or {})
    entry_point_ids = {
        packet.get("entry_point_id")
        for packet in batch_packets
        if packet.get("entry_point_id")
    }
    relevant_files = {
        file_path
        for packet in batch_packets
        for file_path in (
            list(packet.get("primary_files") or [])
            + list(packet.get("optional_files") or [])
            + list((packet.get("scope_policy") or {}).get("allowed_primary_files") or [])
            + list((packet.get("scope_policy") or {}).get("allowed_optional_files") or [])
        )
        if file_path
    }
    if entry_point_ids:
        phase1_context["related_entry_points"] = [
            item for item in phase1_context.get("related_entry_points") or []
            if item.get("id") in entry_point_ids and (not relevant_files or item.get("file") in relevant_files)
        ]
    return phase1_context


def subset_evidence(batch_packets: list[dict]) -> dict:
    primary_anchors: list[dict] = []
    primary_snippets: list[dict] = []
    for packet in batch_packets:
        anchors = packet.get("anchors") or {}
        for kind, anchor_value in (
            ("entry_point", anchors.get("entry_point_anchor")),
            ("finding_source", anchors.get("source_anchor")),
            ("finding_sink", anchors.get("sink_anchor")),
        ):
            if anchor_value:
                primary_anchors.append(
                    {
                        "kind": kind,
                        "anchor": anchor_value,
                        "packet_id": packet_identity(packet),
                        "finding_id": parent_finding_id(packet),
                        "entry_point_id": packet.get("entry_point_id"),
                        "note": packet.get("vuln_type"),
                    }
                )
        primary_snippets.extend(packet.get("primary_snippets") or [])

    primary_anchors = dedupe_items(primary_anchors, ("kind", "anchor", "packet_id"))
    primary_snippets = dedupe_items(primary_snippets, ("file", "anchor", "kind"))
    return {
        "primary_anchors": primary_anchors,
        "primary_files": sorted({snippet["file"] for snippet in primary_snippets}),
        "primary_snippets": primary_snippets,
        "optional_evidence": {"anchors": [], "files": [], "snippets": []},
    }


def subset_worker_summary(batch_findings: list[dict], worker_summary: dict) -> dict:
    total = len(batch_findings)
    tp = sum(1 for finding in batch_findings if str(finding.get("verdict") or "").upper() == "TP")
    fp = sum(1 for finding in batch_findings if str(finding.get("verdict") or "").upper() == "FP")
    review = sum(1 for finding in batch_findings if str(finding.get("verdict") or "").upper() == "REVIEW")
    return {
        "total_findings": total,
        "true_positive_count": tp,
        "false_positive_count": fp,
        "needs_review_count": review,
        "negative_findings_count": 0,
        "overall_risk": worker_summary.get("overall_risk"),
        "analysis_summary": f"Reviewer core batch scoped to {total} packet(s).",
    }


def build_batch_payload(root: Path, data: dict, batch_packets: list[dict], batch_input_path: Path, batch_output_path: Path) -> dict:
    finding_ids = {parent_finding_id(packet) for packet in batch_packets}
    payload = copy.deepcopy(data)
    payload["task"]["output_path"] = relative_to_root(batch_output_path, root)
    payload["worker_findings"] = [item for item in data.get("worker_findings") or [] if item.get("finding_id") in finding_ids]
    payload["finding_packets"] = batch_packets
    payload["worker_summary"] = subset_worker_summary(payload["worker_findings"], data.get("worker_summary") or {})
    payload["phase1_context"] = subset_phase1_context(data, batch_packets)
    payload["evidence"] = subset_evidence(batch_packets)
    payload["artifacts"]["worker_output_path"] = None
    payload["artifacts"]["ir_path"] = None
    payload["artifacts"]["semgrep_path"] = None
    payload["artifacts"]["psalm_path"] = None
    payload["artifacts"]["threat_context_path"] = None

    schema = load_json(root / "contracts" / "phase2-reviewer-input.schema.json")
    jsonschema.validate(instance=payload, schema=schema)
    batch_input_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return payload


def build_reviewer_batches(*, root: Path, input_path: Path, output_plan: Path) -> dict:
    data = load_json(input_path)
    review_mode = normalize_review_mode(data.get("review_mode"))
    if review_mode != "core":
        raise ValueError("Reviewer batching currently supports core mode only.")

    packets = data.get("finding_packets") or []
    if not packets:
        raise ValueError("Reviewer core input has no finding packets to batch.")

    plan_state = plan_batches(packets)
    batches = plan_state["batches"]
    output_dir = output_plan.parent
    plugin_slug = str(data["plugin_slug"])
    review_round = int(data["review_round"])

    batch_entries = []
    for index, batch_packets in enumerate(batches, start=1):
        batch_id = f"b{index:02d}"
        batch_input_path = output_dir / f"{plugin_slug}-phase2.review.r{review_round}.core.{batch_id}.input.json"
        batch_output_path = output_dir / f"{plugin_slug}-phase2.review.r{review_round}.core.{batch_id}.json"
        build_batch_payload(root, data, batch_packets, batch_input_path, batch_output_path)
        batch_entries.append(
            {
                "batch_id": batch_id,
                "packet_count": len(batch_packets),
                "load_score": component_load(batch_packets, plan_state["packet_scores"]),
                "packet_ids": [packet_identity(packet) for packet in batch_packets],
                "finding_ids": sorted({parent_finding_id(packet) for packet in batch_packets}),
                "parent_finding_ids": sorted({parent_finding_id(packet) for packet in batch_packets}),
                "entry_point_ids": sorted({packet.get("entry_point_id") for packet in batch_packets if packet.get("entry_point_id")}),
                "primary_files": sorted({file_path for packet in batch_packets for file_path in packet.get("primary_files") or []}),
                "input_path": relative_to_root(batch_input_path, root),
                "output_path": relative_to_root(batch_output_path, root),
                "reasons": cluster_reasons(batch_packets),
            }
        )

    plan_doc = {
        "plugin_slug": plugin_slug,
        "review_round": review_round,
        "review_mode": "core",
        "total_packet_count": len(packets),
        "total_load_score": plan_state["total_load_score"],
        "target_batch_count": plan_state["target_batch_count"],
        "target_batch_load": plan_state["target_batch_load"],
        "batches": batch_entries,
    }
    schema = load_json(root / "contracts" / "phase2-review-batch-plan.schema.json")
    jsonschema.validate(instance=plan_doc, schema=schema)
    output_plan.write_text(json.dumps(plan_doc, indent=2) + "\n", encoding="utf-8")
    return plan_doc


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build deterministic reviewer_core batches.")
    parser.add_argument("--input", required=True, help="Path to reviewer core input JSON")
    parser.add_argument("--output-plan", required=True, help="Path to batch plan JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = find_project_root()
    input_path = Path(args.input)
    output_plan = Path(args.output_plan)
    build_reviewer_batches(root=root, input_path=input_path, output_plan=output_plan)
    print(f"[OK] Reviewer batch plan written: {output_plan}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
