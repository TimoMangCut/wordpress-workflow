#!/usr/bin/env python3
"""Normalize per-agent Phase 2 outputs before validation or merge."""

from __future__ import annotations

import argparse
import json
import re
import sys
from copy import deepcopy
from pathlib import Path
from typing import Any


VERDICT_NORMALIZE = {
    "TP": "TP",
    "TRUE_POSITIVE": "TP",
    "TRUEPOSITIVE": "TP",
    "VALID": "TP",
    "CONFIRMED": "TP",
    "FP": "FP",
    "FALSE_POSITIVE": "FP",
    "FALSEPOSITIVE": "FP",
    "REJECTED": "FP",
    "REVIEW": "REVIEW",
    "UNCERTAIN": "REVIEW",
    "HYPOTHESIS": "REVIEW",
    "SIGNAL": "REVIEW",
    "RISK_NOTE": "REVIEW",
    "NEEDS_REVIEW": "REVIEW",
}

SEVERITY_NORMALIZE = {
    "critical": "critical",
    "high": "high",
    "medium": "medium",
    "moderate": "medium",
    "low": "low",
    "info": "informational",
    "informational": "informational",
}

AUTH_NORMALIZE = {
    "unauthenticated": "none",
    "anonymous": "none",
    "public": "none",
    "any": "none",
    "none": "none",
    "any logged-in user": "subscriber",
    "any logged in user": "subscriber",
    "logged_in": "subscriber",
    "logged-in": "subscriber",
    "authenticated": "subscriber",
    "authenticated_user": "subscriber",
    "customer": "subscriber",
    "subscriber": "subscriber",
    "contributor": "contributor",
    "author": "author",
    "editor": "editor",
    "editor+": "editor",
    "admin": "admin",
    "administrator": "admin",
    "administrators": "admin",
    "admin+": "admin",
    "privileged": "admin",
    "super admin": "system",
    "superadmin": "system",
    "network admin": "system",
    "system": "system",
    "unknown": "unknown",
}

VALID_SEVERITIES = {"critical", "high", "medium", "low", "informational"}
VALID_AUTH = {"none", "subscriber", "contributor", "author", "editor", "admin", "system", "unknown"}
VALID_VERDICTS = {"TP", "FP", "REVIEW"}
COMMON_NULL_FIELDS = (
    "entry_point_id",
    "store_entry_point_id",
    "load_entry_point_id",
    "source_function",
    "source_file_path",
    "source_line_number",
    "sink_function",
    "sink_file_path",
    "sink_line_number",
    "reasoning",
    "fp_reason",
    "fp_evidence",
    "review_reason",
    "poc_description",
    "storage_key",
    "patchstack_eligible",
    "remediation",
    "cwe_id",
)
TP_REQUIRED_FIELDS = (
    "entry_point_id",
    "reasoning",
    "source_file_path",
    "source_line_number",
    "source_function",
    "sink_file_path",
    "sink_line_number",
    "sink_function",
)


def find_project_root() -> Path:
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        if (candidate / "contracts").is_dir() and (candidate / "plugins").is_dir():
            return candidate
    return Path.cwd()


def optional_text(value: Any) -> str | None:
    if value is None:
        return None
    if isinstance(value, str):
        value = value.strip()
        return value or None
    if isinstance(value, (dict, list)):
        try:
            return json.dumps(value, ensure_ascii=False, sort_keys=True)
        except Exception:
            return str(value)
    return str(value)


def coerce_int(value: Any, default: int | None = None) -> int | None:
    if value is None or value == "":
        return default
    try:
        if isinstance(value, bool):
            return int(value)
        if isinstance(value, (int, float)):
            return int(value)
        return int(float(str(value).strip()))
    except Exception:
        return default


def coerce_confidence(value: Any) -> float | None:
    if value is None or value == "":
        return None
    try:
        confidence = float(value)
    except Exception:
        return None
    if confidence < 0:
        return 0.0
    if confidence > 1:
        return 1.0
    return confidence


def normalize_verdict(value: Any) -> str:
    text = (optional_text(value) or "").upper().replace("-", "_").replace(" ", "_")
    return VERDICT_NORMALIZE.get(text, "REVIEW")


def normalize_severity(value: Any) -> str:
    text = (optional_text(value) or "").strip().lower()
    return SEVERITY_NORMALIZE.get(text, "medium")


def normalize_auth(value: Any) -> str:
    text = (optional_text(value) or "").strip().lower()
    normalized = AUTH_NORMALIZE.get(text, "unknown")
    return normalized if normalized in VALID_AUTH else "unknown"


