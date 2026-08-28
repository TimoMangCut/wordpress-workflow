#!/usr/bin/env python3
"""
Phase 3b — LLM Skeptic Reviewer.

Reads Phase 2 output + Phase 1 IR (+ optional Semgrep + source) and asks the
selected LLM CLI provider to produce a structured validation report.

ROLE: Skeptic reviewer ONLY. This script should only receive findings that Phase 3a
(phase3_gate.py) classified as UNCERTAIN or RISK_NOTE. CONFIRMED findings bypass
this stage entirely. The LLM must NOT self-confirm findings — it must find
counter-evidence, demand PoC, or propose dynamic tests.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, Optional

try:
    from .report_paths import build_report_layout
    from .artifact_freshness import resolve_phase2_trust_state
    from .phase3_review_contract import normalize_phase3_review_document
except ImportError:  # pragma: no cover - direct script execution
    from report_paths import build_report_layout
    from artifact_freshness import resolve_phase2_trust_state
    from phase3_review_contract import normalize_phase3_review_document

_SCRIPT_DIR = Path(__file__).resolve().parent
_ROOT_DIR = _SCRIPT_DIR.parent.parent  # tools/bin -> tools -> root
CLAUDE_SAFE_TOOLS = os.environ.get("PHASE3_CLAUDE_SAFE_TOOLS", "Read,Grep,Glob")
# Reasoning effort for every claude CLI call (low|medium|high|xhigh|max).
CLAUDE_EFFORT = os.environ.get("CLAUDE_EFFORT", "xhigh")
PHASE3_JSON_TAG = "PHASE3_REVIEW_JSON"
PHASE3_MARKDOWN_TAG = "PHASE3_REVIEW_MARKDOWN"


DEFAULT_TEMPLATE = """# Phase 3b LLM Skeptic Review — `{PLUGIN_SLUG}`

Role: SKEPTIC REVIEWER. Find counter-evidence, demand missing proof, propose tests.
You CANNOT confirm findings — only Phase 3a deterministic gate can do that.

Inputs:
- Canonical review bundle JSON: `{REVIEW_INPUT_PATH}`
- Phase 2 findings JSON: `{PHASE2_PATH}`
- Phase 1 IR JSON: `{IR_PATH}`
- Phase 3a gate JSON: `reports/phase3/{PLUGIN_SLUG}-phase3.json` (top-level keys: `phase3_summary`, `validated_findings`, `actionable_findings`)
- Semgrep JSON (if exists): `{SEMGREP_PATH}`
- Psalm SARIF (if exists): `reports/phase1/{PLUGIN_SLUG}-psalm.sarif`
- Plugin source code: `{PLUGIN_PATH}`

Use `{REVIEW_INPUT_PATH}` as the canonical scope for this review.
It already contains the reviewable findings filtered from `validated_findings` where `validation_status` is `UNCERTAIN` or `RISK_NOTE`.
Do NOT inspect or iterate `.findings[]` from the gate JSON.
Do NOT touch CONFIRMED or REJECTED findings.

All `source_file_path` / `sink_file_path` values must be relative to the plugin root, never prefixed with `plugins/{PLUGIN_SLUG}/`.

For each finding:
1) Search for counter-evidence (guards/sanitizers IR may have missed)
2) Verify code evidence at claimed file:line
3) Assess exploitability honestly
4) Propose dynamic test steps (exact HTTP requests)
5) Recommend: reject / downgrade / keep / upgrade

Do NOT write any files yourself.
The orchestration layer will persist your response after parsing and validation.

Return your entire answer in exactly this envelope:

```text
<PHASE3_REVIEW_JSON>
{ ...valid JSON... }
</PHASE3_REVIEW_JSON>
<PHASE3_REVIEW_MARKDOWN>
# Markdown report...
</PHASE3_REVIEW_MARKDOWN>
```

You may optionally wrap the JSON or markdown payload inside fenced code blocks inside those tags, but do not add any prose outside the tags.

JSON schema:
{{
  "plugin_slug": "...",
  "reviews": [
    {{
      "finding_id": "...",
      "original_status": "UNCERTAIN|RISK_NOTE",
      "verdict_change": "reject|downgrade|keep|upgrade",
      "proposed_final_state": "REJECTED|UNCERTAIN|RISK_NOTE",
      "reopening_condition": "required when verdict_change=reject if you can state it precisely",
      "reason": "...",
      "counter_evidence": [{{"type":"guard|sanitizer|unreachable","file":"...","line":0,"detail":"..."}}],
      "missing_evidence": ["..."],
      "dynamic_test_plan": ["Step 1...", "Step 2..."]
    }}
  ]
}}

