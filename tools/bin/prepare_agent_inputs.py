#!/usr/bin/env python3
"""
prepare_agent_inputs.py — Session 16: IR Slicing Script

Slice a Phase 1 IR JSON into per-EP-group subsets for multi-agent Phase 2 analysis.
Also filters semgrep results per group.

Usage:
    python3 tools/bin/prepare_agent_inputs.py <slug>

    # Equivalent explicit form:
    python3 tools/bin/prepare_agent_inputs.py \
        --ir reports/<slug>-ir.json \
        --semgrep reports/<slug>-semgrep.json \
        --output-dir reports/

Outputs (one per agent group):
    <output-dir>/<slug>-ir-slice-ajax-unauth.json   # Agent A1: ajax_nopriv + admin_post_nopriv
    <output-dir>/<slug>-ir-slice-ajax-auth.json     # Agent A2: ajax_priv + admin_post
    <output-dir>/<slug>-ir-slice-rest.json          # Agent A3: rest_route
    <output-dir>/<slug>-ir-slice-shortcode.json     # Agent A4: shortcode + block
    <output-dir>/<slug>-ir-slice-other.json         # Agent A5: cron + init + template_redirect + filters
    <output-dir>/<slug>-semgrep-filtered-ajax-unauth.json
    <output-dir>/<slug>-semgrep-filtered-ajax-auth.json
    <output-dir>/<slug>-semgrep-filtered-rest.json
    <output-dir>/<slug>-semgrep-filtered-shortcode.json
    <output-dir>/<slug>-semgrep-filtered-other.json

Spec: multi-agent-plan.md:228-275
Schema: contracts/ir-slice.schema.json (v1.3.0)
"""

import argparse
import json
import os
import sys
from pathlib import Path

import jsonschema

# ---------------------------------------------------------------------------
# EP group definitions
# Source: multi-agent-plan.md:238-247
# ---------------------------------------------------------------------------
EP_GROUPS = [
    ("ajax-unauth", {"ajax_nopriv", "admin_post_nopriv"}),
    ("ajax-auth",   {"ajax_priv", "admin_post"}),
    ("rest",        {"rest_route"}),
    ("shortcode",   {"shortcode", "block"}),
    ("other",       {"cron", "init", "template_redirect", "filters"}),
]


def load_schema() -> dict:
    """Load ir-slice.schema.json relative to this script's location in tools/bin/."""
    script_dir = os.path.dirname(os.path.abspath(__file__))
    schema_path = os.path.join(script_dir, "..", "..", "contracts", "ir-slice.schema.json")
    schema_path = os.path.normpath(schema_path)
    if not os.path.isfile(schema_path):
        sys.exit(f"ERROR: Schema not found at {schema_path}")
    with open(schema_path, encoding="utf-8") as fh:
        return json.load(fh)


def slice_ir_for_group(ir: dict, ep_types: set) -> dict:
    """
    Filter entry_points by type.
    Keep sources/sinks/guards/anomalies matching filtered entry_point_ids.
    Keep metadata unchanged.
    unresolved_hooks and coverage_gaps are always [] — handled by Agent D from full IR.

    Source: multi-agent-plan.md:251-268
    """
    eps = [ep for ep in ir["entry_points"] if ep["type"] in ep_types]
    ep_ids = {ep["id"] for ep in eps}
    return {
        "metadata": ir["metadata"],
        "entry_points": eps,
        "sources":  [s for s in ir["sources"]   if s.get("entry_point_id") in ep_ids],
        "sinks":    [s for s in ir["sinks"]     if s.get("entry_point_id") in ep_ids],
        "guards":   [g for g in ir["guards"]    if g.get("entry_point_id") in ep_ids],
        "anomalies":[a for a in ir["anomalies"] if a.get("entry_point_id") in ep_ids],
        "unresolved_hooks": [],   # handled by Agent D, not per-group
        "coverage_gaps": [],      # handled by Agent D
    }