def parse_anchor(anchor: Any) -> tuple[str | None, int | None]:
    text = optional_text(anchor)
    if not text:
        return None, None
    match = re.match(r"^(.*?):(\d+)$", text)
    if not match:
        return text, None
    return match.group(1), int(match.group(2))


def repair_invalid_backslashes(text: str) -> str:
    return re.sub(r'(?<!\\)\\(?!["\\/bfnrtu])', r"\\\\", text)


def extract_json_candidates(raw_text: str) -> list[str]:
    stripped = raw_text.strip()
    candidates: list[str] = []
    if stripped:
        candidates.append(stripped)

    if stripped.startswith("```"):
        fenced = re.sub(r"^```(?:json)?\s*|\s*```$", "", stripped, flags=re.IGNORECASE | re.DOTALL).strip()
        if fenced:
            candidates.append(fenced)

    start = stripped.find("{")
    end = stripped.rfind("}")
    if start != -1 and end != -1 and end > start:
        candidates.append(stripped[start : end + 1])

    unique: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        if candidate not in seen:
            seen.add(candidate)
            unique.append(candidate)
    return unique


def load_json_with_repair(path: Path) -> tuple[dict, list[str]]:
    raw_text = path.read_text(encoding="utf-8", errors="replace")
    decoder = json.JSONDecoder()
    last_error: Exception | None = None

    for candidate in extract_json_candidates(raw_text):
        for variant, note in ((candidate, None), (repair_invalid_backslashes(candidate), "escaped_invalid_backslashes")):
            try:
                return json.loads(variant), ([note] if note else [])
            except json.JSONDecodeError as exc:
                last_error = exc
                try:
                    value, end = decoder.raw_decode(variant)
                    tail = variant[end:].strip()
                    if not tail or set(tail) <= {"}"}:
                        notes = []
                        if note:
                            notes.append(note)
                        if tail:
                            notes.append("trimmed_trailing_json_suffix")
                        return value, notes
                except Exception:
                    pass

    if last_error:
        raise ValueError(f"{type(last_error).__name__}: {last_error}") from last_error
    raise ValueError("No JSON object found")


def normalize_negative_findings(values: Any) -> list[dict]:
    normalized: list[dict] = []
    for item in values or []:
        if isinstance(item, str):
            text = optional_text(item)
            if text:
                normalized.append({"area": text, "reason": "reviewed without actionable issue"})
            continue
        if not isinstance(item, dict):
            continue
        area = optional_text(item.get("area")) or optional_text(item.get("file")) or optional_text(item.get("surface"))
        reason = optional_text(item.get("reason")) or optional_text(item.get("note")) or optional_text(item.get("summary"))
        if area or reason:
            normalized.append(
                {
                    "area": area or "unspecified",
                    "reason": reason or "reviewed without actionable issue",
                }
            )
    return normalized


def normalize_fp_evidence(value: Any) -> dict | None:
    if isinstance(value, dict):
        return value
    return None


def normalize_plugin_relative_path(value: Any, expected_plugin_slug: str | None, *, field_name: str, notes: list[str]) -> str | None:
    text = optional_text(value)
    if not text:
        return None

    normalized = text.strip().replace("\\", "/")
    normalized = re.sub(r"/+", "/", normalized)
    normalized = normalized.removeprefix("./")

    marker = None
    if expected_plugin_slug:
        marker = f"/plugins/{expected_plugin_slug}/"
        if marker in normalized:
            normalized = normalized.split(marker, 1)[1]
            notes.append(f"{field_name}:stripped_plugin_prefix")
        else:
            prefix = f"plugins/{expected_plugin_slug}/"
            if normalized.startswith(prefix):
                normalized = normalized[len(prefix):]
                notes.append(f"{field_name}:stripped_relative_plugin_prefix")
            elif normalized.startswith(f"{expected_plugin_slug}/"):
                normalized = normalized[len(expected_plugin_slug) + 1 :]
                notes.append(f"{field_name}:stripped_slug_prefix")

    if Path(normalized).is_absolute():
        if expected_plugin_slug:
            project_root = find_project_root()
            plugin_root = (project_root / "plugins" / expected_plugin_slug).resolve()
            try:
                normalized = Path(normalized).resolve().relative_to(plugin_root).as_posix()
                notes.append(f"{field_name}:made_relative_to_plugin_root")
            except Exception:
                notes.append(f"{field_name}:rejected_absolute_outside_plugin_root")
                return None
        else:
            notes.append(f"{field_name}:rejected_absolute_without_plugin_slug")
            return None

    parts = [part for part in normalized.split("/") if part not in {"", "."}]
    if any(part == ".." for part in parts):
        notes.append(f"{field_name}:rejected_path_traversal")
        return None

    normalized = "/".join(parts)
    return normalized or None


