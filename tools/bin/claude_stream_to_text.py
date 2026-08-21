#!/usr/bin/env python3
"""Extract incremental text content from Claude stream-json output."""

from __future__ import annotations

import json
import sys


def emit_text_from_message(message: object) -> bool:
    emitted = False
    if not isinstance(message, dict):
        return emitted
    content = message.get("content")
    if not isinstance(content, list):
        return emitted
    for block in content:
        if not isinstance(block, dict):
            continue
        if block.get("type") == "text":
            text = block.get("text", "")
            if text:
                print(text, end="", flush=True)
                emitted = True
    return emitted


def main() -> int:
    emitted_text = False
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
                emitted_text = True
        elif event_type == "assistant":
            emitted_text = emit_text_from_message(obj.get("message")) or emitted_text
        elif event_type == "message_stop":
            print(flush=True)
        elif event_type == "result":
            result_text = obj.get("result")
            if isinstance(result_text, str) and result_text and not emitted_text:
                print(result_text, flush=True)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
