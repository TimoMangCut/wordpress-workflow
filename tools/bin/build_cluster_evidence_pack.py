#!/usr/bin/env python3
"""
build_cluster_evidence_pack.py — deterministic evidence pack builder for cluster stages
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

import jsonschema


SNIPPET_RADIUS = 6


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


def parse_anchor(anchor: str) -> tuple[str | None, int | None]:
    if not anchor or anchor == "<unknown>":
        return None, None
    path, sep, tail = anchor.rpartition(":")
    if sep and tail.isdigit():
        return path, int(tail)
    return anchor, None


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8", errors="replace").splitlines()


def extract_snippet(repo_root: Path, plugin_slug: str, anchor: str, kind: str) -> dict | None:
    rel_path, focus_line = parse_anchor(anchor)
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
    code = "\n".join(f"{lineno:>6}\t{lines[lineno - 1]}" for lineno in range(start, end + 1))
    return {
        "file": rel_path,
        "anchor": anchor,
        "focus_line": focus_line,
        "line_start": start,
        "line_end": end,
        "kind": kind,
        "code": code,
    }


def dedupe_snippets(snippets: list[dict]) -> list[dict]:
    deduped: list[dict] = []
    seen: set[tuple[str, str]] = set()
    for snippet in snippets:
        key = (snippet["file"], snippet["anchor"])
        if key in seen:
            continue
        seen.add(key)
        deduped.append(snippet)
    return deduped


def build_pack(cluster_input: dict, repo_root: Path) -> dict:
    slug = cluster_input["plugin_slug"]
    shared = cluster_input["shared_context"]
    member_findings = cluster_input.get("member_findings", [])

    primary_anchors = shared.get("primary_anchors", [])
    primary_files = set(shared.get("primary_files", []))
    optional_files = set(shared.get("optional_files", []))
    budget = cluster_input.get("exploration_budget", {})

    primary_snippets: list[dict] = []
    optional_snippets: list[dict] = []

    for anchor in primary_anchors:
        rel_path, _ = parse_anchor(anchor)
        if not rel_path:
            continue
        kind = "primary_anchor"
        snippet = extract_snippet(repo_root, slug, anchor, kind)
        if snippet:
            primary_snippets.append(snippet)

    optional_files_used: set[str] = set()
    max_optional_files = int(budget.get("max_optional_files", 0))
    for item in member_findings:
        candidate_anchors = [item.get("source_anchor"), item.get("sink_anchor"), *(item.get("guard_anchors") or [])]
        for anchor in candidate_anchors:
            rel_path, _ = parse_anchor(anchor)
            if not rel_path or rel_path in primary_files or rel_path not in optional_files:
                continue
            if rel_path not in optional_files_used and len(optional_files_used) >= max_optional_files:
                continue
            snippet = extract_snippet(repo_root, slug, anchor, "optional_anchor")
            if snippet:
                optional_snippets.append(snippet)
                optional_files_used.add(rel_path)

    primary_snippets = dedupe_snippets(primary_snippets)
    optional_snippets = dedupe_snippets(optional_snippets)

    pack = dict(cluster_input)
    pack["evidence_pack"] = {
        "primary_files_covered": sorted({snippet["file"] for snippet in primary_snippets}),
        "optional_files_covered": sorted({snippet["file"] for snippet in optional_snippets}),
        "primary_snippets": primary_snippets,
        "optional_snippets": optional_snippets,
        "snippet_counts": {
            "primary": len(primary_snippets),
            "optional": len(optional_snippets),
        },
    }
    return pack


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build deterministic evidence packs for Phase 2 cluster stages.")
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--reports-dir", default=None, help="Reports directory (default: <root>/reports)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = find_project_root()
    reports_dir = Path(args.reports_dir) if args.reports_dir else (root / "reports")
    phase2_dir = reports_dir / "phase2"
    plan_path = phase2_dir / f"{args.slug}-cluster-plan.json"
    if not plan_path.exists():
        print(f"[ERROR] Cluster plan not found: {plan_path}")
        return 1

    input_schema = load_schema(root, "phase2-cluster-input.schema.json")
    pack_schema = load_schema(root, "phase2-cluster-pack.schema.json")
    plan = load_json(plan_path)
    updated_clusters = []

    for cluster in plan.get("clusters", []):
        input_path = cluster.get("input_path")
        if not input_path:
            updated_clusters.append(cluster)
            continue
        input_file = Path(input_path)
        if not input_file.is_absolute():
            input_file = root / input_file
        if not input_file.exists():
            updated_clusters.append(cluster)
            continue
        cluster_input = load_json(input_file)
        validate(cluster_input, input_schema, f"{cluster.get('cluster_id')}.input")
        pack = build_pack(cluster_input, root)
        validate(pack, pack_schema, f"{cluster.get('cluster_id')}.pack")
        pack_path = phase2_dir / f"{args.slug}-{cluster['cluster_id']}.pack.json"
        pack_path.write_text(json.dumps(pack, indent=2) + "\n", encoding="utf-8")
        cluster = dict(cluster)
        cluster["pack_path"] = str(pack_path)
        updated_clusters.append(cluster)

    plan["clusters"] = updated_clusters
    plan_path.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    print(f"[OK] Cluster plan updated with pack paths: {plan_path}")
    print(f"[OK] Evidence packs written: {len([c for c in updated_clusters if c.get('pack_path')])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
