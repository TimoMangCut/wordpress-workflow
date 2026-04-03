#!/usr/bin/env python3
"""
Extract premium WordPress plugin source packages into plugins/ safely.

What it does:
1) Recursively extracts zip files (zip-in-zip supported) into a temp workspace.
2) Detects plugin roots by scanning PHP headers for "Plugin Name:".
3) Copies valid plugin roots into target plugins directory.
4) Writes a manifest JSON with imported/skipped details.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import tempfile
import zipfile
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Tuple


PLUGIN_NAME_RE = re.compile(r"^\s*(?:/\*+|\*+|//+)?\s*Plugin\s+Name\s*:\s*(.+?)\s*$", re.IGNORECASE | re.MULTILINE)
GENERIC_NON_PLUGIN_DIRS = {
    "inc",
    "includes",
    "include",
    "vendor",
    "vendors",
    "src",
    "lib",
    "library",
}


@dataclass
class ArchiveResult:
    zip_path: str
    extracted_dir: str
    status: str
    reason: str = ""


@dataclass
class Candidate:
    slug: str
    plugin_name: str
    root_dir: str
    main_file: str
    source_zip: str


@dataclass
class ImportResult:
    slug: str
    action: str
    reason: str
    source_zip: str
    source_root: str
    destination: str
    plugin_name: str
    main_file: str


def now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def default_premium_dir() -> Path:
    candidates = [
        Path("/mnt/c/Users/vibpentest/Downloads/premium"),
        Path("C:/Users/vibpentest/Downloads/premium"),
    ]
    for c in candidates:
        if c.exists():
            return c
    return candidates[0]


def parse_args(repo_root: Path) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract premium plugin zips recursively and import valid plugin roots to plugins/."
    )
    parser.add_argument(
        "--premium-dir",
        default=str(default_premium_dir()),
        help="Source directory containing premium zip archives.",
    )
    parser.add_argument(
        "--plugins-dir",
        default=str(repo_root / "plugins"),
        help="Destination plugins directory.",
    )
    parser.add_argument(
        "--manifest",
        default=str(repo_root / "reports" / "premium-import-manifest.json"),
        help="Manifest JSON output path.",
    )
    parser.add_argument(
        "--temp-dir",
        default="",
        help="Temp workspace directory. Default: auto /tmp (deleted after run unless --keep-temp).",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite existing plugins/<slug> if already exists.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Detect and report only, do not copy to plugins/.",
    )
    parser.add_argument(
        "--keep-temp",
        action="store_true",
        help="Keep extraction temp workspace after run.",
    )
    parser.add_argument(
        "--max-header-bytes",
        type=int,
        default=16384,
        help="Bytes to read from start of PHP file for plugin header detection.",
    )
    return parser.parse_args()


def find_top_level_archives(premium_dir: Path) -> List[Path]:
    return sorted([p for p in premium_dir.iterdir() if p.is_file() and p.suffix.lower() == ".zip"])


def safe_extract_zip(zip_path: Path, out_dir: Path) -> Tuple[bool, str]:
    try:
        with zipfile.ZipFile(zip_path, "r") as zf:
            zf.extractall(out_dir)
        return True, ""
    except Exception as exc:  # noqa: BLE001
        return False, f"{type(exc).__name__}: {exc}"


def extract_recursive_archives(top_archives: List[Path], workspace: Path) -> Tuple[List[ArchiveResult], Dict[Path, Path]]:
    """
    Returns:
      - archive results list
      - mapping extracted_root_dir -> source zip path
    """
    results: List[ArchiveResult] = []
    extracted_roots: Dict[Path, Path] = {}
    queue: List[Path] = list(top_archives)
    seen: set[str] = set()
    idx = 0

    while queue:
        archive = queue.pop(0)
        key = str(archive.resolve())
        if key in seen:
            continue
        seen.add(key)
        idx += 1

        extract_dir = workspace / f"extract_{idx:05d}"
        extract_dir.mkdir(parents=True, exist_ok=True)
        ok, reason = safe_extract_zip(archive, extract_dir)
        if not ok:
            results.append(
                ArchiveResult(
                    zip_path=str(archive),
                    extracted_dir=str(extract_dir),
                    status="failed",
                    reason=reason,
                )
            )
            continue

        results.append(
            ArchiveResult(
                zip_path=str(archive),
                extracted_dir=str(extract_dir),
                status="ok",
            )
        )
        extracted_roots[extract_dir] = archive

        nested = sorted([p for p in extract_dir.rglob("*.zip") if p.is_file()])
        queue.extend(nested)

    return results, extracted_roots


def detect_plugin_header(php_file: Path, max_bytes: int) -> Optional[str]:
    try:
        with php_file.open("rb") as f:
            head = f.read(max_bytes).decode("utf-8", "ignore")
    except Exception:  # noqa: BLE001
        return None

    m = PLUGIN_NAME_RE.search(head)
    if not m:
        return None
    return m.group(1).strip()


def choose_source_zip(path: Path, extracted_roots: Dict[Path, Path]) -> Optional[Path]:
    # Longest matching extracted root wins.
    winners: List[Tuple[int, Path]] = []
    for root, source_zip in extracted_roots.items():
        try:
            path.relative_to(root)
            winners.append((len(str(root)), source_zip))
        except ValueError:
            continue
    if not winners:
        return None
    winners.sort(key=lambda x: x[0], reverse=True)
    return winners[0][1]


def find_plugin_candidates(extracted_roots: Dict[Path, Path], max_header_bytes: int) -> List[Candidate]:
    candidates_by_root: Dict[Path, Candidate] = {}

    for extracted_root in extracted_roots:
        for php in extracted_root.rglob("*.php"):
            if "__MACOSX" in php.parts:
                continue
            plugin_name = detect_plugin_header(php, max_header_bytes)
            if not plugin_name:
                continue

            # Strict root detection:
            # 1) use first folder under extracted root as plugin root
            # 2) accept only when header file is directly in plugin root (not in inc/vendor/etc)
            try:
                rel = php.relative_to(extracted_root)
            except ValueError:
                continue

            if len(rel.parts) == 1:
                root_dir = extracted_root
            else:
                root_dir = extracted_root / rel.parts[0]

            if php.parent != root_dir:
                continue

            slug = root_dir.name
            if root_dir == extracted_root:
                # Archive without top-level plugin folder: derive stable slug from main file.
                slug = php.stem
            if slug.lower() in GENERIC_NON_PLUGIN_DIRS:
                continue

            source_zip = choose_source_zip(root_dir, extracted_roots)
            source_zip_str = str(source_zip) if source_zip else "[unknown]"

            existing = candidates_by_root.get(root_dir)
            if existing:
                # Prefer candidate whose main file matches slug.php
                preferred = (php.name.lower() == f"{slug.lower()}.php")
                current_preferred = (Path(existing.main_file).name.lower() == f"{slug.lower()}.php")
                if preferred and not current_preferred:
                    candidates_by_root[root_dir] = Candidate(
                        slug=slug,
                        plugin_name=plugin_name,
                        root_dir=str(root_dir),
                        main_file=str(php),
                        source_zip=source_zip_str,
                    )
                continue

            candidates_by_root[root_dir] = Candidate(
                slug=slug,
                plugin_name=plugin_name,
                root_dir=str(root_dir),
                main_file=str(php),
                source_zip=source_zip_str,
            )

    return sorted(candidates_by_root.values(), key=lambda c: (c.slug.lower(), c.root_dir.lower()))


def copy_candidate(candidate: Candidate, plugins_dir: Path, overwrite: bool, dry_run: bool) -> ImportResult:
    src = Path(candidate.root_dir)
    dest = plugins_dir / candidate.slug

    if dest.exists() and not overwrite:
        return ImportResult(
            slug=candidate.slug,
            action="skipped",
            reason="destination_exists",
            source_zip=candidate.source_zip,
            source_root=candidate.root_dir,
            destination=str(dest),
            plugin_name=candidate.plugin_name,
            main_file=candidate.main_file,
        )

    if dry_run:
        return ImportResult(
            slug=candidate.slug,
            action="would_import",
            reason="dry_run",
            source_zip=candidate.source_zip,
            source_root=candidate.root_dir,
            destination=str(dest),
            plugin_name=candidate.plugin_name,
            main_file=candidate.main_file,
        )

    if dest.exists() and overwrite:
        shutil.rmtree(dest)

    shutil.copytree(src, dest)
    return ImportResult(
        slug=candidate.slug,
        action="imported",
        reason="ok",
        source_zip=candidate.source_zip,
        source_root=candidate.root_dir,
        destination=str(dest),
        plugin_name=candidate.plugin_name,
        main_file=candidate.main_file,
    )


def main() -> int:
    repo_root = Path(__file__).resolve().parents[2]
    args = parse_args(repo_root)

    premium_dir = Path(args.premium_dir).expanduser().resolve()
    plugins_dir = Path(args.plugins_dir).expanduser().resolve()
    manifest_path = Path(args.manifest).expanduser().resolve()

    if not premium_dir.exists() or not premium_dir.is_dir():
        print(f"[!] premium directory not found: {premium_dir}")
        return 1
    if not plugins_dir.exists() or not plugins_dir.is_dir():
        print(f"[!] plugins directory not found: {plugins_dir}")
        return 1

    top_archives = find_top_level_archives(premium_dir)
    if not top_archives:
        print(f"[!] no .zip archives found in: {premium_dir}")
        return 1

    if args.temp_dir:
        workspace = Path(args.temp_dir).expanduser().resolve()
        workspace.mkdir(parents=True, exist_ok=True)
        auto_temp = False
    else:
        workspace = Path(tempfile.mkdtemp(prefix="premium-extract-"))
        auto_temp = True

    print(f"[*] premium dir: {premium_dir}")
    print(f"[*] plugins dir: {plugins_dir}")
    print(f"[*] workspace:   {workspace}")
    print(f"[*] top archives: {len(top_archives)}")

    archive_results, extracted_roots = extract_recursive_archives(top_archives, workspace)
    ok_archives = [r for r in archive_results if r.status == "ok"]
    failed_archives = [r for r in archive_results if r.status != "ok"]
    print(f"[*] extracted archives: {len(ok_archives)} (failed: {len(failed_archives)})")

    candidates = find_plugin_candidates(extracted_roots, args.max_header_bytes)
    print(f"[*] plugin candidates detected: {len(candidates)}")

    imports: List[ImportResult] = []
    seen_slugs: set[str] = set()
    for c in candidates:
        if c.slug in seen_slugs:
            imports.append(
                ImportResult(
                    slug=c.slug,
                    action="skipped",
                    reason="duplicate_slug_in_batch",
                    source_zip=c.source_zip,
                    source_root=c.root_dir,
                    destination=str(plugins_dir / c.slug),
                    plugin_name=c.plugin_name,
                    main_file=c.main_file,
                )
            )
            continue
        seen_slugs.add(c.slug)
        imports.append(copy_candidate(c, plugins_dir, args.overwrite, args.dry_run))

    summary = {
        "archives_top_level": len(top_archives),
        "archives_processed": len(archive_results),
        "archives_failed": len(failed_archives),
        "plugin_candidates": len(candidates),
        "imported": sum(1 for i in imports if i.action == "imported"),
        "would_import": sum(1 for i in imports if i.action == "would_import"),
        "skipped_exists": sum(1 for i in imports if i.reason == "destination_exists"),
        "skipped_duplicate_slug_in_batch": sum(1 for i in imports if i.reason == "duplicate_slug_in_batch"),
    }

    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest = {
        "ts_utc": now_iso(),
        "premium_dir": str(premium_dir),
        "plugins_dir": str(plugins_dir),
        "workspace": str(workspace),
        "options": {
            "overwrite": bool(args.overwrite),
            "dry_run": bool(args.dry_run),
            "keep_temp": bool(args.keep_temp),
            "max_header_bytes": int(args.max_header_bytes),
        },
        "summary": summary,
        "archives": [asdict(r) for r in archive_results],
        "imports": [asdict(i) for i in imports],
    }
    with manifest_path.open("w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2, ensure_ascii=True)

    print("[*] summary:")
    for k, v in summary.items():
        print(f"    - {k}: {v}")
    print(f"[*] manifest: {manifest_path}")

    if auto_temp and not args.keep_temp:
        shutil.rmtree(workspace, ignore_errors=True)
    elif auto_temp and args.keep_temp:
        print(f"[*] kept workspace: {workspace}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
