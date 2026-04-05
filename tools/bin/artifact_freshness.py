#!/usr/bin/env python3
"""Shared freshness helpers for pipeline artifacts.

This module provides a small mtime-based dependency checker that can be:
- imported from Python scripts
- called from shell runners via the CLI

Batch 1 intentionally uses direct artifact dependencies only. It does not
attempt to fingerprint the full runtime environment.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from typing import Iterable, Optional, Sequence, Union

Pathish = Union[str, Path]


def _coerce_path(path: Pathish) -> Path:
    return path if isinstance(path, Path) else Path(path)


def newest_mtime(path: Pathish) -> Optional[float]:
    """Return the newest mtime for a file or directory tree.

    For directories, this walks the tree recursively and returns the newest
    mtime among the directory itself and all descendants. Missing paths return
    None.
    """
    root = _coerce_path(path)
    if not root.exists():
        return None

    try:
        newest = root.stat().st_mtime
    except OSError:
        return None

    if root.is_dir():
        for current_root, dirnames, filenames in os.walk(root, followlinks=False):
            current_path = Path(current_root)
            try:
                newest = max(newest, current_path.stat().st_mtime)
            except OSError:
                pass

            for name in dirnames:
                candidate = current_path / name
                try:
                    newest = max(newest, candidate.stat().st_mtime)
                except OSError:
                    pass

            for name in filenames:
                candidate = current_path / name
                try:
                    newest = max(newest, candidate.stat().st_mtime)
                except OSError:
                    pass

    return newest


def newest_input_mtime(paths: Iterable[Pathish]) -> Optional[float]:
    newest: Optional[float] = None
    for path in paths:
        current = newest_mtime(path)
        if current is None:
            continue
        newest = current if newest is None else max(newest, current)
    return newest


def is_fresh(output: Pathish, inputs: Sequence[Pathish]) -> bool:
    """Return True when output exists and is newer than every available input."""
    output_mtime = newest_mtime(output)
    if output_mtime is None:
        return False

    input_mtime = newest_input_mtime(inputs)
    if input_mtime is None:
        return True
    return output_mtime >= input_mtime


def resolve_canonical_phase3_path(phase3_dir: Pathish, slug: str) -> Optional[Path]:
    """Pick the freshest authoritative Phase 3 artifact for a slug.

    Rule:
    - prefer `<slug>-phase3.final.json` only when it exists and is not older than
      `<slug>-phase3.json`
    - otherwise use `<slug>-phase3.json`
    """
    phase3_root = _coerce_path(phase3_dir)
    gate_path = phase3_root / f"{slug}-phase3.json"
    final_path = phase3_root / f"{slug}-phase3.final.json"

    gate_mtime = newest_mtime(gate_path)
    final_mtime = newest_mtime(final_path)

    if final_mtime is not None and (gate_mtime is None or final_mtime >= gate_mtime):
        return final_path
    if gate_mtime is not None:
        return gate_path
    if final_mtime is not None:
        return final_path
    return None


def _cmd_newest_mtime(args: argparse.Namespace) -> int:
    newest = newest_input_mtime(args.path)
    if newest is None:
        return 1
    print(f"{newest:.6f}")
    return 0


def _cmd_is_fresh(args: argparse.Namespace) -> int:
    if is_fresh(args.output, args.input):
        print("fresh")
        return 0
    print("stale")
    return 1


def _cmd_canonical_phase3(args: argparse.Namespace) -> int:
    canonical = resolve_canonical_phase3_path(args.phase3_dir, args.slug)
    if canonical is None:
        return 1
    print(canonical)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Artifact freshness helper")
    subparsers = parser.add_subparsers(dest="command", required=True)

    newest_parser = subparsers.add_parser("newest-mtime", help="Print newest mtime across one or more paths")
    newest_parser.add_argument("path", nargs="+")
    newest_parser.set_defaults(func=_cmd_newest_mtime)

    fresh_parser = subparsers.add_parser("is-fresh", help="Exit 0 when output is fresh against inputs")
    fresh_parser.add_argument("--output", required=True)
    fresh_parser.add_argument("--input", action="append", default=[])
    fresh_parser.set_defaults(func=_cmd_is_fresh)

    canonical_parser = subparsers.add_parser("canonical-phase3", help="Resolve canonical Phase 3 artifact path")
    canonical_parser.add_argument("--phase3-dir", required=True)
    canonical_parser.add_argument("--slug", required=True)
    canonical_parser.set_defaults(func=_cmd_canonical_phase3)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