def normalize_finding(raw_finding: Any, index: int, agent_id: str) -> dict:
    finding = deepcopy(raw_finding) if isinstance(raw_finding, dict) else {}
    finding_notes: list[str] = []

    source_anchor_path, source_anchor_line = parse_anchor(finding.get("source_anchor"))
    sink_anchor_path, sink_anchor_line = parse_anchor(finding.get("sink_anchor"))

    original_verdict = optional_text(finding.get("verdict"))
    verdict = normalize_verdict(original_verdict)
    finding["finding_id"] = optional_text(finding.get("finding_id")) or f"{agent_id}-f{index:03d}"
    finding["verdict"] = verdict
    if original_verdict and original_verdict != verdict:
        finding["original_verdict"] = original_verdict

    finding["vuln_type"] = optional_text(finding.get("vuln_type")) or optional_text(finding.get("type")) or "unknown_issue"
    finding["severity"] = normalize_severity(finding.get("severity"))

    original_auth = optional_text(finding.get("auth_required"))
    auth_required = normalize_auth(original_auth)
    finding["auth_required"] = auth_required
    if original_auth and original_auth != auth_required:
        finding["original_auth_required"] = original_auth

    confidence = coerce_confidence(finding.get("confidence"))
    if confidence is None:
        finding.pop("confidence", None)
    else:
        finding["confidence"] = confidence

    finding["entry_point_id"] = optional_text(finding.get("entry_point_id")) or optional_text(finding.get("load_entry_point_id"))
    finding["store_entry_point_id"] = optional_text(finding.get("store_entry_point_id"))
    finding["load_entry_point_id"] = optional_text(finding.get("load_entry_point_id"))

    finding["source_function"] = optional_text(finding.get("source_function"))
    finding["source_file_path"] = normalize_plugin_relative_path(
        optional_text(finding.get("source_file_path")) or source_anchor_path,
        finding.get("plugin_slug") or None,
        field_name="source_file_path",
        notes=finding_notes,
    )
    finding["source_line_number"] = coerce_int(finding.get("source_line_number"), source_anchor_line)

    finding["sink_function"] = optional_text(finding.get("sink_function"))
    finding["sink_file_path"] = normalize_plugin_relative_path(
        optional_text(finding.get("sink_file_path"))
        or optional_text(finding.get("file_path"))
        or sink_anchor_path,
        finding.get("plugin_slug") or None,
        field_name="sink_file_path",
        notes=finding_notes,
    )
    finding["sink_line_number"] = coerce_int(
        finding.get("sink_line_number"),
        coerce_int(finding.get("line_number"), sink_anchor_line),
    )

    finding["reasoning"] = optional_text(finding.get("reasoning"))
    finding["fp_reason"] = optional_text(finding.get("fp_reason"))
    finding["review_reason"] = optional_text(finding.get("review_reason"))
    finding["poc_description"] = optional_text(finding.get("poc_description"))
    finding["storage_key"] = optional_text(finding.get("storage_key"))
    finding["remediation"] = optional_text(finding.get("remediation"))
    finding["cwe_id"] = optional_text(finding.get("cwe_id"))
    finding["patchstack_eligible"] = finding.get("patchstack_eligible") if isinstance(finding.get("patchstack_eligible"), bool) else None
    finding["fp_evidence"] = normalize_fp_evidence(finding.get("fp_evidence"))

    for field in COMMON_NULL_FIELDS:
        finding.setdefault(field, None)

    if verdict == "TP":
        for field in TP_REQUIRED_FIELDS:
            finding.setdefault(field, None)
        if not finding.get("reasoning"):
            finding["reasoning"] = (
                optional_text(finding.get("review_reason"))
                or optional_text(finding.get("fp_reason"))
                or "Revised bundle output preserved after reviewer critique; inspect raw artifact for the original rationale."
            )
        missing_tp_fields = [field for field in TP_REQUIRED_FIELDS if finding.get(field) in (None, "", [])]
        if missing_tp_fields:
            finding["policy_original_verdict"] = "TP"
            finding["verdict"] = "REVIEW"
            finding["review_reason"] = (
                f"Downgraded from TP during normalization because required exploit path evidence is missing: {', '.join(missing_tp_fields)}."
            )
            finding["fp_reason"] = None
            finding_notes.append(f"downgraded_tp_to_review_missing_evidence:{','.join(missing_tp_fields)}")
    elif verdict == "FP":
        if not finding.get("fp_reason"):
            finding["fp_reason"] = (
                optional_text(finding.get("reasoning"))
                or optional_text(finding.get("review_reason"))
                or "Normalized false-positive downgrade after reviewer critique."
            )
        if not isinstance(finding.get("fp_evidence"), dict):
            finding["fp_evidence"] = {"defense": "not specified", "file": None, "line": None}
    elif verdict == "REVIEW":
        if not finding.get("review_reason"):
            finding["review_reason"] = (
                optional_text(finding.get("reasoning"))
                or optional_text(finding.get("fp_reason"))
                or "Additional code evidence is required after reviewer critique."
            )

    if finding_notes:
        existing_notes = finding.get("normalization_notes")
        if isinstance(existing_notes, list):
            finding["normalization_notes"] = existing_notes + finding_notes
        else:
            finding["normalization_notes"] = finding_notes

    return finding


