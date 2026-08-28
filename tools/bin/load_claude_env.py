#!/usr/bin/env python3
"""Load project-local Claude settings env values as shell exports.

This reads `.claude/settings.json` and `.claude/settings.local.json` from the
repository root, merges their `env` objects using Claude's documented
project/local precedence, and emits shell-safe `export KEY='value'` lines.
"""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from typing import Dict


ALLOWED_KEYS = {
    "LLM_PROVIDER",
    "LLM_PROVIDERS",
    "CODEX_BIN",
    "CODEX_MODEL",
    "CLAUDE_BIN",
    "CLAUDE_MODEL",
    "CLAUDE_EFFORT",
    "PHASE2_PRIMARY_PROVIDER",
    "PHASE2_PROVIDER_TIMEOUT_SECONDS",
    "PHASE2_WORKER_TIMEOUT_SECONDS",
    "PHASE2_REVISION_TIMEOUT_SECONDS",
    "PHASE2_REVIEWER_TIMEOUT_SECONDS",
    "PHASE2_EXPLORATION_TIMEOUT_SECONDS",
    "PHASE2_WORKER_PROVIDER",
    "PHASE2_WORKER_CHUNK_PARALLEL_LIMIT",
    "PHASE2_REVIEWER_BATCH_PARALLEL_LIMIT",
    "PHASE2_REVIEWER_PROVIDER",
    "PHASE2_EXPLORE_PROVIDER",
    "PHASE2_WORKER_CODEX_MODEL",
    "PHASE2_WORKER_CLAUDE_MODEL",
    "PHASE2_REVIEWER_CODEX_MODEL",
    "PHASE2_REVIEWER_CLAUDE_MODEL",
    "PHASE2_MAX_REVIEW_ROUNDS",
    "PHASE2_ENABLE_FORCED_EXPLORATION",
    "PHASE2_MAX_EXPLORATION_CANDIDATES",
    "PHASE2_CLUSTER_SYNTH_PROVIDER",
    "PHASE2_CLUSTER_SYNTH_CODEX_MODEL",
    "PHASE2_CLUSTER_SYNTH_CLAUDE_MODEL",
    "PHASE2_CLUSTER_CHALLENGER_PROVIDER",
    "PHASE2_CLUSTER_CHALLENGER_CODEX_MODEL",
    "PHASE2_CLUSTER_CHALLENGER_CLAUDE_MODEL",
    "PHASE2_CLUSTER_SYNTH_TIMEOUT_SECONDS",
    "PHASE2_CLUSTER_CHALLENGE_TIMEOUT_SECONDS",
    "PHASE3_PRIMARY_PROVIDER",
}


def load_json(path: Path) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def main() -> int:
    parser = argparse.ArgumentParser(description="Emit shell exports from .claude settings env")
    parser.add_argument("--root", required=True, help="Repository root")
    args = parser.parse_args()

    root = Path(args.root).resolve()
    claude_dir = root / ".claude"

    merged: Dict[str, str] = {}
    for path in (claude_dir / "settings.json", claude_dir / "settings.local.json"):
        data = load_json(path)
        env = data.get("env", {})
        if not isinstance(env, dict):
            continue
        for key, value in env.items():
            if key not in ALLOWED_KEYS:
                continue
            merged[key] = str(value)

    for key in sorted(merged):
        print(f"export {key}={shlex.quote(merged[key])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
