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
    "PHASE2_PRIMARY_PROVIDER",
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
