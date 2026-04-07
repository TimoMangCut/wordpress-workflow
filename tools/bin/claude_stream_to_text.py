#!/usr/bin/env python3
"""Extract incremental text content from Claude stream-json output."""

from __future__ import annotations

import json
import sys


def main() -> int:
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", errors="replace").rstrip("\n")
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            print(line, flush=True)
            continue

        event_type = obj.get("type", "")
        if event_type == "content_block_delta":
            delta = obj.get("delta", {})
            if delta.get("type") == "text_delta":
                print(delta.get("text", ""), end="", flush=True)
        elif event_type == "message_stop":
            print(flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
