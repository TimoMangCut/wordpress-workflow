#!/usr/bin/env python3
"""Validate and normalize Phase 3 skeptic review JSON artifacts."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any, Dict, Iterable

ALLOWED_ORIGINAL_STATES = {"UNCERTAIN", "RISK_NOTE"}
ALLOWED_VERDICT_CHANGES = {"reject", "downgrade", "keep", "upgrade"}
ALLOWED_FINAL_STATES = {"REJECTED", "UNCERTAIN", "RISK_NOTE"}


def _clean_text(value: Any) -> str:
    return str(value or "").strip()


def normalize_phase3_review_document(data: Any, *, slug: str | None = None) -> Dict[str, Any]:
    if not isinstance(data, dict):
        raise ValueError("Phase 3 review payload must be a JSON object.")

    normalized = dict(data)
    if "reviews" not in normalized and isinstance(normalized.get("findings"), list):
        normalized["reviews"] = normalized.get("findings")

    plugin_slug = _clean_text(normalized.get("plugin_slug"))
    if not plugin_slug:
        raise ValueError("Phase 3 review payload missing non-empty `plugin_slug`.")
    if slug and plugin_slug != slug:
        raise ValueError(
            f"Phase 3 review payload plugin_slug mismatch: expected `{slug}`, got `{plugin_slug}`."
        )

    reviews = normalized.get("reviews")
    if not isinstance(reviews, list):
        raise ValueError("Phase 3 review payload must contain `reviews` as a JSON array.")

    cleaned_reviews = []
    for idx, row in enumerate(reviews):
        if not isinstance(row, dict):
            raise ValueError(f"Phase 3 review row `reviews[{idx}]` must be a JSON object.")

        finding_id = _clean_text(row.get("finding_id"))
        if not finding_id:
            raise ValueError(f"Phase 3 review row `reviews[{idx}]` missing non-empty `finding_id`.")

        clean_row = dict(row)
        clean_row["finding_id"] = finding_id

        original_status = row.get("original_status")
        if original_status is not None:
            normalized_state = _clean_text(original_status).upper()
            if normalized_state not in ALLOWED_ORIGINAL_STATES:
                raise ValueError(
                    f"Phase 3 review row `reviews[{idx}]` has invalid original_status `{original_status}`."
                )
            clean_row["original_status"] = normalized_state

        verdict_change = row.get("verdict_change")
        if verdict_change is not None:
            normalized_change = _clean_text(verdict_change).lower()
            if normalized_change not in ALLOWED_VERDICT_CHANGES:
                raise ValueError(
                    f"Phase 3 review row `reviews[{idx}]` has invalid verdict_change `{verdict_change}`."
                )
            clean_row["verdict_change"] = normalized_change

        proposed_final_state = (
            row.get("proposed_final_state")
            or row.get("suggested_final_state")
            or row.get("final_state")
        )
        if proposed_final_state is not None:
            normalized_final = _clean_text(proposed_final_state).upper()
            if normalized_final not in ALLOWED_FINAL_STATES:
                raise ValueError(
                    f"Phase 3 review row `reviews[{idx}]` has invalid proposed_final_state `{proposed_final_state}`."
                )
            clean_row["proposed_final_state"] = normalized_final

        if "verdict_change" not in clean_row and "proposed_final_state" not in clean_row:
            raise ValueError(
                f"Phase 3 review row `reviews[{idx}]` must declare verdict_change or proposed_final_state."
            )

        cleaned_reviews.append(clean_row)

    normalized["plugin_slug"] = plugin_slug
    normalized["reviews"] = cleaned_reviews
    return normalized


def load_phase3_review_file(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def validate_phase3_review_file(path: Path, *, slug: str | None = None) -> Dict[str, Any]:
    data = load_phase3_review_file(path)
    return normalize_phase3_review_document(data, slug=slug)


def rewrite_phase3_review_file(path: Path, normalized: Dict[str, Any]) -> None:
    path.write_text(json.dumps(normalized, indent=2) + "\n", encoding="utf-8")


def _cmd_validate_file(args: argparse.Namespace) -> int:
    path = Path(args.path).resolve()
    try:
        normalized = validate_phase3_review_file(path, slug=args.slug or None)
    except Exception as exc:
        print(str(exc))
        return 1
    if args.write_normalized:
        rewrite_phase3_review_file(path, normalized)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate Phase 3 review JSON artifacts.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_file = subparsers.add_parser("validate-file", help="Validate a phase3 review JSON file")
    validate_file.add_argument("--path", required=True)
    validate_file.add_argument("--slug", default="")
    validate_file.add_argument("--write-normalized", action="store_true")
    validate_file.set_defaults(func=_cmd_validate_file)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
