#!/usr/bin/env python3
"""
Phase 3 LLM validation runner.

Reads Phase 2 output + Phase 1 IR (+ optional Semgrep + source) and asks Codex CLI
to produce a human-readable Markdown validation report.
"""

import argparse
import subprocess
import sys
from pathlib import Path
from typing import Optional

from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root


DEFAULT_TEMPLATE = """# Phase 3 LLM Validation for `{PLUGIN_SLUG}`

Load and validate these inputs:
- Phase 2 findings JSON: `{PHASE2_PATH}`
- Phase 1 IR JSON: `{IR_PATH}`
- Semgrep JSON (if exists): `{SEMGREP_PATH}`
- Plugin source code: `{PLUGIN_PATH}`

Task:
1) Validate each Phase 2 finding against actual source code and IR evidence.
2) Reject weak or non-impactful items; keep only meaningful security issues.
3) Be strict about Patchstack scope and false-positive reduction.
4) Include negative findings (why specific flagged areas are actually safe).
5) For each Confirmed finding and each Needs Dynamic Verification item, include mandatory PoC Evidence.
6) Produce concise, human-readable report.

PoC Evidence requirements (mandatory for Confirmed + Needs Dynamic Verification):
- Setup: plugin activation, required config/dependencies, and test users/roles.
- Preconditions: exact conditions to make the vulnerable path reachable.
- Attack: exact exploitation steps (UI flow and/or HTTP/fetch/curl/raw request examples).
- Observed result: concrete measurable impact after exploitation attempt.
- If you cannot provide reliable PoC evidence, do not keep the item as Confirmed.

Write output to: `{OUTPUT_PATH}`

Required Markdown sections:
- Plugin Overview
- Validation Summary
- Confirmed Findings
- Rejected Findings
- Needs Dynamic Verification
- Negative Findings
- Overall Assessment
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Phase 3 LLM validator: generate reports/phase3/<index>-<slug>.md"
    )
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"), help="Reports directory")
    parser.add_argument("--plugins-dir", default=str(_ROOT_DIR / "plugins"), help="Plugins directory")
    parser.add_argument("--prompt-template", default="", help="Prompt template path")
    parser.add_argument("--force", action="store_true", help="Overwrite existing phase3 markdown")
    parser.add_argument("--index", type=int, default=0, help="IR-order index for output file naming")
    parser.add_argument("--codex-bin", default="codex", help="Codex CLI executable")
    return parser.parse_args()


def to_abs(path_str: str, cwd: Path) -> Path:
    path = Path(path_str)
    if path.is_absolute():
        return path.resolve()
    return (cwd / path).resolve()


def to_rel(root: Path, path: Path) -> str:
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except Exception:
        return path.resolve().as_posix()


def resolve_template(args: argparse.Namespace, root_dir: Path) -> Optional[Path]:
    candidates = []
    if args.prompt_template:
        candidates.append(to_abs(args.prompt_template, Path.cwd()))
    candidates.extend([
        root_dir / "tools" / "config" / "phase3-prompt-template.md",
        root_dir / "phase3-prompt-template.md",
    ])
    for candidate in candidates:
        if candidate.exists() and candidate.is_file():
            return candidate
    return None


def load_template(template_path: Optional[Path]) -> str:
    if template_path is None:
        return DEFAULT_TEMPLATE
    return template_path.read_text(encoding="utf-8", errors="replace")


def compute_ir_index(slug: str, reports_dir: Path) -> int:
    layout = build_report_layout(reports_dir)
    ir_files = sorted(layout.phase1.glob("*-ir.json"))
    idx = 0
    for ir_file in ir_files:
        file_slug = ir_file.name[:-8]  # strip "-ir.json"
        if file_slug.startswith("plugin-"):
            continue
        idx += 1
        if file_slug == slug:
            return idx
    return 0


def main() -> int:
    args = parse_args()

    script_dir = Path(__file__).resolve().parent
    tools_dir = script_dir.parent
    root_dir = tools_dir.parent

    reports_dir = to_abs(args.reports_dir, Path.cwd())
    plugins_dir = to_abs(args.plugins_dir, Path.cwd())
    layout = build_report_layout(reports_dir).ensure()

    ir_path = layout.phase1 / f"{args.slug}-ir.json"
    phase2_path = layout.phase2 / f"{args.slug}-phase2.json"
    semgrep_path = layout.phase1 / f"{args.slug}-semgrep.json"
    plugin_path = plugins_dir / args.slug

    logs_dir = layout.logs
    phase3_dir = layout.phase3

    output_index = args.index if args.index > 0 else compute_ir_index(args.slug, reports_dir)
    if output_index <= 0:
        print(f"[!] Could not resolve IR-order index for slug: {args.slug}")
        return 1

    output_path = phase3_dir / f"{output_index}-{args.slug}.md"
    err_path = logs_dir / f"{args.slug}-phase3.err"

    if output_path.exists() and not args.force:
        print(f"[=] Skip {args.slug}: phase3 markdown already exists")
        return 0

    missing = []
    if not ir_path.exists():
        missing.append(ir_path.as_posix())
    if not phase2_path.exists():
        missing.append(phase2_path.as_posix())
    if not plugin_path.exists() or not plugin_path.is_dir():
        missing.append(plugin_path.as_posix())

    if missing:
        print("[!] Missing required inputs for phase 3:")
        for item in missing:
            print(f"    - {item}")
        return 1

    template_path = resolve_template(args, root_dir)
    template = load_template(template_path)

    replacements = {
        "{PLUGIN_SLUG}": args.slug,
        "{PHASE2_PATH}": to_rel(root_dir, phase2_path),
        "{IR_PATH}": to_rel(root_dir, ir_path),
        "{SEMGREP_PATH}": to_rel(root_dir, semgrep_path),
        "{PLUGIN_PATH}": to_rel(root_dir, plugin_path),
        "{OUTPUT_PATH}": to_rel(root_dir, output_path),
    }

    for key, value in replacements.items():
        template = template.replace(key, value)

    skill_hint = "Khi thuc hien WP plugin security audit, LUON load skill `$application-security` truoc."
    prompt = f"{skill_hint}\n\n{template}"

    print(f"=== Phase 3: {args.slug} ===")
    print(f"  Reports dir: {reports_dir.as_posix()}")
    print(f"  Plugins dir: {plugins_dir.as_posix()}")
    if template_path is not None:
        print(f"  Prompt template: {template_path.as_posix()}")
    else:
        print("  Prompt template: built-in default")
    print("  Running Codex CLI (LLM validation + markdown report)...")

    cmd = [
        args.codex_bin,
        "exec",
        "--full-auto",
        "--skip-git-repo-check",
        prompt,
    ]

    with err_path.open("w", encoding="utf-8", newline="\n") as err_file:
        result = subprocess.run(cmd, cwd=str(root_dir), stderr=err_file)

    if result.returncode != 0:
        print(f"  [!] Codex phase3 failed. See: {err_path.as_posix()}")
        return 1

    if not output_path.exists():
        print(f"  [!] Phase3 markdown not generated: {output_path.as_posix()}")
        print(f"  [!] See error log: {err_path.as_posix()}")
        return 1

    print(f"  Output: {output_path.as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
