#!/bin/bash
# batch-scan-parallel.sh - Parallel Semgrep-only scan for all plugins.
# Usage: batch-scan-parallel.sh [plugins-dir] [threads]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
PLUGINS_DIR="${1:-${ROOT_DIR}/plugins}"
THREADS="${2:-4}"
LOGDIR="${LOGS_DIR}"
SEMGREP_VENV="${SEMGREP_VENV:-${ROOT_DIR}/tmmc/bin/activate}"

if [ ! -d "$PLUGINS_DIR" ]; then
    echo "Usage: $0 [plugins-directory] [threads]"
    exit 1
fi

if [ ! -f "$SEMGREP_VENV" ]; then
    echo "[!] Required Semgrep venv not found at $SEMGREP_VENV"
    echo "    Set SEMGREP_VENV or create venv at \${ROOT}/tmmc/"
    exit 2
fi

ensure_report_dirs

PLUGIN_LIST=$(mktemp)
TOTAL=0
SKIPPED=0

for dir in "$PLUGINS_DIR"/*/; do
    [ ! -d "$dir" ] && continue
    slug=$(basename "$dir")

    # Skip hidden/common non-plugin directories.
    case "$slug" in .*|node_modules|vendor|__*|.github) continue ;; esac

    # Must contain at least one PHP file.
    if ! find "$dir" -maxdepth 2 -name "*.php" -print -quit 2>/dev/null | grep -q .; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    printf '%s\0' "$dir" >> "$PLUGIN_LIST"
    TOTAL=$((TOTAL + 1))
done

if [ "$TOTAL" -eq 0 ]; then
    echo "No plugins to scan."
    rm -f "$PLUGIN_LIST"
    exit 0
fi

echo "=== SEMGREP BATCH SCAN ==="
echo "  Plugins dir:      $PLUGINS_DIR"
echo "  Plugins to scan:  $TOTAL"
echo "  Filtered (skip):  $SKIPPED"
echo "  Threads:          $THREADS"
echo "  Venv:             $SEMGREP_VENV"
echo ""

START_TIME=$(date +%s)

export SCRIPT_DIR PHASE1_DIR LOGDIR SEMGREP_VENV
xargs -0 -n 1 -P "$THREADS" bash -c '
    PLUGIN_DIR="$1"
    SLUG=$(basename "$PLUGIN_DIR")
    LOG="${LOGDIR}/${SLUG}-semgrep.log"
    echo "[$(date +%H:%M:%S)] START: $SLUG"

    if [ -f "$SEMGREP_VENV" ]; then
        # shellcheck disable=SC1090
        . "$SEMGREP_VENV"
    fi

    # Always scan and overwrite old semgrep json.
    bash "${SCRIPT_DIR}/bin/scan-semgrep.sh" "$PLUGIN_DIR" > "$LOG" 2>&1
    EXIT=$?
    if [ $EXIT -eq 0 ]; then
        FINDINGS=$(python3 -c "import json; print(len(json.load(open(\"${PHASE1_DIR}/${SLUG}-semgrep.json\")).get(\"results\",[])))" 2>/dev/null || echo "?")
        echo "[$(date +%H:%M:%S)] DONE:  $SLUG ($FINDINGS findings)"
    else
        echo "[$(date +%H:%M:%S)] ERROR: $SLUG (exit $EXIT) -> see $LOG"
    fi
' _ < "$PLUGIN_LIST"

rm -f "$PLUGIN_LIST"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "=== SEMGREP BATCH COMPLETE (${ELAPSED}s) ==="
echo "Reports in: $PHASE1_DIR"
