#!/usr/bin/env python3
"""
merge_agent_outputs.py — Phase 2.5: Deterministic Merge
========================================================
Session 17 — tools/bin/merge_agent_outputs.py (new file)

Merges per-agent JSON outputs into a single deduplicated findings file.

Pipeline position (multi-agent-plan.md:431-437):
  1. prepare_agent_inputs.py  → per-agent IR slices
  2. Agents run               → reports/<slug>-agent-{id}.json
  3. THIS SCRIPT              → reports/<slug>-phase2-merged.json (archive)
                                reports/<slug>-phase2.json         (canonical for gate)

Usage:
  python3 tools/bin/merge_agent_outputs.py <slug> [--output-dir <dir>]
  python3 tools/bin/merge_agent_outputs.py --agent-a1 <file> --agent-a2 <file> ... [--slug <slug>] [--output-dir <dir>]
  python3 tools/bin/merge_agent_outputs.py --agents "reports/<slug>-agent-*.json" [--slug <slug>] [--output-dir <dir>]

Schema contracts:
  Input:  contracts/agent-output.schema.json  (per-agent, validated before merge)
  Output: contracts/merge-output.schema.json  (hard error on mismatch)
"""

import argparse
import copy
import datetime
import glob as glob_module
import json
import os
import sys
from pathlib import Path


# ---------------------------------------------------------------------------
# Schema loading + validation
# ---------------------------------------------------------------------------

def _find_contracts_dir() -> Path:
    """Walk up from this script to find the contracts/ directory."""
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        contracts = candidate / "contracts"
        if contracts.is_dir():
            return contracts
    raise FileNotFoundError(
        "contracts/ directory not found relative to script location. "
        "Run from the project root or ensure contracts/ exists."
    )


def _load_schema(schema_file: str) -> dict:
    contracts = _find_contracts_dir()
    path = contracts / schema_file
    with open(path) as f:
        return json.load(f)


def _validate(instance: dict, schema: dict, label: str) -> list[str]:
    """
    Validate `instance` against `schema`. Returns list of error messages.
    Requires jsonschema; if missing, logs a warning and skips validation.
    """
    try:
        import jsonschema
        errors = list(jsonschema.Draft7Validator(schema).iter_errors(instance))
        return [e.message for e in errors]
    except ImportError:
        print(
            f"[WARN] jsonschema not installed — skipping schema validation for {label}. "
            "Install with: pip install jsonschema",
            file=sys.stderr,
        )
        return []


# ---------------------------------------------------------------------------
# Dedup key construction
# ---------------------------------------------------------------------------

_SINK_LINE_WINDOW = 5  # ±5 lines counts as "same sink"


