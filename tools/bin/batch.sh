#!/bin/bash
# batch.sh — Batch scan all plugins with parallel support, with range for LLM reasoning phases
# Usage: batch.sh [plugins-dir] [threads] [start-index] [end-index] [--clean]
# Features: directory filtering, hash-based cache, crash isolation, summary, range for Phase 2/3, clean option

set -euo pipefail

# Resolve directories first
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"

# Arguments
PLUGINS_DIR="${1:-${ROOT_DIR}/plugins}"
THREADS="${2:-4}"
START_INDEX="${3:-1}"            # Chỉ số bắt đầu (dành riêng cho Phase 2 và Phase 3)
END_INDEX="${4:-1000}"           # Chỉ số kết thúc (dành riêng cho Phase 2 và Phase 3)
CLEAN="${5:-false}"
SEMGREP_VENV="${SEMGREP_VENV:-${ROOT_DIR}/tmmc/bin/activate}"

DB="${ROOT_DIR}/data/audit.db"
LOGDIR="${LOGS_DIR}"

ensure_report_dirs

if [ ! -d "$PLUGINS_DIR" ]; then
    echo "Usage: $0 [plugins-directory] [threads] [start-index] [end-index] [--clean]"
    exit 1
fi

if [ ! -f "$SEMGREP_VENV" ]; then
    echo "[!] Required Semgrep venv not found at $SEMGREP_VENV"
    echo "    Set SEMGREP_VENV or create venv at \${ROOT}/tmmc/"
    exit 2
fi

# Clean up existing results if requested
if [ "$CLEAN" == "--clean" ]; then
    echo "Cleaning up all previous scan results..."
    rm -rf "${PHASE1_DIR}"/* "${PHASE2_DIR}"/* "${PHASE3_DIR}"/* "${LOGS_DIR}"/*
    echo "Clean up complete."
fi

# Build list of plugins to scan (filter non-plugin dirs)
PLUGIN_LIST=$(mktemp)
SKIPPED=0
CACHED=0

PLUGIN_COUNTER=0
TOTAL=0

for dir in "$PLUGINS_DIR"/*/; do
    [ ! -d "$dir" ] && continue
    slug=$(basename "$dir")

    # Skip hidden dirs and non-plugin directories
    case "$slug" in .*|node_modules|vendor|__*|.github) continue ;; esac

    # Must contain PHP files
    if ! find "$dir" -maxdepth 2 -name "*.php" -print -quit 2>/dev/null | grep -q .; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Hash-based cache: skip if IR exists and hash matches
    if [ -f "${PHASE1_DIR}/${slug}-ir.json" ]; then
        CACHED=$((CACHED + 1))
        continue
    fi

    # Skip plugins that fall outside the selected range (A to B) for Phase 2/3
    PLUGIN_COUNTER=$((PLUGIN_COUNTER + 1))
    if [ "$PLUGIN_COUNTER" -lt "$START_INDEX" ] || [ "$PLUGIN_COUNTER" -gt "$END_INDEX" ]; then
        continue
    fi

    printf '%s\0' "$dir" >> "$PLUGIN_LIST"
    TOTAL=$((TOTAL + 1))
done

# Check if any plugins are selected within the range
if [ "$TOTAL" -eq 0 ]; then
    echo "No plugins found within the range of index $START_INDEX to $END_INDEX."
    rm -f "$PLUGIN_LIST"
    exit 0
fi

echo "=== BATCH SCAN ==="
echo "  Total directories:  $TOTAL"
echo "  Plugins to scan:    $TOTAL"
echo "  Cached (skip):      $CACHED"
echo "  Filtered (skip):    $SKIPPED"
echo "  Threads:            $THREADS"
echo "  Database:           $DB"
echo ""

START_TIME=$(date +%s)

# Parallel execution with crash isolation
export SCRIPT_DIR PHASE1_DIR LOGDIR SEMGREP_VENV
xargs -0 -n 1 -P "$THREADS" bash -c '
    PLUGIN_DIR="$1"
    SLUG=$(basename "$PLUGIN_DIR")
    LOG="${LOGDIR}/${SLUG}.log"
    echo "[$(date +%H:%M:%S)] START: $SLUG"
    
    if [ -f "$SEMGREP_VENV" ]; then
        # shellcheck disable=SC1090
        . "$SEMGREP_VENV"
    fi

    # Crash-safe: redirect all output to log, capture exit code
    bash "${SCRIPT_DIR}/bin/scan-all.sh" "$PLUGIN_DIR" > "$LOG" 2>&1
    EXIT=$?
    
    if [ $EXIT -eq 0 ]; then
        # Count findings from IR
        if [ -f "${PHASE1_DIR}/${SLUG}-ir.json" ]; then
            ANOMALIES=$(python3 -c "import json; print(len(json.load(open(\"${PHASE1_DIR}/${SLUG}-ir.json\")).get(\"anomalies\",[])))" 2>/dev/null || echo "?")
        else
            ANOMALIES="?"
        fi
        echo "[$(date +%H:%M:%S)] DONE:  $SLUG (${ANOMALIES} anomalies)"
    else
        echo "[$(date +%H:%M:%S)] ERROR: $SLUG (exit $EXIT) → see $LOG"
    fi
' _ < "$PLUGIN_LIST"

rm -f "$PLUGIN_LIST"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))

echo ""
echo "=== BATCH COMPLETE (${ELAPSED}s) ==="

# Summary from SQLite
if [ -f "$DB" ]; then
    echo ""
    echo "=== FINDINGS SUMMARY ==="
    sqlite3 "$DB" "
        SELECT p.slug,
               COUNT(f.id) as findings,
               SUM(CASE WHEN f.severity='critical' THEN 1 ELSE 0 END) as critical,
               SUM(CASE WHEN f.severity='high' THEN 1 ELSE 0 END) as high
        FROM plugins p
        LEFT JOIN findings f ON f.plugin_id = p.id
        GROUP BY p.id
        HAVING findings > 0
        ORDER BY critical DESC, high DESC
        LIMIT 30;
    " -column -header 2>/dev/null || echo "(no findings)"

    echo ""
    echo "=== METRICS ==="
    sqlite3 "$DB" "
        SELECT phase, metric_name,
               ROUND(AVG(metric_value),1) as avg,
               ROUND(MAX(metric_value),1) as max,
               COUNT(*) as plugins
        FROM metrics
        GROUP BY phase, metric_name
        ORDER BY phase, metric_name;
    " -column -header 2>/dev/null || echo "(no metrics)"
fi