If `reviewable_findings` is empty in `{REVIEW_INPUT_PATH}`, write:
- JSON with `"reviews": []`
- Markdown with Plugin Overview, Validation Summary showing zero reviewed findings, Negative Findings, and Overall Assessment
- Do not invent any finding

Markdown sections:
- Plugin Overview
- Validation Summary
- Detailed Reviews (for each reviewed finding MUST include these labels in order:
  Finding ID, Type, Minimum Role/Capability, Status Transition, Description exactly 2 sentences, Highest Impact, PoC setup->activate plugin->attack->verify, counter-evidence, dynamic test plan)
- Negative Findings
- Overall Assessment

Type taxonomy rules (mandatory):
- `Broken Access Control` must stay `Broken Access Control`.
- `Privilege Escalation` must stay `Privilege Escalation`.
- `Arbitrary Option Update` must stay `Arbitrary Option Update`.
- If source text says `Broken Access Control to Change Option`, normalize to `Broken Access Control`.
- Never mix `Broken Access Control` with `Privilege Escalation`.
- For `Arbitrary Option Update`, explicitly describe option key/value impact and whether arbitrary key:value can be changed.

If Type, Minimum Role/Capability, or Status Transition is missing for any finding, the markdown is invalid.
"""


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Phase 3 LLM validator: generate reports/phase3/<index>-<slug>.<provider>.llm.md"
    )
    parser.add_argument("slug", help="Plugin slug")
    parser.add_argument("--reports-dir", default=str(_ROOT_DIR / "reports"), help="Reports directory")
    parser.add_argument("--plugins-dir", default=str(_ROOT_DIR / "plugins"), help="Plugins directory")
    parser.add_argument("--prompt-template", default="", help="Prompt template path")
    parser.add_argument("--force", action="store_true", help="Overwrite existing phase3 markdown")
    parser.add_argument("--index", type=int, default=0, help="IR-order index for output file naming")
    parser.add_argument("--provider", default="codex", choices=["codex", "claude"], help="LLM provider")
    parser.add_argument("--model", default="", help="Optional provider model name")
    parser.add_argument("--codex-bin", default="", help="Codex CLI executable")
    parser.add_argument("--claude-bin", default="", help="Claude Code executable")
    parser.add_argument("--review-output-path", default="", help="Optional output JSON path override")
    parser.add_argument("--err-path", default="", help="Optional stderr log path override")
    parser.add_argument("--output-path", default="", help="Optional output markdown path override")
    parser.add_argument("--raw-path", default="", help="Optional raw provider stream/output path override")
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


def load_system_prompt(root_dir: Path) -> str:
    candidates = [
        root_dir / "tools" / "config" / "system-prompt-phase3.md",
        root_dir / "system-prompt-phase3.md",
    ]
    for c in candidates:
        if c.exists() and c.is_file():
            return c.read_text(encoding="utf-8", errors="replace")
    return "Apply the WordPress AppSec workflow stated in the prompt and project docs directly. Do not rely on auto-loaded skills."


def load_claude_headless_fallback(root_dir: Path) -> str:
    fallback_path = root_dir / "tools" / "config" / "claude-headless-appsec-fallback.md"
    if fallback_path.exists() and fallback_path.is_file():
        return fallback_path.read_text(encoding="utf-8", errors="replace").strip()
    return (
        "Apply the WordPress audit workflow and evidence rules written in this prompt "
        "directly. Do not assume external skill auto-loading."
    )


def normalize_prompt_for_provider(text: str, provider: str) -> str:
    lines = []
    for line in text.splitlines():
        lower = line.lower()
        if "application-security" in lower or "load skill" in lower:
            continue
        lines.append(line)
    text = "\n".join(lines).strip()
    extra = load_claude_headless_fallback(_ROOT_DIR)
    prefix = (
        f"Provider note: you are running via {provider}. "
        "Keep the workflow self-contained; do not rely on provider-specific skill auto-loading."
    )
    if not text:
        return f"{prefix}\n\n{extra}"
    return f"{text}\n\n{prefix}\n\n{extra}"


def provider_display_name(provider: str) -> str:
    return "Claude Code" if provider == "claude" else "Codex CLI"


def provider_timeout_seconds() -> int:
    raw = os.environ.get("PHASE3_PROVIDER_TIMEOUT_SECONDS", "1200").strip()
    try:
        value = int(raw)
    except Exception:
        return 1200
    if value < 0:
        return 1200
    return value


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


def expected_review_count(reports_dir: Path, slug: str) -> int:
    gate_path = build_report_layout(reports_dir).phase3 / f"{slug}-phase3.json"
    if not gate_path.exists():
        return 0
    try:
        gate = json.loads(gate_path.read_text(encoding="utf-8"))
    except Exception:
        return 0
    rows = gate.get("validated_findings", []) or []
    count = 0
    for row in rows:
        status = str(row.get("validation_status", "")).upper()
        if status in {"UNCERTAIN", "RISK_NOTE"}:
            count += 1
    return count


def load_json_file(path: Path) -> Dict[str, Any]:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def semgrep_metadata(path: Path) -> Dict[str, Any]:
    meta: Dict[str, Any] = {
        "path": path.as_posix(),
        "exists": path.exists(),
        "parseable": False,
        "available": False,
        "results_count": 0,
    }
    if not path.exists():
        meta["status"] = "missing"
        return meta
    data = load_json_file(path)
    results = data.get("results", []) if isinstance(data, dict) else []
    if isinstance(results, list):
        meta["parseable"] = True
        meta["available"] = True
        meta["results_count"] = len(results)
        meta["status"] = "ok"
        return meta
    meta["status"] = "invalid"
    return meta


def psalm_metadata(path: Path) -> Dict[str, Any]:
    meta: Dict[str, Any] = {
        "path": path.as_posix(),
        "exists": path.exists(),
        "parseable": False,
        "available": False,
        "results_count": 0,
    }
    if not path.exists():
        meta["status"] = "missing"
        return meta

    data = load_json_file(path)
    if not isinstance(data, dict):
        meta["status"] = "invalid"
        return meta

    if "status" in data:
        meta["parseable"] = True
        meta["status"] = str(data.get("status") or "unknown")
        if "exit_code" in data:
            meta["exit_code"] = data.get("exit_code")
        if "reason" in data:
            meta["reason"] = data.get("reason")
        return meta

    runs = data.get("runs", []) or []
    if not isinstance(runs, list):
        meta["status"] = "invalid"
        return meta

    results = []
    if runs and isinstance(runs[0], dict):
        results = runs[0].get("results", []) or []
    if isinstance(results, list):
        meta["parseable"] = True
        meta["available"] = True
        meta["results_count"] = len(results)
        meta["status"] = "ok"
        return meta

    meta["status"] = "invalid"
    return meta


def build_review_bundle(
    slug: str,
    gate_path: Path,
    phase2_path: Path,
    semgrep_path: Path,
    psalm_path: Path,
) -> Dict[str, Any]:
    gate = load_json_file(gate_path)
    phase2 = load_json_file(phase2_path)

    phase2_findings = phase2.get("findings", []) if isinstance(phase2, dict) else []
    by_id = {
        str(f.get("finding_id")): f
        for f in phase2_findings
        if isinstance(f, dict) and f.get("finding_id")
    }

    validated = gate.get("validated_findings", []) if isinstance(gate, dict) else []
    reviewable = []
    for row in validated or []:
        if not isinstance(row, dict):
            continue
        status = str(row.get("validation_status") or "").upper()
        if status not in {"UNCERTAIN", "RISK_NOTE"}:
            continue
        fid = str(row.get("finding_id") or "")
        reviewable.append(
            {
                "finding_id": fid,
                "validation_status": status,
                "gate_finding": row,
                "phase2_finding": by_id.get(fid, {}),
            }
        )

    return {
        "plugin_slug": slug,
        "phase3_summary": gate.get("phase3_summary", {}) if isinstance(gate, dict) else {},
        "reviewable_count": len(reviewable),
        "reviewable_findings": reviewable,
        "phase2_findings_by_id": by_id,
        "scanner_meta": {
            "semgrep": semgrep_metadata(semgrep_path),
            "psalm": psalm_metadata(psalm_path),
        },
        "gate_contract": {
            "top_level_keys": ["phase3_summary", "validated_findings", "actionable_findings"],
            "canonical_review_source": "validated_findings filtered by validation_status in {UNCERTAIN, RISK_NOTE}",
        },
        "empty_review_behavior": "If reviewable_findings is empty, write reviews=[] and an empty-review markdown without inventing findings.",
    }


def validate_markdown_contract(output_path: Path, expected_count: int) -> Optional[str]:
    if expected_count <= 0:
        return None
    try:
        content = output_path.read_text(encoding="utf-8", errors="replace")
    except Exception as exc:
        return f"Cannot read markdown for validation: {exc}"

    patterns = {
        "Type": r"(?mi)^\s*[-*]\s*Type\s*:",
        "Minimum Role/Capability": r"(?mi)^\s*[-*]\s*Minimum Role/Capability\s*:",
        "Status Transition": r"(?mi)^\s*[-*]\s*Status Transition\s*:",
    }
    for label, pattern in patterns.items():
        hits = len(re.findall(pattern, content))
        if hits < expected_count:
            return (
                f"Markdown contract failed: expected >= {expected_count} `{label}` lines, "
                f"found {hits}."
            )

    forbidden_type_patterns = {
        "Broken Access Control to Change Option": (
            r"(?mi)^\s*[-*]\s*Type\s*:\s*Broken Access Control to Change Option\s*$",
            "Use `Type: Broken Access Control` instead.",
        ),
    }
    for bad_label, (pattern, guidance) in forbidden_type_patterns.items():
        if re.search(pattern, content):
            return f"Markdown contract failed: invalid Type label `{bad_label}`. {guidance}"
    return None


def emit_claude_stream_text(obj: Dict[str, Any], *, allow_result_fallback: bool) -> str:
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


def _strip_optional_code_fence(text: str) -> str:
    candidate = (text or "").strip()
    match = re.fullmatch(r"```(?:json|markdown)?\s*(.*?)\s*```", candidate, re.DOTALL)
    if match:
        return match.group(1).strip()
    return candidate


def extract_tagged_block(text: str, tag: str) -> str:
    pattern = rf"<{tag}>\s*(.*?)\s*</{tag}>"
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        raise ValueError(f"Missing tagged phase3 block: {tag}")
    return _strip_optional_code_fence(match.group(1))


def materialize_phase3_response(
    response_text: str,
    review_output_path: Path,
    markdown_output_path: Path,
    *,
    slug: Optional[str] = None,
) -> None:
    json_block = extract_tagged_block(response_text, PHASE3_JSON_TAG)
    markdown_block = extract_tagged_block(response_text, PHASE3_MARKDOWN_TAG)
    data = normalize_phase3_review_document(json.loads(json_block), slug=slug)
    review_output_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
    markdown_output_path.write_text(markdown_block.rstrip() + "\n", encoding="utf-8")


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
    psalm_path = layout.phase1 / f"{args.slug}-psalm.sarif"
    gate_path = layout.phase3 / f"{args.slug}-phase3.json"
    plugin_path = plugins_dir / args.slug

    phase3_dir = layout.phase3

    output_index = args.index if args.index > 0 else compute_ir_index(args.slug, reports_dir)
    if output_index <= 0:
        print(f"[ERROR] Could not resolve IR-order index for slug: {args.slug}")
        return 1

    output_path = (
        Path(args.output_path).resolve()
        if args.output_path
        else (phase3_dir / f"{output_index}-{args.slug}.{args.provider}.llm.md")
    )
    review_output_path = Path(args.review_output_path).resolve() if args.review_output_path else (phase3_dir / f"{args.slug}-phase3-review.json")
    err_path = Path(args.err_path).resolve() if args.err_path else (layout.phase3_provider_logs(args.slug) / f"{args.provider}.err")
    raw_path = Path(args.raw_path).resolve() if args.raw_path else (layout.phase3_provider_raw_log(args.slug, args.provider))
    err_path.parent.mkdir(parents=True, exist_ok=True)
    raw_path.parent.mkdir(parents=True, exist_ok=True)

    if output_path.exists() and not args.force:
        print(f"[INFO] Skip {args.slug}: phase3 markdown already exists")
        return 0

    missing = []
    if not ir_path.exists():
        missing.append(ir_path.as_posix())
    if not phase2_path.exists():
        missing.append(phase2_path.as_posix())
    if not gate_path.exists():
        missing.append(gate_path.as_posix())
    if not plugin_path.exists() or not plugin_path.is_dir():
        missing.append(plugin_path.as_posix())

    if missing:
        print("[ERROR] Missing required inputs for phase 3:")
        for item in missing:
            print(f"  - {item}")
        return 1

    phase2_trust_state = resolve_phase2_trust_state(phase2_path)
    if phase2_trust_state != "success":
        print(
            f"[ERROR] Phase 2 canonical is not trusted for phase3_llm_review: {phase2_path} "
            f"(trust_state={phase2_trust_state or 'missing'})"
        )
        return 1

    template_path = resolve_template(args, root_dir)
    template = load_template(template_path)

    system_prompt = normalize_prompt_for_provider(load_system_prompt(root_dir), args.provider)
    codex_bin = args.codex_bin or "codex"
    claude_bin = args.claude_bin or "claude"
    timeout_seconds = provider_timeout_seconds()

    print(f"=== Phase 3: {args.slug} ===")
    print(f"  Reports dir: {reports_dir.as_posix()}")
    print(f"  Plugins dir: {plugins_dir.as_posix()}")
    print(f"  LLM provider: {args.provider}")
    if args.model:
        print(f"  LLM model: {args.model}")
    if timeout_seconds > 0:
        print(f"  Provider timeout: {timeout_seconds}s")
    else:
        print("  Provider timeout: disabled")
    if template_path is not None:
        print(f"  Prompt template: {template_path.as_posix()}")
    else:
        print("  Prompt template: built-in default")
    print(f"  Running {provider_display_name(args.provider)} (LLM validation + markdown report)...")

    with tempfile.TemporaryDirectory(prefix="phase3-review-") as temp_dir:
        review_input_path = Path(temp_dir) / f"{args.slug}-phase3-review-input.json"
        provider_last_message_path = Path(temp_dir) / f"{args.provider}.last-message.txt"
        review_bundle = build_review_bundle(args.slug, gate_path, phase2_path, semgrep_path, psalm_path)
        review_input_path.write_text(json.dumps(review_bundle, indent=2), encoding="utf-8")

        replacements = {
            "{PLUGIN_SLUG}": args.slug,
            "{REVIEW_INPUT_PATH}": review_input_path.as_posix(),
            "{PHASE2_PATH}": to_rel(root_dir, phase2_path),
            "{IR_PATH}": to_rel(root_dir, ir_path),
            "{SEMGREP_PATH}": to_rel(root_dir, semgrep_path),
            "{PLUGIN_PATH}": to_rel(root_dir, plugin_path),
            "{REVIEW_OUTPUT_PATH}": to_rel(root_dir, review_output_path),
            "{OUTPUT_PATH}": to_rel(root_dir, output_path),
        }

        resolved_template = template
        for key, value in replacements.items():
            resolved_template = resolved_template.replace(key, value)
        resolved_template = normalize_prompt_for_provider(resolved_template, args.provider)
        provider_response_text = ""

        with err_path.open("w", encoding="utf-8", newline="\n") as err_file, raw_path.open("w", encoding="utf-8", newline="\n") as raw_file:
            _run_start = time.time()
            err_file.write(f"[TIMING] start={_run_start:.3f} provider={args.provider} slug={args.slug}\n")
            try:
                if args.provider == "claude":
                    system_prompt_path = Path(temp_dir) / "system-prompt.txt"
                    system_prompt_path.write_text(system_prompt, encoding="utf-8")
                    cmd = [
                        claude_bin,
                        "-p",
                        "--disable-slash-commands",
                        "--permission-mode",
                        "bypassPermissions",
                        "--tools",
                        CLAUDE_SAFE_TOOLS,
                        "--effort",
                        CLAUDE_EFFORT,
                        "--verbose",
                        "--output-format",
                        "stream-json",
                        "--include-partial-messages",
                        "--append-system-prompt-file",
                        str(system_prompt_path),
                    ]
                    if args.model:
                        cmd.extend(["--model", args.model])
                    cmd.append(resolved_template)
                    try:
                        proc = subprocess.Popen(
                            cmd,
                            cwd=str(root_dir),
                            stdout=subprocess.PIPE,
                            stderr=err_file,
                        )
                        deadline = time.time() + timeout_seconds if timeout_seconds > 0 else None
                        timed_out = False
                        emitted_assistant_text = False
                        assistant_text_chunks = []
                        for raw_line in proc.stdout:
                            if deadline and time.time() > deadline:
                                proc.kill()
                                err_file.write(f"[ERROR] provider timed out after {timeout_seconds}s\n")
                                timed_out = True
                                break
                            line = raw_line.decode("utf-8", errors="replace").strip()
                            if not line:
                                continue
                            raw_file.write(line + "\n")
                            raw_file.flush()
                            try:
                                obj = json.loads(line)
                            except Exception:
                                print(line, flush=True)
                                continue
                            text = emit_claude_stream_text(obj, allow_result_fallback=not emitted_assistant_text)
                            if text:
                                if obj.get("type") != "result":
                                    emitted_assistant_text = True
                                assistant_text_chunks.append(text)
                                print(text, end="", flush=True)
                            if obj.get("type") == "message_stop":
                                print(flush=True)
                        provider_response_text = "".join(assistant_text_chunks)
                        if timed_out:
                            _run_end = time.time()
                            _elapsed = _run_end - _run_start
                            err_file.write(
                                f"[TIMING] end={_run_end:.3f} elapsed={_elapsed:.1f}s exit=timeout\n"
                            )
                            result = subprocess.CompletedProcess(cmd, 124)
                        else:
                            proc.wait()
                            _run_end = time.time()
                            _elapsed = _run_end - _run_start
                            err_file.write(
                                f"[TIMING] end={_run_end:.3f} elapsed={_elapsed:.1f}s exit=normal rc={proc.returncode}\n"
                            )
                            result = subprocess.CompletedProcess(cmd, proc.returncode)
                    except Exception as exc:
                        err_file.write(f"[ERROR] Popen failed: {exc}\n")
                        _run_end = time.time()
                        _elapsed = _run_end - _run_start
                        err_file.write(
                            f"[TIMING] end={_run_end:.3f} elapsed={_elapsed:.1f}s exit=exception\n"
                        )
                        result = subprocess.CompletedProcess(cmd, 1)
                else:
                    prompt = f"{system_prompt}\n\n{resolved_template}"
                    cmd = [
                        codex_bin,
                        "exec",
                        "--full-auto",
                        "--sandbox",
                        "read-only",
                        "--skip-git-repo-check",
                        "--output-last-message",
                        str(provider_last_message_path),
                    ]
                    if args.model:
                        cmd.extend(["--model", args.model])
                    cmd.append(prompt)
                    result = subprocess.run(
                        cmd,
                        cwd=str(root_dir),
                        stdout=subprocess.PIPE,
                        text=True,
                        stderr=err_file,
                        timeout=timeout_seconds if timeout_seconds > 0 else None,
                    )
                    if result.stdout:
                        raw_file.write(result.stdout)
                        raw_file.flush()
                        print(result.stdout, end="", flush=True)
                    if provider_last_message_path.exists():
                        provider_response_text = provider_last_message_path.read_text(encoding="utf-8", errors="replace")
                    else:
                        provider_response_text = result.stdout or ""
                    _run_end = time.time()
                    _elapsed = _run_end - _run_start
                    err_file.write(
                        f"[TIMING] end={_run_end:.3f} elapsed={_elapsed:.1f}s exit=normal rc={result.returncode}\n"
                    )
            except subprocess.TimeoutExpired:
                err_file.write(f"[ERROR] provider timed out after {timeout_seconds}s\n")
                _run_end = time.time()
                _elapsed = _run_end - _run_start
                err_file.write(
                    f"[TIMING] end={_run_end:.3f} elapsed={_elapsed:.1f}s exit=timeout\n"
                )
                result = subprocess.CompletedProcess(cmd, 124)

    if result.returncode != 0:
        print(f"[ERROR] {provider_display_name(args.provider)} phase3 failed")
        print(f"  - log: {err_path.as_posix()}")
        return 1

    try:
        materialize_phase3_response(provider_response_text, review_output_path, output_path, slug=args.slug)
    except Exception as exc:
        print(f"[ERROR] Phase3 response materialization failed: {exc}")
        print(f"  - raw: {raw_path.as_posix()}")
        print(f"  - log: {err_path.as_posix()}")
        return 1

    if not output_path.exists():
        print("[ERROR] Phase3 markdown not generated")
        print(f"  - output: {output_path.as_posix()}")
        print(f"  - log: {err_path.as_posix()}")
        return 1

    if not review_output_path.exists():
        print("[ERROR] Phase3 review JSON not generated")
        print(f"  - output: {review_output_path.as_posix()}")
        print(f"  - log: {err_path.as_posix()}")
        return 1

    expected_count = expected_review_count(reports_dir, args.slug)
    contract_err = validate_markdown_contract(output_path, expected_count)
    if contract_err:
        print(f"[ERROR] {contract_err}")
        print(f"  - output: {output_path.as_posix()}")
        return 1

    print(f"[OK] Output: {output_path.as_posix()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