def _make_dedup_key(finding: dict) -> tuple:
    """
    Build a canonical dedup key.

    Single-EP:    (entry_point_id, sink_file, sink_line_bucket, vuln_type)
    Stored/cross: (store_entry_point_id, load_entry_point_id, storage_key, vuln_type)

    Source: multi-agent-plan.md:353-354
    """
    store_ep = finding.get("store_entry_point_id")
    if store_ep:
        # Stored / cross-EP flow (Agent B output)
        return (
            "stored",
            store_ep or "",
            finding.get("load_entry_point_id") or "",
            finding.get("storage_key") or "",
            (finding.get("vuln_type") or "").lower(),
        )
    else:
        # Single-EP flow
        sink_line = finding.get("sink_line_number")
        if sink_line is not None:
            # Bucket to nearest _SINK_LINE_WINDOW boundary so ±5 lines match
            sink_bucket = (int(sink_line) // _SINK_LINE_WINDOW) * _SINK_LINE_WINDOW
        else:
            sink_bucket = None
        return (
            "single",
            finding.get("entry_point_id") or "",
            (finding.get("sink_file_path") or "").lower(),
            sink_bucket,
            (finding.get("vuln_type") or "").lower(),
        )


# ---------------------------------------------------------------------------
# Merge logic
# ---------------------------------------------------------------------------

_VERDICT_RANK = {"TP": 2, "REVIEW": 1, "FP": 0}


def _merge_group(findings_with_agents: list[tuple[dict, str]]) -> dict:
    """
    Merge a group of findings that share the same dedup key.

    findings_with_agents: list of (finding_dict, agent_id)

    Rules (multi-agent-plan.md:356-359):
    - Single finding → keep as-is, add source_agents.
    - Duplicates (same verdict) → merge evidence, keep highest confidence,
      record agent_agreement count.
    - Conflicts (different verdicts) → preserve BOTH findings, flag conflict=True,
      include conflicting_verdicts list.

    Returns a single merged finding dict (conflicts result in a finding with
    conflict=True and conflicting_verdicts=[...]).
    """
    assert findings_with_agents, "empty group"

    if len(findings_with_agents) == 1:
        finding, agent_id = findings_with_agents[0]
        merged = copy.deepcopy(finding)
        merged["source_agents"] = [agent_id]
        return merged

    # Partition by verdict
    by_verdict: dict[str, list[tuple[dict, str]]] = {}
    for f, aid in findings_with_agents:
        verdict = f.get("verdict", "REVIEW")
        by_verdict.setdefault(verdict, []).append((f, aid))

    verdicts_present = list(by_verdict.keys())

    if len(verdicts_present) > 1:
        # CONFLICT: different verdicts for the same dedup key
        # Preserve the HIGHEST-ranked verdict's finding as the base,
        # flag conflict=True, include full conflicting_verdicts.
        best_verdict = max(verdicts_present, key=lambda v: _VERDICT_RANK.get(v, 0))
        best_findings = by_verdict[best_verdict]
        # Pick highest confidence among best-verdict group
        base_f, base_agent = max(
            best_findings,
            key=lambda fa: fa[0].get("confidence") or 0.0,
        )
        merged = copy.deepcopy(base_f)
        all_agents = [aid for _, aid in findings_with_agents]
        merged["source_agents"] = all_agents
        merged["conflict"] = True
        merged["conflicting_verdicts"] = [
            {
                "agent_id": aid,
                "verdict": f.get("verdict"),
                "confidence": f.get("confidence"),
                "reasoning": f.get("reasoning") or f.get("fp_reason") or f.get("review_reason"),
            }
            for f, aid in findings_with_agents
        ]
        return merged
    else:
        # DUPLICATE: same verdict from multiple agents → merge evidence
        same_findings = by_verdict[verdicts_present[0]]
        # Pick highest confidence as base
        base_f, base_agent = max(
            same_findings,
            key=lambda fa: fa[0].get("confidence") or 0.0,
        )
        merged = copy.deepcopy(base_f)
        all_agents = [aid for _, aid in same_findings]
        merged["source_agents"] = all_agents
        merged["agent_agreement"] = len(same_findings)
        merged["conflict"] = False

        # Merge reasoning: concatenate if different (preserve nuance per spec note)
        reasonings = []
        for f, _ in same_findings:
            r = f.get("reasoning") or ""
            if r and r not in reasonings:
                reasonings.append(r)
        if reasonings:
            merged["reasoning"] = "\n\n---\n\n".join(reasonings)

        return merged


def merge_agent_findings(agent_outputs: list[dict]) -> dict:
    """
    Core merge function. Spec: multi-agent-plan.md:348-364.

    Steps:
    1. (Schema validation handled by caller before this function is called)
    2. Group findings by dedup key
    3. Single → keep; Duplicates → merge; Conflicts → preserve + flag
    4. Compute merge_stats
    5. Return merged output dict (caller does schema validate + write)
    """
    if not agent_outputs:
        return {
            "plugin_slug": "",
            "merge_timestamp": datetime.datetime.utcnow().isoformat() + "Z",
            "findings": [],
            "merge_stats": {
                "total_raw": 0,
                "total_deduplicated": 0,
                "agents_included": [],
                "agents_missing": [],
                "tp_count": 0,
                "fp_count": 0,
                "review_count": 0,
                "duplicates_merged": 0,
                "conflicts_flagged": 0,
                "schema_errors": 0,
            },
        }

    plugin_slug = agent_outputs[0].get("plugin_slug", "")
    agents_included = [ao.get("agent_id", "unknown") for ao in agent_outputs]

    # Collect all (finding, agent_id) pairs
    all_pairs: list[tuple[dict, str]] = []
    for ao in agent_outputs:
        agent_id = ao.get("agent_id", "unknown")
        for f in ao.get("findings", []):
            all_pairs.append((f, agent_id))

    total_raw = len(all_pairs)

    # Group by dedup key
    groups: dict[tuple, list[tuple[dict, str]]] = {}
    for f, aid in all_pairs:
        key = _make_dedup_key(f)
        groups.setdefault(key, []).append((f, aid))

    # Merge each group
    merged_findings: list[dict] = []
    duplicates_merged = 0
    conflicts_flagged = 0

    for key, group in groups.items():
        merged = _merge_group(group)
        merged_findings.append(merged)
        if len(group) > 1:
            if merged.get("conflict"):
                conflicts_flagged += 1
            else:
                duplicates_merged += len(group) - 1  # extra copies removed

    # Compute verdict counts on merged findings
    tp_count = sum(1 for f in merged_findings if f.get("verdict") == "TP")
    fp_count = sum(1 for f in merged_findings if f.get("verdict") == "FP")
    review_count = sum(1 for f in merged_findings if f.get("verdict") == "REVIEW")

    return {
        "plugin_slug": plugin_slug,
        "merge_timestamp": datetime.datetime.utcnow().isoformat() + "Z",
        "findings": merged_findings,
        "merge_stats": {
            "total_raw": total_raw,
            "total_deduplicated": len(merged_findings),
            "agents_included": agents_included,
            "agents_missing": [],   # populated by caller who knows expected agents
            "tp_count": tp_count,
            "fp_count": fp_count,
            "review_count": review_count,
            "duplicates_merged": duplicates_merged,
            "conflicts_flagged": conflicts_flagged,
            "schema_errors": 0,     # populated by caller
        },
    }


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _parse_args(argv=None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Phase 2.5 Deterministic Merge — merge per-agent findings outputs.\n\n"
            "Usage modes:\n"
            "  1. Positional slug:  merge_agent_outputs.py <slug> [--output-dir <dir>]\n"
            "     Reads reports/<slug>-agent-{a1,a2,b,c,d}.json (present files only)\n\n"
            "  2. Glob pattern:     merge_agent_outputs.py --agents 'reports/<slug>-agent-*.json'\n\n"
            "  3. Explicit files:   merge_agent_outputs.py --agent-a1 <f> --agent-a2 <f> ...\n"
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "slug",
        nargs="?",
        help="Plugin slug. Resolves input files as reports/<slug>-agent-*.json",
    )
    parser.add_argument(
        "--slug",
        dest="slug_flag",
        default=None,
        help="Plugin slug (alternative to positional arg)",
    )
    parser.add_argument(
        "--output-dir",
        default=None,
        help="Directory for output files. Default: reports/ relative to project root.",
    )
    parser.add_argument(
        "--agents",
        default=None,
        help="Glob pattern matching per-agent output files.",
    )
    # Per-agent explicit paths
    for agent_id in ("a1", "a2", "b", "c", "d"):
        parser.add_argument(
            f"--agent-{agent_id}",
            default=None,
            help=f"Path to agent-{agent_id} output JSON.",
        )
    parser.add_argument(
        "--expected-agents",
        nargs="*",
        default=None,
        help="List of expected agent IDs (e.g. agent-a1 agent-b). Used to populate agents_missing.",
    )
    return parser.parse_args(argv)


def _find_project_root() -> Path:
    """Walk up from script to find project root (directory with contracts/)."""
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        if (candidate / "contracts").is_dir():
            return candidate
    return Path.cwd()


def _collect_input_files(args: argparse.Namespace, project_root: Path) -> list[Path]:
    """Resolve which agent output files to load, based on CLI args."""
    files: list[Path] = []

    # Explicit per-agent flags
    for agent_id in ("a1", "a2", "b", "c", "d"):
        path_str = getattr(args, f"agent_{agent_id}", None)
        if path_str:
            files.append(Path(path_str))

    # Glob pattern
    if args.agents:
        matched = sorted(glob_module.glob(args.agents))
        files.extend(Path(p) for p in matched)

    # Slug-based auto-discovery
    slug = args.slug or args.slug_flag
    if slug and not files:
        reports_dir = project_root / "reports"
        for agent_id in ("a1", "a2", "b", "c", "d"):
            candidate = reports_dir / f"{slug}-agent-{agent_id}.json"
            if candidate.exists():
                files.append(candidate)

    # Deduplicate while preserving order
    seen: set[Path] = set()
    unique: list[Path] = []
    for f in files:
        resolved = f.resolve()
        if resolved not in seen:
            seen.add(resolved)
            unique.append(f)

    return unique


def main(argv=None) -> int:
    args = _parse_args(argv)

    slug = args.slug or args.slug_flag
    project_root = _find_project_root()
    output_dir = Path(args.output_dir) if args.output_dir else (project_root / "reports")

    # Resolve input files
    input_files = _collect_input_files(args, project_root)
    if not input_files:
        print(
            "[ERROR] No agent output files found. Provide a slug, --agents glob, "
            "or --agent-a1/a2/b/c/d flags.",
            file=sys.stderr,
        )
        return 1

    # Load schemas
    try:
        agent_schema = _load_schema("agent-output.schema.json")
        merge_schema = _load_schema("merge-output.schema.json")
    except FileNotFoundError as exc:
        print(f"[ERROR] Schema load failed: {exc}", file=sys.stderr)
        return 1

    # Load + validate each agent output
    agent_outputs: list[dict] = []
    schema_error_count = 0
    agents_seen: list[str] = []

    for path in input_files:
        if not path.exists():
            print(f"[WARN] Agent file not found, skipping: {path}", file=sys.stderr)
            continue
        try:
            with open(path) as f:
                data = json.load(f)
        except json.JSONDecodeError as exc:
            print(f"[ERROR] Invalid JSON in {path}: {exc} — skipping", file=sys.stderr)
            schema_error_count += 1
            continue

        # Schema validate — reject malformed, log error, continue with valid
        errors = _validate(data, agent_schema, str(path))
        if errors:
            print(
                f"[ERROR] Schema validation failed for {path} "
                f"({len(errors)} error(s)) — skipping:",
                file=sys.stderr,
            )
            for e in errors[:5]:  # limit noise
                print(f"  • {e}", file=sys.stderr)
            schema_error_count += 1
            continue

        agent_id = data.get("agent_id", path.stem)
        agents_seen.append(agent_id)
        agent_outputs.append(data)
        print(f"[OK] Loaded {path} ({agent_id}, {len(data.get('findings', []))} findings)")

    if not agent_outputs:
        print("[ERROR] No valid agent outputs to merge.", file=sys.stderr)
        return 1

    # Auto-detect slug from first valid output if not provided
    if not slug:
        slug = agent_outputs[0].get("plugin_slug", "unknown")

    # Merge
    merged = merge_agent_findings(agent_outputs)
    merged["plugin_slug"] = slug

    # Populate agents_missing
    expected = args.expected_agents or []
    if expected:
        missing = [a for a in expected if a not in agents_seen]
        merged["merge_stats"]["agents_missing"] = missing
    merged["merge_stats"]["schema_errors"] = schema_error_count

    # Schema validate merged output — hard error on mismatch
    merge_errors = _validate(merged, merge_schema, "merged output")
    if merge_errors:
        print(
            f"[ERROR] Merged output failed schema validation "
            f"({len(merge_errors)} error(s)):",
            file=sys.stderr,
        )
        for e in merge_errors:
            print(f"  • {e}", file=sys.stderr)
        return 1

    # Write output files
    output_dir.mkdir(parents=True, exist_ok=True)
    archive_path = output_dir / f"{slug}-phase2-merged.json"
    canonical_path = output_dir / f"{slug}-phase2.json"

    with open(archive_path, "w") as f:
        json.dump(merged, f, indent=2)
    print(f"[OK] Archive written: {archive_path}")

    # Copy to canonical (gate reads this)
    import shutil
    shutil.copy2(archive_path, canonical_path)
    print(f"[OK] Canonical written: {canonical_path}")

    # Summary
    stats = merged["merge_stats"]
    print(
        f"\n[MERGE STATS]\n"
        f"  Agents merged:      {len(stats['agents_included'])}\n"
        f"  Total raw findings: {stats['total_raw']}\n"
        f"  After dedup:        {stats['total_deduplicated']}\n"
        f"  Duplicates merged:  {stats['duplicates_merged']}\n"
        f"  Conflicts flagged:  {stats['conflicts_flagged']}\n"
        f"  Schema errors:      {stats['schema_errors']}\n"
        f"  TP / FP / REVIEW:   {stats['tp_count']} / {stats['fp_count']} / {stats['review_count']}"
    )
    if stats.get("agents_missing"):
        print(f"  [WARN] Agents missing: {stats['agents_missing']}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