def filter_semgrep_for_group(semgrep: dict, ep_files: set, slug: str) -> dict:
    """
    Filter semgrep results to only hits whose path falls within files
    referenced by EPs in this group.

    ep_files: set of plugin-relative file paths (e.g. 'inc/class-admin.php')
              built from entry_points[].file AND entry_points[].callback.file.
    slug:     plugin slug used to normalise semgrep absolute paths.

    Semgrep artifacts store absolute paths (e.g.
    '/…/plugins/backwpup/inc/class-admin.php') while IR uses plugin-relative
    paths ('inc/class-admin.php').  We strip the 'plugins/<slug>/' prefix
    before comparing so both sides are on the same footing.
    """
    marker = f"plugins/{slug}/"

    def to_relative(path: str) -> str:
        idx = path.find(marker)
        return path[idx + len(marker):] if idx != -1 else path

    filtered_results = [
        r for r in semgrep.get("results", [])
        if to_relative(r.get("path", "")) in ep_files
    ]
    return {**semgrep, "results": filtered_results}


def validate_slice(slice_data: dict, schema: dict, label: str) -> None:
    """Validate slice_data against ir-slice.schema.json. Exits non-zero on failure."""
    try:
        jsonschema.validate(instance=slice_data, schema=schema)
    except jsonschema.ValidationError as exc:
        sys.exit(
            f"ERROR: Slice '{label}' failed schema validation.\n"
            f"  Path: {list(exc.absolute_path)}\n"
            f"  Message: {exc.message}"
        )


