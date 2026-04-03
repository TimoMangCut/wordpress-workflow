#!/bin/bash
# batch.sh — Phase 1 batch scan with parallel support
# Usage: batch.sh [plugins-dir] [threads]

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "${BIN_DIR}/.." && pwd)"          # updated-scripts/
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"         # tools/
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"           # project root

PLUGINS_DIR="${1:-${ROOT_DIR}/plugins}"
THREADS="${2:-4}"
REPORTS="${ROOT_DIR}/reports"
DB="${ROOT_DIR}/data/audit.db"

mkdir -p "$REPORTS" "$REPORTS/logs"

if [ ! -d "$PLUGINS_DIR" ]; then
    echo "Usage: $0 [plugins-directory] [threads]"
    exit 1
fi

# Activate venv for semgrep
VENV_PATH="${ROOT_DIR}/tmmc/bin/activate"
[ -f "$VENV_PATH" ] && source "$VENV_PATH"

# Build plugin list (filter non-plugin dirs)
PLUGIN_LIST=$(mktemp)
SKIPPED=0
CACHED=0
TOTAL=0

for dir in "$PLUGINS_DIR"/*/; do
    [ ! -d "$dir" ] && continue
    slug=$(basename "$dir")
    case "$slug" in .*|node_modules|vendor|__*|.github) continue ;; esac
    if ! find "$dir" -maxdepth 2 -name "*.php" -print -quit 2>/dev/null | grep -q .; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if [ -f "${REPORTS}/${slug}-ir.json" ]; then
        CACHED=$((CACHED + 1))
        continue
    fi
    printf '%s\0' "$dir" >> "$PLUGIN_LIST"
    TOTAL=$((TOTAL + 1))
done

echo "=== PHASE 1 BATCH ==="
echo "  To scan: $TOTAL | Cached: $CACHED | Filtered: $SKIPPED | Threads: $THREADS"

if [ "$TOTAL" -eq 0 ]; then
    echo "Nothing to scan."
    rm -f "$PLUGIN_LIST"
    exit 0
fi

START_TIME=$(date +%s)

export SCRIPT_DIR REPORTS
xargs -0 -n 1 -P "$THREADS" bash -c '
    PLUGIN_DIR="$1"
    SLUG=$(basename "$PLUGIN_DIR")
    LOG="${REPORTS}/logs/${SLUG}-phase1.log"
    echo "[$(date +%H:%M:%S)] START: $SLUG"
    bash "${SCRIPT_DIR}/bin/scan-all.sh" "$PLUGIN_DIR" > "$LOG" 2>&1
    EXIT=$?
    if [ $EXIT -eq 0 ]; then
        ANOMS=$(python3 -c "import json; print(len(json.load(open(\"${REPORTS}/${SLUG}-ir.json\")).get(\"anomalies\",[])))" 2>/dev/null || echo "?")
        echo "[$(date +%H:%M:%S)] DONE:  $SLUG (${ANOMS} anomalies)"
    else
        echo "[$(date +%H:%M:%S)] ERROR: $SLUG (exit $EXIT)"
    fi
' _ < "$PLUGIN_LIST"

rm -f "$PLUGIN_LIST"
ELAPSED=$(( $(date +%s) - START_TIME ))

echo ""
echo "=== BATCH COMPLETE (${ELAPSED}s) ==="
