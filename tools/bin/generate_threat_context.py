#!/usr/bin/env python3
"""
generate_threat_context.py — A-02: Deterministic threat context from keyword matching.

Input:  plugin source code directory
Output: reports/context/<slug>-threat-context.json

Logic:  keyword matching from tools/data/threat-profiles.json.
        No LLM. Purely deterministic.
"""

import argparse
import json
import os
import sys
from pathlib import Path

from report_paths import build_report_layout

_SCRIPT_DIR = Path(__file__).resolve().parent
_TOOLS_DIR = _SCRIPT_DIR.parent
_ROOT_DIR = _TOOLS_DIR.parent

DEFAULT_PROFILES_PATH = _TOOLS_DIR / "data" / "threat-profiles.json"
DEFAULT_PLUGINS_DIR = _ROOT_DIR / "plugins"
DEFAULT_REPORTS_DIR = _ROOT_DIR / "reports"

PHP_EXTENSIONS = {".php", ".inc"}
SCAN_EXTENSIONS = PHP_EXTENSIONS | {".js", ".ts", ".json", ".yaml", ".yml", ".txt", ".md"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate deterministic threat context for a plugin via keyword matching."
    )
    parser.add_argument("slug", help="Plugin slug (directory name under plugins/)")
    parser.add_argument(
        "--plugins-dir",
        default=str(DEFAULT_PLUGINS_DIR),
        help="Root plugins directory",
    )
    parser.add_argument(
        "--reports-dir",
        default=str(DEFAULT_REPORTS_DIR),
        help="Root reports directory",
    )
    parser.add_argument(
        "--profiles",
        default=str(DEFAULT_PROFILES_PATH),
        help="Path to threat-profiles.json",
    )
    parser.add_argument(
        "--output",
        default="",
        help="Override output JSON path (default: reports/context/<slug>-threat-context.json)",
    )
    return parser.parse_args()


def load_profiles(profiles_path: Path) -> dict:
    if not profiles_path.exists():
        print(f"[ERROR] threat-profiles.json not found: {profiles_path}", file=sys.stderr)
        sys.exit(1)
    try:
        return json.loads(profiles_path.read_text(encoding="utf-8"))
    except Exception as exc:
        print(f"[ERROR] Failed to parse threat-profiles.json: {exc}", file=sys.stderr)
        sys.exit(1)


def collect_source_files(plugin_dir: Path) -> list:
    """Return all scannable source files under plugin_dir, relative paths."""
    files = []
    for root, dirs, filenames in os.walk(plugin_dir):
        # Skip hidden dirs and common vendor/asset dirs that don't affect logic
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in ("node_modules", ".git")]
        for name in filenames:
            ext = Path(name).suffix.lower()
            if ext in SCAN_EXTENSIONS:
                files.append(Path(root) / name)
    return sorted(files)


def scan_file_for_keywords(file_path: Path, keywords: list) -> list:
    """Return list of (keyword, line_number) hits in file_path."""
    hits = []
    try:
        text = file_path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return hits
    text_lower = text.lower()
    for kw in keywords:
        kw_lower = kw.lower()
        if kw_lower in text_lower:
            # Find first line number with this keyword
            for i, line in enumerate(text_lower.splitlines(), start=1):
                if kw_lower in line:
                    hits.append({"keyword": kw, "line": i})
                    break
    return hits


def match_categories(plugin_dir: Path, profiles: dict) -> dict:
    """
    For each category, scan all source files and record:
      - matched: bool
      - matched_keywords: list of keywords found
      - evidence: list of {file, keyword, line}
      - priority_vulns: from profiles if category matched
    """
    source_files = collect_source_files(plugin_dir)
    results = {}

    for category, profile in profiles.items():
        keywords = profile.get("keywords", [])
        priority_vulns = profile.get("priority_vulns", [])

        matched_keywords = set()
        evidence = []

        for f in source_files:
            hits = scan_file_for_keywords(f, keywords)
            for hit in hits:
                kw = hit["keyword"]
                rel_path = f.relative_to(plugin_dir).as_posix()
                if kw not in matched_keywords:
                    matched_keywords.add(kw)
                    evidence.append({"file": rel_path, "keyword": kw, "line": hit["line"]})

        matched = len(matched_keywords) > 0
        results[category] = {
            "matched": matched,
            "matched_keywords": sorted(matched_keywords),
            "evidence": sorted(evidence, key=lambda x: x["file"]),
            "priority_vulns": priority_vulns if matched else [],
        }

    return results


def build_output(slug: str, plugin_dir: Path, profiles_path: Path, profiles: dict) -> dict:
    categories = match_categories(plugin_dir, profiles)
    matched_categories = [cat for cat, data in categories.items() if data["matched"]]
    all_priority_vulns = []
    seen_vulns = set()
    for cat in matched_categories:
        for vuln in categories[cat]["priority_vulns"]:
            if vuln not in seen_vulns:
                all_priority_vulns.append(vuln)
                seen_vulns.add(vuln)

    return {
        "plugin_slug": slug,
        "profiles_source": profiles_path.as_posix(),
        "matched_categories": matched_categories,
        "priority_vulns": all_priority_vulns,
        "categories": categories,
        "generator": "generate_threat_context.py",
        "method": "deterministic_keyword_matching",
    }


def main() -> int:
    args = parse_args()

    plugins_dir = Path(args.plugins_dir).resolve()
    reports_dir = Path(args.reports_dir).resolve()
    profiles_path = Path(args.profiles).resolve()

    plugin_dir = plugins_dir / args.slug
    if not plugin_dir.exists() or not plugin_dir.is_dir():
        print(f"[ERROR] Plugin directory not found: {plugin_dir}", file=sys.stderr)
        return 1

    profiles = load_profiles(profiles_path)

    layout = build_report_layout(reports_dir).ensure()
    output_path = Path(args.output).resolve() if args.output else layout.threat_context(args.slug)
    output_path.parent.mkdir(parents=True, exist_ok=True)

    print(f"=== Threat Context: {args.slug} ===")
    print(f"  Plugin dir:    {plugin_dir.as_posix()}")
    print(f"  Profiles:      {profiles_path.as_posix()}")
    print(f"  Output:        {output_path.as_posix()}")

    result = build_output(args.slug, plugin_dir, profiles_path, profiles)
    output_path.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")

    matched = result["matched_categories"]
    vulns = result["priority_vulns"]
    print(f"  Matched categories: {matched if matched else '(none)'}")
    print(f"  Priority vulns: {vulns if vulns else '(none)'}")
    print(f"[OK] {output_path.as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
