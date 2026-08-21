#!/usr/bin/env python3
"""Phase 2 dispatch manifest generation and verification helpers."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any


class ManifestVerificationError(RuntimeError):
    """Raised when a dispatch manifest does not verify cleanly."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def repo_relative_path(path: Path, repo_root: Path) -> str:
    return path.resolve().relative_to(repo_root.resolve()).as_posix()


def resolve_repo_relative_path(repo_root: Path, rel_path: str, *, allow_missing: bool = False) -> Path:
    if not rel_path:
        raise ManifestVerificationError("Manifest path cannot be empty.")
    rel = Path(rel_path)
    if rel.is_absolute():
        raise ManifestVerificationError(f"Manifest path must be repo-relative, got absolute path: {rel_path}")
    candidate = (repo_root / rel).resolve()
    try:
        candidate.relative_to(repo_root.resolve())
    except ValueError as exc:
        raise ManifestVerificationError(f"Manifest path escapes repo root: {rel_path}") from exc
    if not allow_missing and not candidate.exists():
        raise ManifestVerificationError(f"Tracked artifact missing: {rel_path}")
    return candidate


def normalize_dispatch_path_value(repo_root: Path, raw_path: str, *, allow_missing: bool = False) -> str:
    value = str(raw_path or "").strip()
    if not value:
        return ""
    candidate = Path(value)
    if candidate.is_absolute():
        resolved = candidate.resolve()
        try:
            return repo_relative_path(resolved, repo_root)
        except Exception as exc:
            raise ManifestVerificationError(f"Dispatch path escapes repo root: {value}") from exc
    resolved = resolve_repo_relative_path(repo_root, value, allow_missing=allow_missing)
    return repo_relative_path(resolved, repo_root)


def tracked_file_entry(
    repo_root: Path,
    path: Path | None,
    *,
    required: bool,
) -> dict[str, Any]:
    if path is None:
        return {"required": required, "present": False}
    resolved = path.resolve()
    entry = {
        "path": repo_relative_path(resolved, repo_root),
        "required": required,
        "present": resolved.is_file(),
    }
    if resolved.is_file():
        entry["sha256"] = sha256_file(resolved)
    return entry


def dispatch_input_entry(repo_root: Path, agent_id: str, path: Path, *, origin: str) -> dict[str, Any]:
    resolved = path.resolve()
    if not resolved.is_file():
        raise FileNotFoundError(f"Dispatch input missing for {agent_id}: {resolved}")
    return {
        "agent_id": agent_id,
        "origin": origin,
        "path": repo_relative_path(resolved, repo_root),
        "sha256": sha256_file(resolved),
    }


def build_dispatch_manifest(
    *,
    repo_root: Path,
    slug: str,
    source_dir: str,
    run_id: str | None,
    dispatch_path: Path,
    inventory_path: Path,
    ir_path: Path,
    semgrep_path: Path | None,
    psalm_path: Path | None,
    threat_context_path: Path | None,
    provider_policy_path: Path | None,
    dispatch_inputs: list[dict[str, Any]],
) -> dict[str, Any]:
    bundle_inputs = [entry for entry in dispatch_inputs if entry.get("origin") == "bundle"]
    return {
        "manifest_version": 1,
        "hash_algorithm": "sha256",
        "plugin_slug": slug,
        "source_dir": source_dir,
        "run_id": run_id or None,
        "artifacts": {
            "dispatch": tracked_file_entry(repo_root, dispatch_path, required=True),
            "candidate_inventory": tracked_file_entry(repo_root, inventory_path, required=True),
            "ir": tracked_file_entry(repo_root, ir_path, required=True),
            "semgrep": tracked_file_entry(repo_root, semgrep_path, required=False),
            "psalm": tracked_file_entry(repo_root, psalm_path, required=False),
            "threat_context": tracked_file_entry(repo_root, threat_context_path, required=False),
            "provider_policy": tracked_file_entry(repo_root, provider_policy_path, required=False),
        },
        "dispatch_inputs": dispatch_inputs,
        "bundle_inputs": bundle_inputs,
    }


