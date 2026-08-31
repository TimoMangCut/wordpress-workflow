#!/usr/bin/env python3
"""Validate a single-agent methodology review against the output contract.

Part of the enforcement layer for the source-first, single-agent WordPress review.
This is a deterministic tool, not a pipeline stage: it takes the JSON a review run
produced and checks it conforms to contracts/methodology-review.schema.json. A run is
not COMPLETE until its output validates here.

Usage:
    python3 tools/bin/validate_review.py <review.json> [--schema <path>]

Exit codes:
    0  valid
    1  schema violation(s) — printed with JSON paths
    2  usage / environment error (bad file, jsonschema missing)
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SCHEMA = REPO_ROOT / "contracts" / "methodology-review.schema.json"


def _load_json(path: Path, label: str) -> dict:
    try:
        with path.open(encoding="utf-8") as fh:
            return json.load(fh)
    except FileNotFoundError:
        print(f"error: {label} not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    except json.JSONDecodeError as exc:
        print(f"error: {label} is not valid JSON: {path}\n  {exc}", file=sys.stderr)
        raise SystemExit(2)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate a methodology review against its schema.")
    parser.add_argument("review", type=Path, help="Path to the review JSON produced by the run.")
    parser.add_argument("--schema", type=Path, default=DEFAULT_SCHEMA, help="Schema path (default: the methodology-review contract).")
    args = parser.parse_args(argv)

    try:
        import jsonschema
    except ImportError:
        print(
            "error: the 'jsonschema' package is required.\n"
            "  install it in the audit environment: pip install jsonschema\n"
            "  (the Docker helper image already ships it).",
            file=sys.stderr,
        )
        return 2

    schema = _load_json(args.schema, "schema")
    review = _load_json(args.review, "review")

    validator = jsonschema.Draft7Validator(schema)
    errors = sorted(validator.iter_errors(review), key=lambda e: list(e.absolute_path))
    if not errors:
        print(f"OK: {args.review} conforms to {args.schema.name}")
        return 0

    print(f"FAIL: {len(errors)} schema violation(s) in {args.review}:", file=sys.stderr)
    for err in errors:
        loc = "/".join(str(p) for p in err.absolute_path) or "<root>"
        print(f"  - at {loc}: {err.message}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