def normalize_agent_output_object(
    data: dict,
    *,
    expected_agent_id: str | None = None,
    expected_plugin_slug: str | None = None,
) -> dict:
    normalized = deepcopy(data) if isinstance(data, dict) else {}
    normalized["agent_id"] = optional_text(normalized.get("agent_id")) or expected_agent_id or "unknown-agent"
    original_plugin_slug = optional_text(normalized.get("plugin_slug"))
    normalized["plugin_slug"] = expected_plugin_slug or original_plugin_slug or "unknown-plugin"
    if (
        expected_plugin_slug
        and original_plugin_slug
        and original_plugin_slug != expected_plugin_slug
    ):
        normalized["original_plugin_slug"] = original_plugin_slug
    normalized["execution_time_ms"] = coerce_int(normalized.get("execution_time_ms"), 0)

    findings = normalized.get("findings")
    if not isinstance(findings, list):
        findings = []
    normalized["findings"] = [
        normalize_finding(
            {**finding, "plugin_slug": normalized["plugin_slug"]} if isinstance(finding, dict) else finding,
            index + 1,
            normalized["agent_id"],
        )
        for index, finding in enumerate(findings)
    ]

    if "negative_findings" in normalized:
        normalized["negative_findings"] = normalize_negative_findings(normalized.get("negative_findings"))

    return normalized


def validate_with_schema(instance: dict, schema: dict | None) -> list[str]:
    if not schema:
        return []
    try:
        import jsonschema
    except ImportError:
        return []
    validator = jsonschema.Draft7Validator(schema)
    return [error.message for error in validator.iter_errors(instance)]


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp_path.replace(path)


def normalize_agent_output_path(
    input_path: Path,
    output_path: Path,
    *,
    schema: dict | None = None,
    expected_agent_id: str | None = None,
    expected_plugin_slug: str | None = None,
) -> tuple[dict, list[str]]:
    payload, notes = load_json_with_repair(input_path)
    normalized = normalize_agent_output_object(
        payload,
        expected_agent_id=expected_agent_id,
        expected_plugin_slug=expected_plugin_slug,
    )
    errors = validate_with_schema(normalized, schema)
    if errors:
        raise ValueError("; ".join(errors[:10]))
    write_json_atomic(output_path, normalized)
    return normalized, notes


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Normalize per-agent output JSON for Phase 2.")
    parser.add_argument("--input", required=True, help="Input JSON path")
    parser.add_argument("--output", required=True, help="Output JSON path")
    parser.add_argument("--schema", default=None, help="Optional schema path for post-normalization validation")
    parser.add_argument("--agent-id", default=None, help="Fallback agent_id when missing")
    parser.add_argument("--plugin-slug", default=None, help="Fallback plugin_slug when missing")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    schema = None
    if args.schema:
        schema = json.loads(Path(args.schema).read_text(encoding="utf-8"))
    try:
        _, notes = normalize_agent_output_path(
            Path(args.input),
            Path(args.output),
            schema=schema,
            expected_agent_id=args.agent_id,
            expected_plugin_slug=args.plugin_slug,
        )
    except Exception as exc:
        print(f"[ERROR] normalize_agent_output failed: {exc}", file=sys.stderr)
        return 1

    if notes:
        print(f"[INFO] normalize_agent_output repaired: {', '.join(notes)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
