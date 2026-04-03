#!/bin/bash
# Shared timeout helpers for workflow scripts.

TIMEOUT_CMD=()
TIMEOUT_BACKEND="none"

resolve_timeout_backend() {
    if [ -n "${TIMEOUT_BIN:-}" ]; then
        if [ -x "${TIMEOUT_BIN}" ]; then
            TIMEOUT_CMD=("${TIMEOUT_BIN}")
            TIMEOUT_BACKEND="custom"
            return 0
        fi
        if command -v "${TIMEOUT_BIN}" >/dev/null 2>&1; then
            TIMEOUT_CMD=("$(command -v "${TIMEOUT_BIN}")")
            TIMEOUT_BACKEND="custom"
            return 0
        fi
    fi

    if command -v timeout >/dev/null 2>&1; then
        TIMEOUT_CMD=("$(command -v timeout)")
        TIMEOUT_BACKEND="timeout"
        return 0
    fi

    if command -v gtimeout >/dev/null 2>&1; then
        TIMEOUT_CMD=("$(command -v gtimeout)")
        TIMEOUT_BACKEND="gtimeout"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        TIMEOUT_BACKEND="python3"
        return 0
    fi

    TIMEOUT_BACKEND="none"
    return 1
}

timeout_run() {
    local seconds="$1"
    shift

    case "$TIMEOUT_BACKEND" in
        timeout|gtimeout|custom)
            "${TIMEOUT_CMD[@]}" "$seconds" "$@"
            ;;
        python3)
            python3 - "$seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = int(sys.argv[1])
command = sys.argv[2:]

try:
    completed = subprocess.run(command, timeout=timeout_seconds, check=False)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except FileNotFoundError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(127)
except PermissionError as exc:
    print(str(exc), file=sys.stderr)
    sys.exit(126)
PY
            ;;
        *)
            if command -v log_warn >/dev/null 2>&1; then
                log_warn "timeout command not found; running without timeout guard" >&2
            else
                echo "[WARN] timeout command not found; running without timeout guard" >&2
            fi
            "$@"
            ;;
    esac
}