def verify_tracked_entry(
    repo_root: Path,
    entry: dict[str, Any],
    *,
    label: str,
) -> Path | None:
    required = bool(entry.get("required", False))
    present = bool(entry.get("present", False))
    rel_path = entry.get("path") or ""
    if not present:
        if required:
            raise ManifestVerificationError(f"Required tracked artifact is absent in manifest: {label}")
        return None
    path = resolve_repo_relative_path(repo_root, rel_path)
    expected = entry.get("sha256")
    if not expected:
        raise ManifestVerificationError(f"Tracked artifact is missing sha256 for {label}: {rel_path}")
    actual = sha256_file(path)
    if actual != expected:
        raise ManifestVerificationError(f"Hash mismatch for {label}: {rel_path}")
    return path


def _validate_source_dir(source_dir: str) -> None:
    if not source_dir:
        raise ManifestVerificationError("Manifest source_dir is empty.")
    path = Path(source_dir)
    if path.is_absolute():
        raise ManifestVerificationError(f"Manifest source_dir must be relative: {source_dir}")
    if ".." in path.parts:
        raise ManifestVerificationError(f"Manifest source_dir cannot traverse upward: {source_dir}")


def verify_dispatch_manifest(
    *,
    manifest_path: Path,
    repo_root: Path,
    dispatch_path: Path | None = None,
    expected_slug: str | None = None,
) -> dict[str, Any]:
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ManifestVerificationError(f"Dispatch manifest not found: {manifest_path}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestVerificationError(f"Dispatch manifest is not valid JSON: {manifest_path}") from exc

    if manifest.get("manifest_version") != 1:
        raise ManifestVerificationError(f"Unsupported dispatch manifest version: {manifest.get('manifest_version')!r}")

    slug = str(manifest.get("plugin_slug") or "")
    if not slug:
        raise ManifestVerificationError("Dispatch manifest missing plugin_slug.")
    if expected_slug and slug != expected_slug:
        raise ManifestVerificationError(
            f"Dispatch manifest slug mismatch: expected {expected_slug!r}, found {slug!r}"
        )

    source_dir = str(manifest.get("source_dir") or "")
    _validate_source_dir(source_dir)

    artifacts = manifest.get("artifacts")
    if not isinstance(artifacts, dict):
        raise ManifestVerificationError("Dispatch manifest missing artifacts section.")

    verified_paths: dict[str, Path | None] = {}
    for label, entry in artifacts.items():
        if not isinstance(entry, dict):
            raise ManifestVerificationError(f"Tracked artifact entry must be an object: {label}")
        verified_paths[label] = verify_tracked_entry(repo_root, entry, label=label)

    dispatch_entry = artifacts.get("dispatch")
    if not isinstance(dispatch_entry, dict) or not dispatch_entry.get("present"):
        raise ManifestVerificationError("Dispatch manifest does not track a present dispatch artifact.")
    manifest_dispatch_rel = str(dispatch_entry.get("path") or "")
    verified_dispatch = verified_paths["dispatch"]
    assert verified_dispatch is not None
    if dispatch_path is not None and verified_dispatch.resolve() != dispatch_path.resolve():
        raise ManifestVerificationError(
            f"Dispatch path mismatch: manifest tracks {manifest_dispatch_rel}, requested {dispatch_path}"
        )

    dispatch = json.loads(verified_dispatch.read_text(encoding="utf-8"))
    if dispatch.get("slug") != slug:
        raise ManifestVerificationError(
            f"Dispatch slug does not match manifest plugin_slug: {dispatch.get('slug')!r} != {slug!r}"
        )
    if dispatch.get("source_dir") != source_dir:
        raise ManifestVerificationError(
            f"Dispatch source_dir does not match manifest: {dispatch.get('source_dir')!r} != {source_dir!r}"
        )

    dispatch_inputs = dispatch.get("inputs")
    if not isinstance(dispatch_inputs, dict):
        raise ManifestVerificationError("Dispatch inputs must be an object.")

    manifest_inputs = manifest.get("dispatch_inputs")
    if not isinstance(manifest_inputs, list):
        raise ManifestVerificationError("Dispatch manifest dispatch_inputs must be a list.")

    manifest_input_map: dict[str, dict[str, Any]] = {}
    for entry in manifest_inputs:
        if not isinstance(entry, dict):
            raise ManifestVerificationError("Dispatch manifest input entry must be an object.")
        agent_id = str(entry.get("agent_id") or "")
        rel_path = str(entry.get("path") or "")
        origin = str(entry.get("origin") or "")
        expected_hash = str(entry.get("sha256") or "")
        if not agent_id or not rel_path or not expected_hash:
            raise ManifestVerificationError("Dispatch manifest input entry is incomplete.")
        if agent_id in manifest_input_map:
            raise ManifestVerificationError(f"Duplicate manifest dispatch input entry for {agent_id}.")
        manifest_input_map[agent_id] = entry
        path = resolve_repo_relative_path(repo_root, rel_path)
        if sha256_file(path) != expected_hash:
            raise ManifestVerificationError(f"Hash mismatch for dispatch input {agent_id}: {rel_path}")
        if origin not in {"bundle", "support_ir"}:
            raise ManifestVerificationError(f"Unsupported dispatch input origin for {agent_id}: {origin}")

    if set(dispatch_inputs.keys()) != set(manifest_input_map.keys()):
        raise ManifestVerificationError("Dispatch inputs do not match manifest agent mapping.")

    for agent_id, rel_path in dispatch_inputs.items():
        entry = manifest_input_map[agent_id]
        normalized_dispatch_rel = normalize_dispatch_path_value(repo_root, str(rel_path))
        if normalized_dispatch_rel != entry["path"]:
            raise ManifestVerificationError(
                f"Dispatch input path mismatch for {agent_id}: {rel_path!r} != {entry['path']!r}"
            )

    inventory_rel = normalize_dispatch_path_value(repo_root, str(dispatch.get("bundle_inventory") or ""))
    inventory_entry = artifacts.get("candidate_inventory")
    if inventory_rel and isinstance(inventory_entry, dict) and inventory_entry.get("path") != inventory_rel:
        raise ManifestVerificationError(
            f"Dispatch bundle_inventory mismatch: {inventory_rel!r} != {inventory_entry.get('path')!r}"
        )

    threat_context_rel = ((dispatch.get("threat_context_path") or "")).strip()
    threat_context_entry = artifacts.get("threat_context")
    threat_context_manifest_rel = ""
    if isinstance(threat_context_entry, dict) and threat_context_entry.get("present"):
        threat_context_manifest_rel = str(threat_context_entry.get("path") or "")
    if threat_context_rel != threat_context_manifest_rel:
        raise ManifestVerificationError(
            f"Dispatch threat_context_path mismatch: {threat_context_rel!r} != {threat_context_manifest_rel!r}"
        )

    return manifest


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify Phase 2 dispatch manifests.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    verify_parser = subparsers.add_parser("verify", help="Verify a dispatch manifest against current files.")
    verify_parser.add_argument("--manifest", required=True, help="Path to dispatch.manifest.json")
    verify_parser.add_argument("--repo-root", required=True, help="Repository root used to resolve relative paths")
    verify_parser.add_argument("--dispatch", help="Expected dispatch.json path")
    verify_parser.add_argument("--expected-slug", help="Expected plugin slug")

    args = parser.parse_args()

    if args.command == "verify":
        try:
            verify_dispatch_manifest(
                manifest_path=Path(args.manifest).resolve(),
                repo_root=Path(args.repo_root).resolve(),
                dispatch_path=Path(args.dispatch).resolve() if args.dispatch else None,
                expected_slug=args.expected_slug,
            )
        except ManifestVerificationError as exc:
            print(f"ERROR: {exc}", file=sys.stderr)
            return 1
        return 0

    parser.error("Unknown command")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
