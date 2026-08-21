#!/usr/bin/env python3
"""
run-phase2-clusters.py — execute cluster synthesis/challenge for existing cluster artifacts
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import jsonschema
from report_paths import build_report_layout


def find_project_root() -> Path:
    candidate = Path(__file__).resolve()
    for _ in range(6):
        candidate = candidate.parent
        if (candidate / "contracts").is_dir():
            return candidate
    return Path.cwd()


ROOT = find_project_root()
REPORTS_DIR = ROOT / "reports"
LAYOUT = build_report_layout(REPORTS_DIR).ensure()
PHASE2_DIR = LAYOUT.phase2
LOGS_DIR = LAYOUT.logs
COST_TELEMETRY_BIN = ROOT / "tools" / "bin" / "cost_telemetry.py"

CLUSTER_OUTPUT_SCHEMA = ROOT / "contracts" / "phase2-cluster-output.schema.json"
CLUSTER_PACK_SCHEMA = ROOT / "contracts" / "phase2-cluster-pack.schema.json"
SYNTH_TEMPLATE = ROOT / "tools" / "config" / "phase2-cluster-synthesis-prompt-template.md"
CHALLENGE_TEMPLATE = ROOT / "tools" / "config" / "phase2-cluster-challenge-prompt-template.md"
SYNTH_TIMEOUT_SECONDS = int(os.environ.get("PHASE2_CLUSTER_SYNTH_TIMEOUT_SECONDS", "420"))
CHALLENGE_TIMEOUT_SECONDS = int(os.environ.get("PHASE2_CLUSTER_CHALLENGE_TIMEOUT_SECONDS", "300"))
CODEX_BIN = os.environ.get("CODEX_BIN", "codex")
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
CLAUDE_SAFE_TOOLS = os.environ.get("PHASE2_CLUSTER_CLAUDE_SAFE_TOOLS", "Read,Grep,Glob")


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
    cluster_findings = cluster_pack.get("member_findings", [])

    def advisory_why_it_matters(question: dict) -> str:
        existing = question.get("why_it_matters")
        if isinstance(existing, str) and existing.strip():
            return existing.strip()
        impact = question.get("impact")
        if isinstance(impact, str) and impact.strip():
            return impact.strip()
        severity = str(question.get("severity") or "").strip()
        blocking = question.get("blocking")
        if blocking is True:
            return "This ambiguity changes whether the cluster outcome can be trusted and needs explicit closure."
        if severity:
            return f"This is advisory context from the cluster challenge ({severity}) and helps narrow exploitability breadth without changing the current verdict."
        return "This is advisory context from the cluster challenge and helps narrow exploitability breadth without changing the current verdict."

    def normalize_open_questions(items: object) -> list[dict]:
        if not isinstance(items, list):
            return []
        normalized: list[dict] = []
        default_targets = [finding.get("finding_id") for finding in cluster_findings if isinstance(finding.get("finding_id"), str)]
        for item in items:
            if not isinstance(item, dict):
                continue
            question = str(item.get("question") or "").strip()
            if not question:
                continue
            normalized_item = dict(item)
            normalized_item["question"] = question
            normalized_item["why_it_matters"] = advisory_why_it_matters(item)
            if not isinstance(normalized_item.get("target_finding_ids"), list) and default_targets:
                normalized_item["target_finding_ids"] = default_targets
            normalized.append(normalized_item)
        return normalized

    def normalize_missing_evidence(items: object) -> list[dict]:
        if not isinstance(items, list):
            return []
        normalized: list[dict] = []
        default_targets = [finding.get("finding_id") for finding in cluster_findings if isinstance(finding.get("finding_id"), str)]
        for item in items:
            if not isinstance(item, dict):
                continue
            evidence_needed = item.get("evidence_needed")
            if not isinstance(evidence_needed, str) or not evidence_needed.strip():
                description = item.get("description")
                impact = item.get("impact")
                parts = []
                if isinstance(description, str) and description.strip():
                    parts.append(description.strip())
                if isinstance(impact, str) and impact.strip():
                    parts.append(f"Impact/context: {impact.strip()}")
                evidence_needed = " ".join(parts).strip()
            reason = item.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                impact = item.get("impact")
                description = item.get("description")
                if isinstance(impact, str) and impact.strip():
                    reason = impact.strip()
                elif isinstance(description, str) and description.strip():
                    reason = f"Additional evidence is needed to resolve: {description.strip()}"
                else:
                    reason = "Additional evidence is needed to refine the cluster advisory context."
            evidence_needed = str(evidence_needed or "").strip()
            reason = str(reason or "").strip()
            if not evidence_needed or not reason:
                continue
            normalized_item = dict(item)
            normalized_item["evidence_needed"] = evidence_needed
            normalized_item["reason"] = reason
            if not isinstance(normalized_item.get("target_finding_ids"), list) and default_targets:
                normalized_item["target_finding_ids"] = default_targets
            normalized.append(normalized_item)
        return normalized

    summary = data.get("summary")
    if isinstance(summary, str):
        data["summary"] = {
            "member_findings_reviewed": len(cluster_findings),
            "material_links_found": len(data.get("proposed_links", [])) if isinstance(data.get("proposed_links"), list) else 0,
            "objections_count": len(data.get("objections", [])) if isinstance(data.get("objections"), list) else 0,
            "closure_packets_count": len(data.get("closure_packets", [])) if isinstance(data.get("closure_packets"), list) else 0,
            "open_questions_count": len(data.get("open_questions", [])) if isinstance(data.get("open_questions"), list) else 0,
            "expansion_attempts_count": len(data.get("expansion_attempts", [])) if isinstance(data.get("expansion_attempts"), list) else 0,
            "notes": summary,
        }
    elif not isinstance(summary, dict):
        data["summary"] = {
            "member_findings_reviewed": len(cluster_findings),
            "material_links_found": 0,
            "objections_count": 0,
            "closure_packets_count": 0,
            "open_questions_count": 0,
            "expansion_attempts_count": 0,
            "notes": "",
        }
    else:
        data["summary"].setdefault("member_findings_reviewed", len(cluster_findings))
        data["summary"].setdefault("material_links_found", len(data.get("proposed_links", [])) if isinstance(data.get("proposed_links"), list) else 0)
        data["summary"].setdefault("objections_count", len(data.get("objections", [])) if isinstance(data.get("objections"), list) else 0)
        data["summary"].setdefault("closure_packets_count", len(data.get("closure_packets", [])) if isinstance(data.get("closure_packets"), list) else 0)
        data["summary"].setdefault("open_questions_count", len(data.get("open_questions", [])) if isinstance(data.get("open_questions"), list) else 0)
        data["summary"].setdefault("expansion_attempts_count", len(data.get("expansion_attempts", [])) if isinstance(data.get("expansion_attempts"), list) else 0)
        data["summary"].setdefault("notes", "")

    data.setdefault("plugin_slug", cluster_pack.get("plugin_slug", ""))
    data.setdefault("cluster_id", cluster_pack.get("cluster_id", ""))
    data["stage"] = stage
    data.setdefault("status", "needs_followup")
    for key in ("suggested_actions", "proposed_links", "objections", "closure_packets", "open_questions", "missing_evidence", "expansion_attempts"):
        if not isinstance(data.get(key), list):
            data[key] = []
    data["open_questions"] = normalize_open_questions(data.get("open_questions"))
    data["missing_evidence"] = normalize_missing_evidence(data.get("missing_evidence"))
    data["summary"]["open_questions_count"] = len(data["open_questions"])
    data["summary"]["closure_packets_count"] = len(data.get("closure_packets", []))
    data["summary"]["material_links_found"] = len(data.get("proposed_links", []))
    data["summary"]["objections_count"] = len(data.get("objections", []))
    data["summary"]["expansion_attempts_count"] = len(data.get("expansion_attempts", []))
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def extract_json_response_text(text: str) -> str:
    candidate = (text or "").strip()
    if not candidate:
        raise ValueError("Cluster response text is empty.")

    def _loads(payload: str) -> bool:
        try:
            json.loads(payload)
            return True
        except Exception:
            return False

    if _loads(candidate):
        return candidate

    for match in re.finditer(r"```(?:json)?\s*(\{.*?\})\s*```", candidate, re.DOTALL):
        payload = match.group(1).strip()
        if _loads(payload):
            return payload

    first = candidate.find("{")
    last = candidate.rfind("}")
    if first != -1 and last != -1 and last > first:
        payload = candidate[first:last + 1].strip()
        if _loads(payload):
            return payload

    raise ValueError("Could not extract cluster JSON response.")


def materialize_cluster_output(path: Path, last_message_path: Path, raw_log_path: Path) -> bool:
    text = ""
    if last_message_path.exists():
        text = last_message_path.read_text(encoding="utf-8", errors="replace")
    if not text.strip() and raw_log_path.exists():
        text = raw_log_path.read_text(encoding="utf-8", errors="replace")
    payload = extract_json_response_text(text)
    data = json.loads(payload)
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    return True


def compact_validation_error(exc: Exception) -> str:
    message = str(exc).strip()
    if not message:
        return exc.__class__.__name__
    line = message.splitlines()[0].strip()
    if len(line) > 240:
        return line[:237] + "..."
    return line


def utc_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def cluster_log_dir(slug: str) -> Path:
    return LAYOUT.phase2_cluster_logs(slug)


def cluster_run_errlog_path(slug: str) -> Path:
    return cluster_log_dir(slug) / "run.err"


def cluster_run_live_log_path(slug: str) -> Path:
    return cluster_log_dir(slug) / "run.live.log"


def cluster_stage_log_path(slug: str, cluster_id: str, stage: str) -> Path:
    return cluster_log_dir(slug) / f"{cluster_id}.{stage}.log"


def cluster_stage_raw_log_path(slug: str, cluster_id: str, stage: str) -> Path:
    return cluster_log_dir(slug) / f"{cluster_id}.{stage}.raw.log"


def cluster_stage_last_message_path(slug: str, cluster_id: str, stage: str) -> Path:
    return cluster_log_dir(slug) / f"{cluster_id}.{stage}.last-message.txt"


def cluster_status_path(slug: str, cluster_id: str) -> Path:
    return PHASE2_DIR / f"{slug}-{cluster_id}.status.json"


def emit_progress(cluster_id: str, stage: str, event: str, **fields: object) -> None:
    parts = [f"[{cluster_id}] {stage}:{event}"]
    for key, value in fields.items():
        if value is None:
            continue
        parts.append(f"{key}={value}")
    print(" ".join(parts), file=sys.stderr, flush=True)


def append_progress_logs(slug: str, cluster_id: str, stage: str, event: str, **fields: object) -> None:
    parts = [f"[{utc_timestamp()}] [{cluster_id}] {stage}:{event}"]
    for key, value in fields.items():
        if value is None:
            continue
        parts.append(f"{key}={value}")
    line = " ".join(parts) + "\n"
    for path in (cluster_run_errlog_path(slug), cluster_run_live_log_path(slug)):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a", encoding="utf-8") as handle:
            handle.write(line)


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
    append_progress_logs(plugin_slug, cluster_id, stage, state, **fields)
    write_cluster_status(status_path, plugin_slug, cluster_id, stage, state, **fields)


def render_template(template_path: Path, replacements: dict[str, str]) -> str:
    text = template_path.read_text(encoding="utf-8", errors="replace")
    for needle, value in replacements.items():
        text = text.replace(needle, value)
    return text


def append_quota_event(
    *,
    phase: str,
    slug: str,
    mode: str,
    provider: str,
    model: str,
    status: str,
    duration_sec: int,
    component: str,
    role: str,
    cluster_id: str,
    input_path: Path,
    output_path: Path,
    errlog_path: Path,
    live_log_path: Path,
    raw_log_path: Path,
    timeout_seconds: int,
) -> None:
    subprocess.run(
        [
            sys.executable,
            str(COST_TELEMETRY_BIN),
            "append-event",
            "--ledger",
            str(LAYOUT.quota_ledger),
            "--phase",
            phase,
            "--slug",
            slug,
            "--run-id",
            os.environ.get("AUDIT_RUN_ID", ""),
            "--mode",
            mode,
            "--provider",
            provider,
            "--model",
            model,
            "--status",
            status,
            "--duration",
            str(duration_sec),
            "--component",
            component,
            "--role",
            role,
            "--cluster-id",
            cluster_id,
            "--attempt",
            "1",
            "--timeout-seconds",
            str(timeout_seconds),
            "--input-path",
            str(input_path),
            "--output-path",
            str(output_path),
            "--errlog-path",
            str(errlog_path),
            "--live-log-path",
            str(live_log_path),
            "--raw-log-path",
            str(raw_log_path),
        ],
        cwd=ROOT,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def emit_claude_stream_text(obj: dict, *, allow_result_fallback: bool) -> str:
    event_type = obj.get("type", "")
    if event_type == "content_block_delta":
        delta = obj.get("delta", {})
        if isinstance(delta, dict) and delta.get("type") == "text_delta":
            return str(delta.get("text") or "")
        return ""
    if event_type == "assistant":
        message = obj.get("message", {})
        if not isinstance(message, dict):
            return ""
        chunks: list[str] = []
        for block in message.get("content", []) or []:
            if isinstance(block, dict) and block.get("type") == "text":
                chunks.append(str(block.get("text") or ""))
        return "".join(chunks)
    if event_type == "result" and allow_result_fallback:
        result_text = obj.get("result")
        if isinstance(result_text, str):
            return result_text
    return ""


def run_claude(prompt: str, model: str, log_path: Path, raw_log_path: Path, last_message_path: Path, timeout_seconds: int) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    raw_log_path.parent.mkdir(parents=True, exist_ok=True)
    last_message_path.parent.mkdir(parents=True, exist_ok=True)
    cmd = [
        CLAUDE_BIN,
        "-p",
        "--bare",
        "--disable-slash-commands",
        "--permission-mode",
        "bypassPermissions",
        "--tools",
        CLAUDE_SAFE_TOOLS,
        "--verbose",
        "--output-format",
        "stream-json",
    ]
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
        raw_log_path.write_text(stdout or "", encoding="utf-8")
        return 124
    log_path.write_text(stderr or "", encoding="utf-8")
    raw_log_path.write_text(stdout or "", encoding="utf-8")
    text_chunks = []
    emitted_assistant_text = False
    for line in stdout.splitlines():
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            text_chunks.append(line)
            continue
        text = emit_claude_stream_text(obj, allow_result_fallback=not emitted_assistant_text)
        if text:
            if obj.get("type") != "result":
                emitted_assistant_text = True
            text_chunks.append(text)
    last_message_path.write_text("".join(text_chunks), encoding="utf-8")
    return proc.returncode


def run_codex(prompt: str, log_path: Path, raw_log_path: Path, last_message_path: Path, timeout_seconds: int) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    raw_log_path.parent.mkdir(parents=True, exist_ok=True)
    last_message_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8") as log_file, raw_log_path.open("w", encoding="utf-8") as raw_file:
        try:
            proc = subprocess.run(
                [
                    CODEX_BIN,
                    "exec",
                    "--full-auto",
                    "--sandbox",
                    "read-only",
                    "-C",
                    str(ROOT),
                    "--output-last-message",
                    str(last_message_path),
                ],
                cwd=ROOT,
                input=prompt,
                text=True,
                stdout=raw_file,
                stderr=log_file,
                timeout=timeout_seconds,
            )
            return proc.returncode
        except subprocess.TimeoutExpired:
            log_file.write(f"\n[TIMEOUT] Codex cluster stage exceeded {timeout_seconds}s.\n")
            return 124


def run_with_retries(provider: str, model: str, prompt: str, log_path: Path, raw_log_path: Path, last_message_path: Path, timeout_seconds: int) -> int:
    rc = 0
    for attempt in range(1, 4):
        if provider == "claude":
            rc = run_claude(prompt, model, log_path, raw_log_path, last_message_path, timeout_seconds)
        else:
            rc = run_codex(prompt, log_path, raw_log_path, last_message_path, timeout_seconds)

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
    challenge_provider = (challenger.get("provider") or "codex").lower()
    challenge_model = challenger.get("model") or "gpt-5.4"
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
    synth_log = cluster_stage_log_path(slug, cluster_id, "synth")
    synth_raw_log = cluster_stage_raw_log_path(slug, cluster_id, "synth")
    synth_last = cluster_stage_last_message_path(slug, cluster_id, "synth")
    challenge_log = cluster_stage_log_path(slug, cluster_id, "challenge")
    challenge_raw_log = cluster_stage_raw_log_path(slug, cluster_id, "challenge")
    challenge_last = cluster_stage_last_message_path(slug, cluster_id, "challenge")

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
    synth_started = time.time()
    rc = run_with_retries(synth_provider, synth_model, synth_prompt, synth_log, synth_raw_log, synth_last, SYNTH_TIMEOUT_SECONDS)
    synth_duration = int(time.time() - synth_started)
    try:
        materialize_cluster_output(synth_path, synth_last, synth_raw_log)
    except Exception:
        pass
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
    append_quota_event(
        phase="phase2",
        slug=slug,
        mode="cluster_synth",
        provider=synth_provider,
        model=synth_model,
        status="ok" if synth_ok else ("timeout" if rc == 124 else "failed"),
        duration_sec=synth_duration,
        component="cluster_stage",
        role="synthesizer",
        cluster_id=cluster_id,
        input_path=cluster_pack_path,
        output_path=synth_path,
        errlog_path=synth_log,
        live_log_path=synth_last,
        raw_log_path=synth_raw_log,
        timeout_seconds=SYNTH_TIMEOUT_SECONDS,
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
    challenge_started = time.time()
    rc = run_with_retries(challenge_provider, challenge_model, challenge_prompt, challenge_log, challenge_raw_log, challenge_last, CHALLENGE_TIMEOUT_SECONDS)
    challenge_duration = int(time.time() - challenge_started)
    try:
        materialize_cluster_output(challenge_path, challenge_last, challenge_raw_log)
    except Exception:
        pass
    normalize_cluster_output(challenge_path, "challenge", cluster_pack)
    challenge_ok = False
    challenge_salvaged = False
    challenge_validation_error = None
    if challenge_path.exists():
        try:
            validate_cluster_output(challenge_path)
            challenge_ok = True
            challenge_salvaged = rc != 0
        except Exception as exc:
            challenge_ok = False
            challenge_validation_error = compact_validation_error(exc)
            if challenge_log:
                with challenge_log.open("a", encoding="utf-8") as handle:
                    handle.write(f"[VALIDATION_ERROR] {challenge_validation_error}\n")
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
        validation_error=challenge_validation_error,
    )
    append_quota_event(
        phase="phase2",
        slug=slug,
        mode="cluster_challenge",
        provider=challenge_provider,
        model=challenge_model,
        status="ok" if challenge_ok else ("timeout" if rc == 124 else "failed"),
        duration_sec=challenge_duration,
        component="cluster_stage",
        role="challenger",
        cluster_id=cluster_id,
        input_path=synth_path,
        output_path=challenge_path,
        errlog_path=challenge_log,
        live_log_path=challenge_last,
        raw_log_path=challenge_raw_log,
        timeout_seconds=CHALLENGE_TIMEOUT_SECONDS,
    )
    return synth_ok, challenge_ok


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Phase 2 cluster synthesis/challenge on an existing cluster plan.")
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--cluster-id", default=None, help="Run only a specific cluster id")
    parser.add_argument("--limit", type=int, default=None, help="Run only the first N clusters")
    parser.add_argument("--codex-bin", default=CODEX_BIN, help="Codex CLI binary/path")
    parser.add_argument("--claude-bin", default=CLAUDE_BIN, help="Claude CLI binary/path")
    parser.add_argument("--claude-safe-tools", default=CLAUDE_SAFE_TOOLS, help="Claude tool list for cluster automation")
    return parser.parse_args()


def main() -> int:
    global CODEX_BIN, CLAUDE_BIN, CLAUDE_SAFE_TOOLS
    args = parse_args()
    CODEX_BIN = args.codex_bin
    CLAUDE_BIN = args.claude_bin
    CLAUDE_SAFE_TOOLS = args.claude_safe_tools
    if not os.environ.get("AUDIT_RUN_ID"):
        os.environ["AUDIT_RUN_ID"] = f"{args.slug}-phase2-clusters-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}-{os.getpid()}"
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

    for path in (cluster_run_errlog_path(args.slug), cluster_run_live_log_path(args.slug)):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("", encoding="utf-8")

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
    return 0 if synth_ok == len(selected) and challenge_ok == len(selected) else 1


if __name__ == "__main__":
    raise SystemExit(main())