def write_json(path: str, data: dict) -> None:
    """Write data as indented JSON to path."""
    os.makedirs(os.path.dirname(path) if os.path.dirname(path) else ".", exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
        fh.write("\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Slice Phase 1 IR into per-EP-group files for multi-agent Phase 2."
    )
    parser.add_argument("slug", nargs="?", help="Plugin slug shorthand (uses reports/phase1/<slug>-*.json and writes into reports/)")
    parser.add_argument("--ir",         help="Path to <slug>-ir.json")
    parser.add_argument("--semgrep",    help="Path to <slug>-semgrep.json (missing path falls back to empty results)")
    parser.add_argument("--output-dir", dest="output_dir",
                        help="Directory to write output files into")
    args = parser.parse_args()

    script_dir = Path(__file__).resolve().parent
    root_dir = script_dir.parent.parent

    if args.slug:
        phase1_dir = root_dir / "reports" / "phase1"
        args.ir = args.ir or str(phase1_dir / f"{args.slug}-ir.json")
        args.semgrep = args.semgrep or str(phase1_dir / f"{args.slug}-semgrep.json")
        args.output_dir = args.output_dir or str(root_dir / "reports")

    if not args.ir or not args.semgrep or not args.output_dir:
        parser.error("Provide either <slug> shorthand or all of --ir, --semgrep, and --output-dir")

    # --- Fail fast if inputs missing ---
    if not os.path.isfile(args.ir):
        sys.exit(f"ERROR: IR file not found: {args.ir}")
    # --- Load inputs ---
    with open(args.ir, encoding="utf-8") as fh:
        ir = json.load(fh)
    semgrep_missing = not os.path.isfile(args.semgrep)
    if semgrep_missing:
        semgrep = {"results": []}
    else:
        with open(args.semgrep, encoding="utf-8") as fh:
            semgrep = json.load(fh)

    slug = ir["metadata"]["plugin_slug"]
    schema = load_schema()
    threat_context_rel = os.path.join("reports", f"{slug}-threat-context.json")

    print(f"IR: {args.ir} (slug={slug}, "
          f"eps={len(ir['entry_points'])}, sources={len(ir['sources'])}, "
          f"sinks={len(ir['sinks'])}, guards={len(ir['guards'])}, "
          f"anomalies={len(ir['anomalies'])})")
    if semgrep_missing:
        print(f"Semgrep: {args.semgrep} (missing -> using empty results)")
    else:
        print(f"Semgrep: {args.semgrep} ({len(semgrep.get('results', []))} results)")
    print(f"Output dir: {args.output_dir}")
    print()

    # --- Produce one slice per EP group ---
    for group_name, ep_types in EP_GROUPS:
        # IR slice
        slice_data = slice_ir_for_group(ir, ep_types)
        validate_slice(slice_data, schema, group_name)

        ir_out = os.path.join(args.output_dir, f"{slug}-ir-slice-{group_name}.json")
        write_json(ir_out, slice_data)

        # Build ep_files from BOTH registration file and callback file.
        # The registration file (entry_points[].file) is where add_action/add_filter
        # is called; the callback file (entry_points[].callback.file) is where the
        # handler lives. Semgrep hits typically appear in the handler file, so both
        # must be included to avoid false-zero filtering.
        ep_files = set()
        for ep in slice_data["entry_points"]:
            if ep.get("file"):
                ep_files.add(ep["file"])
            cb = ep.get("callback") or {}
            if cb.get("file"):
                ep_files.add(cb["file"])

        # Semgrep slice
        semgrep_slice = filter_semgrep_for_group(semgrep, ep_files, slug)
        sg_out = os.path.join(args.output_dir, f"{slug}-semgrep-filtered-{group_name}.json")
        write_json(sg_out, semgrep_slice)

        print(f"  [{group_name}] eps={len(slice_data['entry_points'])} "
              f"sources={len(slice_data['sources'])} "
              f"sinks={len(slice_data['sinks'])} "
              f"guards={len(slice_data['guards'])} "
              f"anomalies={len(slice_data['anomalies'])} "
              f"semgrep_hits={len(semgrep_slice['results'])} "
              f"→ schema OK")

    print()
    print(f"Done. Wrote {len(EP_GROUPS) * 2} files to {args.output_dir}")

    # --- Generate dispatch.json ---
    # Maps each agent-id to its input ir-slice file.
    # Agent A (a1-a5): per-EP-group ir-slice files
    # Agent B, C, D: full IR (they need cross-EP visibility)
    group_names = [g[0] for g in EP_GROUPS]  # ["ajax-unauth", "ajax-auth", "rest", "shortcode", "other"]
    agent_a_ids = [f"agent-a{i+1}" for i in range(len(group_names))]

    inputs = {}
    for i, gname in enumerate(group_names):
        inputs[agent_a_ids[i]] = os.path.join(args.output_dir, f"{slug}-ir-slice-{gname}.json")
    inputs["agent-b"] = args.ir
    inputs["agent-c"] = args.ir
    inputs["agent-d"] = args.ir

    agents_list = agent_a_ids + ["agent-b", "agent-c", "agent-d"]

    import os as _os
    dispatch = {
        "slug": slug,
        "agents": agents_list,
        "inputs": inputs,
        "source_dir": f"plugins/{slug}/",
        "threat_context_path": threat_context_rel,
        "timeout_seconds": 600,
        # quota_account: set CODEX_QUOTA_ACCOUNT env var before running orchestrator
        # to record which Codex account was used (helps debug cross-account quota issues).
        # Leave empty string if not provided.
        "quota_account": _os.environ.get("CODEX_QUOTA_ACCOUNT", ""),
        # provider_map: override provider per agent-id.
        # Keys: agent-a1 … agent-d.  Values: "codex" | "claude".
        # Omit an agent to use default_provider.
        # Example: {"agent-c": "claude", "agent-d": "claude"}
        "provider_map": {},
        # default_provider: used for any agent not listed in provider_map.
        # "codex" → Codex CLI (codex exec …)
        # "claude" → Claude Code CLI (claude -p --dangerously-skip-permissions …)
        "default_provider": "codex",
        # model_map: pin model per agent-id (only meaningful when provider="claude").
        # Keys: agent-id.  Values: Claude model name.
        # Source of truth: .claude/settings.local.json CLAUDE_MODEL = "claude-sonnet-4.6"
        # Omit an agent to use the claude CLI's current default model.
        # Example: {"agent-c": "claude-sonnet-4.6", "agent-d": "claude-sonnet-4.6"}
        "model_map": {},
    }
    dispatch_out = os.path.join(args.output_dir, f"{slug}-dispatch.json")
    write_json(dispatch_out, dispatch)
    print(f"Dispatch config written → {dispatch_out}")
    print(f"  Agents ({len(agents_list)}): {', '.join(agents_list)}")


if __name__ == "__main__":
    main()
