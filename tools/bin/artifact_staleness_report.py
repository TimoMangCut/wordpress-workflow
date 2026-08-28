#!/usr/bin/env python3
"""Report artifacts that are older than the inputs they were derived from.

Phase 1 -> 2 -> 3 artifacts are written at different times and survive independently. When a
tool changes and Phase 1 is re-extracted, a Phase 2/3 report built on the previous IR keeps
sitting in reports/ looking authoritative. That happened here: a Phase 3 report claiming
"58 findings, 0 confirmed" sat next to a Phase 2 canonical holding 145 findings, because the
Phase 3 run had been refused and the earlier file was never cleared.

Freshness checks inside the runners only decide whether to re-run a stage. Nothing audits the
tree afterwards, so this does.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
from pathlib import Path


def mtime(path: str) -> float | None:
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reports-dir", default="reports")
    parser.add_argument("--strict", action="store_true",
                        help="exit 1 if any artifact is stale or untrusted")
    args = parser.parse_args()

    root = Path(args.reports_dir)
    slugs = sorted({Path(p).name.replace("-ir.json", "")
                    for p in glob.glob(str(root / "phase1" / "*-ir.json"))})

    problems = 0
    rows = []
    for slug in slugs:
        ir = mtime(str(root / "phase1" / f"{slug}-ir.json"))
        p2_path = root / "phase2" / f"{slug}-phase2.json"
        p2 = mtime(str(p2_path))
        p3 = mtime(str(root / "phase3" / f"{slug}-phase3.json"))
        finals = glob.glob(str(root / "final" / f"*-{slug}.md"))
        fin = mtime(finals[0]) if finals else None

        trust = ""
        if p2:
            try:
                trust = json.loads(p2_path.read_text(encoding="utf-8")).get("trust_state") or ""
            except Exception:
                trust = "unreadable"

        flags = []
        if p2 and ir and p2 < ir:
            flags.append("phase2 older than IR")
        if p3 and p2 and p3 < p2:
            flags.append("phase3 older than phase2")
        if fin and p2 and fin < p2:
            flags.append("final older than phase2")
        if p3 and not p2:
            flags.append("phase3 without phase2")
        # An absent artifact is not a coherent one. Reporting "ok" for a plugin that was never
        # analysed past Phase 1 hides unfinished work behind a clean-looking row.
        if not p2:
            flags.append("no phase2 (Phase 1 only)")
        elif not p3:
            flags.append("no phase3")
        if trust and trust != "success":
            flags.append(f"trust={trust}")
        if flags:
            problems += 1
        rows.append((slug, flags))

    width = max((len(s) for s, _ in rows), default=10) + 2
    for slug, flags in rows:
        status = "; ".join(flags) if flags else "coherent"
        marker = "STALE" if flags else "  ok "
        print(f"[{marker}] {slug:<{width}} {status}")

    print(f"\n{problems}/{len(rows)} plugin(s) need attention")
    return 1 if (args.strict and problems) else 0


if __name__ == "__main__":
    raise SystemExit(main())
