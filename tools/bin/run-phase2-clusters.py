#!/usr/bin/env python3
"""
run-phase2-clusters.py — execute cluster synthesis/challenge for existing cluster artifacts
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import jsonschema


def find_project_root() -> Path:
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        if (candidate / "contracts").is_dir():
            return candidate
    return Path.cwd()


ROOT = find_project_root()
REPORTS_DIR = ROOT / "reports"
PHASE2_DIR = REPORTS_DIR / "phase2"
LOGS_DIR = REPORTS_DIR / "logs"
LOGS_DIR.mkdir(parents=True, exist_ok=True)

CLUSTER_OUTPUT_SCHEMA = ROOT / "contracts" / "phase2-cluster-output.schema.json"
CLUSTER_PACK_SCHEMA = ROOT / "contracts" / "phase2-cluster-pack.schema.json"
SYNTH_TEMPLATE = ROOT / "tools" / "config" / "phase2-cluster-synthesis-prompt-template.md"
CHALLENGE_TEMPLATE = ROOT / "tools" / "config" / "phase2-cluster-challenge-prompt-template.md"
SYNTH_TIMEOUT_SECONDS = int(os.environ.get("PHASE2_CLUSTER_SYNTH_TIMEOUT_SECONDS", "420"))
CHALLENGE_TIMEOUT_SECONDS = int(os.environ.get("PHASE2_CLUSTER_CHALLENGE_TIMEOUT_SECONDS", "300"))


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def quota_signal(text: str) -> bool:
    haystack = text.lower()
    return any(token in haystack for token in ("usage limit", "usage exhausted", "rate limit", "quota"))


def validate_cluster_output(path: Path) -> None:
    schema = load_json(CLUSTER_OUTPUT_SCHEMA)
    data = load_json(path)
    jsonschema.validate(instance=data, schema=schema)


def validate_cluster_pack(path: Path) -> None:
    schema = load_json(CLUSTER_PACK_SCHEMA)
    data = load_json(path)
    jsonschema.validate(instance=data, schema=schema)


def normalize_cluster_output(path: Path, stage: str, cluster_pack: dict) -> None:
    if not path.exists():
        return
    data = load_json(path)
    summary = data.get("summary")
    if isinstance(summary, str):
        data["summary"] = {
            "member_findings_reviewed": len(cluster_pack.get("member_findings", [])),
            "material_links_found": len(data.get("proposed_links", [])) if isinstance(data.get("proposed_links"), list) else 0,
            "objections_count": len(data.get("objections", [])) if isinstance(data.get("objections"), list) else 0,
            "open_questions_count": len(data.get("open_questions", [])) if isinstance(data.get("open_questions"), list) else 0,
            "expansion_attempts_count": len(data.get("expansion_attempts", [])) if isinstance(data.get("expansion_attempts"), list) else 0,
            "notes": summary,
        }
    elif not isinstance(summary, dict):
        data["summary"] = {
            "member_findings_reviewed": len(cluster_pack.get("member_findings", [])),
            "material_links_found": 0,
            "objections_count": 0,
            "open_questions_count": 0,
            "expansion_attempts_count": 0,
            "notes": "",
        }
    else:
        data["summary"].setdefault("member_findings_reviewed", len(cluster_pack.get("member_findings", [])))
        data["summary"].setdefault("material_links_found", len(data.get("proposed_links", [])) if isinstance(data.get("proposed_links"), list) else 0)
        data["summary"].setdefault("objections_count", len(data.get("objections", [])) if isinstance(data.get("objections"), list) else 0)
        data["summary"].setdefault("open_questions_count", len(data.get("open_questions", [])) if isinstance(data.get("open_questions"), list) else 0)
        data["summary"].setdefault("expansion_attempts_count", len(data.get("expansion_attempts", [])) if isinstance(data.get("expansion_attempts"), list) else 0)
        data["summary"].setdefault("notes", "")

    data.setdefault("plugin_slug", cluster_pack.get("plugin_slug", ""))
    data.setdefault("cluster_id", cluster_pack.get("cluster_id", ""))
    data["stage"] = stage
    data.setdefault("status", "needs_followup")
    for key in ("suggested_actions", "proposed_links", "objections", "open_questions", "missing_evidence", "expansion_attempts"):
        if not isinstance(data.get(key), list):
            data[key] = []
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def cluster_status_path(slug: str, cluster_id: str) -> Path:
    return PHASE2_DIR / f"{slug}-{cluster_id}.status.json"


def emit_progress(cluster_id: str, stage: str, event: str, **fields: object) -> None:
    parts = [f"[{cluster_id}] {stage}:{event}"]
    for key, value in fields.items():
        if value is None:
            continue
        parts.append(f"{key}={value}")
    print(" ".join(parts), file=sys.stderr, flush=True)


def write_cluster_status(
    status_path: Path,
    plugin_slug: str,
    cluster_id: str,
    stage: str,
    state: str,
    **fields: object,
) -> None:
    def serialize(value: object) -> object:
        if isinstance(value, Path):
            return str(value)
        if isinstance(value, dict):
            return {str(k): serialize(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [serialize(item) for item in value]
        return value

    payload = {
        "plugin_slug": plugin_slug,
        "cluster_id": cluster_id,
        "stage": stage,
        "state": state,
        "updated_at": utc_timestamp(),
    }
    for key, value in fields.items():
        if value is not None:
            payload[key] = serialize(value)
    status_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def update_cluster_progress(
    status_path: Path,
    plugin_slug: str,
    cluster_id: str,
    stage: str,
    state: str,
    **fields: object,
) -> None:
    emit_progress(cluster_id, stage, state, **fields)
    write_cluster_status(status_path, plugin_slug, cluster_id, stage, state, **fields)


def render_template(template_path: Path, replacements: dict[str, str]) -> str:
    text = template_path.read_text(encoding="utf-8", errors="replace")
    for needle, value in replacements.items():
        text = text.replace(needle, value)
    return text


def run_claude(prompt: str, model: str, log_path: Path, last_message_path: Path, timeout_seconds: int) -> int:
    cmd = ["claude", "-p", "--dangerously-skip-permissions", "--verbose", "--output-format", "stream-json"]
    if model:
        cmd.extend(["--model", model])
    proc = subprocess.Popen(
        cmd,
        cwd=ROOT,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        stdout, stderr = proc.communicate(prompt, timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        proc.kill()
        stdout, stderr = proc.communicate()
        log_path.write_text((stderr or "") + f"\n[TIMEOUT] Claude cluster stage exceeded {timeout_seconds}s.\n", encoding="utf-8")
        return 124
    log_path.write_text(stderr or "", encoding="utf-8")
    text_chunks = []
    for line in stdout.splitlines():
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            text_chunks.append(line)
            continue
        if obj.get("type") == "content_block_delta":
            delta = obj.get("delta", {})
            if delta.get("type") == "text_delta":
                text_chunks.append(delta.get("text", ""))
    last_message_path.write_text("".join(text_chunks), encoding="utf-8")
    return proc.returncode


def run_codex(prompt: str, log_path: Path, last_message_path: Path, timeout_seconds: int) -> int:
    with log_path.open("w", encoding="utf-8") as log_file:
        try:
            proc = subprocess.run(
                [
                    "codex",
                    "exec",
                    "--dangerously-bypass-approvals-and-sandbox",
                    "-C",
                    str(ROOT),
                    "--output-last-message",
                    str(last_message_path),
                ],
                cwd=ROOT,
                input=prompt,
                text=True,
                stdout=subprocess.DEVNULL,
                stderr=log_file,
                timeout=timeout_seconds,
            )
            return proc.returncode
        except subprocess.TimeoutExpired:
            log_file.write(f"\n[TIMEOUT] Codex cluster stage exceeded {timeout_seconds}s.\n")
            return 124


def run_with_retries(provider: str, model: str, prompt: str, log_path: Path, last_message_path: Path, timeout_seconds: int) -> int:
    rc = 0
    for attempt in range(1, 4):
        if provider == "claude":
            rc = run_claude(prompt, model, log_path, last_message_path, timeout_seconds)
        else:
            rc = run_codex(prompt, log_path, last_message_path, timeout_seconds)

        stderr_text = log_path.read_text(encoding="utf-8", errors="replace") if log_path.exists() else ""
        if provider == "codex" and quota_signal(stderr_text) and attempt < 3:
            time.sleep(3)
            continue
        return rc
    return rc


def cluster_models(cluster_doc: dict) -> tuple[tuple[str, str], tuple[str, str]]:
    synth = cluster_doc.get("recommended_models", {}).get("synthesizer", {})
    challenger = cluster_doc.get("recommended_models", {}).get("challenger", {})
    synth_provider = (synth.get("provider") or "codex").lower()
    synth_model = synth.get("model") or "gpt-5.4"
    challenge_provider = (challenger.get("provider") or "claude").lower()
    challenge_model = challenger.get("model") or "claude-sonnet-4.6"
    if synth_provider == "claude" and "opus" in synth_model.lower():
        synth_model = "claude-sonnet-4.6"
    if challenge_provider == "claude" and "opus" in challenge_model.lower():
        challenge_model = "claude-sonnet-4.6"
    return (synth_provider, synth_model), (challenge_provider, challenge_model)


def run_cluster(cluster_path: Path, cluster_pack_path: Path) -> tuple[bool, bool]:
    cluster_doc = load_json(cluster_path)
    cluster_pack = load_json(cluster_pack_path)
    slug = cluster_doc["plugin_slug"]
    cluster_id = cluster_doc["cluster_id"]
    status_path = cluster_status_path(slug, cluster_id)
    synth_path = PHASE2_DIR / f"{slug}-{cluster_id}.synth.json"
    challenge_path = PHASE2_DIR / f"{slug}-{cluster_id}.challenge.json"
    synth_log = LOGS_DIR / f"{slug}-{cluster_id}.synth.log"
    synth_last = LOGS_DIR / f"{slug}-{cluster_id}.synth.last-message.txt"
    challenge_log = LOGS_DIR / f"{slug}-{cluster_id}.challenge.log"
    challenge_last = LOGS_DIR / f"{slug}-{cluster_id}.challenge.last-message.txt"

    (synth_provider, synth_model), (challenge_provider, challenge_model) = cluster_models(cluster_doc)

    update_cluster_progress(
        status_path,
        slug,
        cluster_id,
        "cluster",
        "selected",
        cluster_path=cluster_path,
        cluster_pack_path=cluster_pack_path,
    )
    validate_cluster_pack(cluster_pack_path)
    update_cluster_progress(
        status_path,
        slug,
        cluster_id,
        "pack",
        "validated",
        cluster_pack_path=cluster_pack_path,
    )

    synth_prompt = render_template(
        SYNTH_TEMPLATE,
        {
            "{PLUGIN_SLUG}": slug,
            "{CLUSTER_ID}": cluster_id,
            "{CLUSTER_PACK_PATH}": str(cluster_pack_path),
            "{OUTPUT_PATH}": str(synth_path),
        },
    )
    update_cluster_progress(
        status_path,
        slug,
        cluster_id,
        "synth",
        "start",
        provider=synth_provider,
        model=synth_model,
        timeout_seconds=SYNTH_TIMEOUT_SECONDS,
        output_path=synth_path,
        log_path=synth_log,
    )
    rc = run_with_retries(synth_provider, synth_model, synth_prompt, synth_log, synth_last, SYNTH_TIMEOUT_SECONDS)
    normalize_cluster_output(synth_path, "synthesis", cluster_pack)
    synth_ok = False
    synth_salvaged = False
    if synth_path.exists():
        try:
            validate_cluster_output(synth_path)
            synth_ok = True
            synth_salvaged = rc != 0
        except Exception:
            synth_ok = False
    update_cluster_progress(
        status_path,
        slug,
        cluster_id,
        "synth",
        "validated" if synth_ok else "failed",
        rc=rc,
        output_path=synth_path,
        validated=synth_ok,
        salvaged=synth_salvaged if synth_ok else None,
        last_message_path=synth_last if synth_last.exists() else None,
    )

    if not synth_ok:
        return False, False

    challenge_prompt = render_template(
        CHALLENGE_TEMPLATE,
        {
            "{PLUGIN_SLUG}": slug,
            "{CLUSTER_ID}": cluster_id,
            "{CLUSTER_PACK_PATH}": str(cluster_pack_path),
            "{SYNTH_PATH}": str(synth_path),
            "{OUTPUT_PATH}": str(challenge_path),
        },
    )
    update_cluster_progress(
        status_path,
        slug,
        cluster_id,
        "challenge",
        "start",
        provider=challenge_provider,
        model=challenge_model,
        timeout_seconds=CHALLENGE_TIMEOUT_SECONDS,
        synth_path=synth_path,
        output_path=challenge_path,
        log_path=challenge_log,
    )
    rc = run_with_retries(challenge_provider, challenge_model, challenge_prompt, challenge_log, challenge_last, CHALLENGE_TIMEOUT_SECONDS)
    normalize_cluster_output(challenge_path, "challenge", cluster_pack)
    challenge_ok = False
    challenge_salvaged = False
    if challenge_path.exists():
        try:
            validate_cluster_output(challenge_path)
            challenge_ok = True
            challenge_salvaged = rc != 0
        except Exception:
            challenge_ok = False
    update_cluster_progress(
        status_path,
        slug,
        cluster_id,
        "challenge",
        "validated" if challenge_ok else "failed",
        rc=rc,
        output_path=challenge_path,
        validated=challenge_ok,
        salvaged=challenge_salvaged if challenge_ok else None,
        last_message_path=challenge_last if challenge_last.exists() else None,
    )
    return synth_ok, challenge_ok


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Phase 2 cluster synthesis/challenge on an existing cluster plan.")
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--cluster-id", default=None, help="Run only a specific cluster id")
    parser.add_argument("--limit", type=int, default=None, help="Run only the first N clusters")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    plan_path = PHASE2_DIR / f"{args.slug}-cluster-plan.json"
    if not plan_path.exists():
        print(f"[ERROR] Cluster plan not found: {plan_path}", file=sys.stderr)
        return 1
    plan = load_json(plan_path)
    selected = plan.get("clusters", [])
    if args.cluster_id:
        selected = [cluster for cluster in selected if cluster.get("cluster_id") == args.cluster_id]
    if args.limit is not None:
        selected = selected[: args.limit]
    if not selected:
        print("[ERROR] No clusters selected to run.", file=sys.stderr)
        return 1

    synth_ok = 0
    challenge_ok = 0
    for cluster in selected:
        cluster_path = Path(cluster["path"])
        cluster_input_path = Path(cluster.get("pack_path") or cluster.get("input_path") or cluster["path"])
        if not cluster_path.is_absolute():
            cluster_path = ROOT / cluster_path
        if not cluster_input_path.is_absolute():
            cluster_input_path = ROOT / cluster_input_path
        ok1, ok2 = run_cluster(cluster_path, cluster_input_path)
        synth_ok += int(ok1)
        challenge_ok += int(ok2)
        print(f"[OK] {cluster['cluster_id']}: synth={ok1} challenge={ok2}")

    print(f"[SUMMARY] synth_ok={synth_ok}/{len(selected)} challenge_ok={challenge_ok}/{len(selected)}")
    return 0 if synth_ok == len(selected) else 1


if __name__ == "__main__":
    raise SystemExit(main())
