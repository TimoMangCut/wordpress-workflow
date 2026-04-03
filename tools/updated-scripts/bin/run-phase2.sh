#!/bin/bash
# run-phase2.sh — Phase 2 LLM Deep Reasoning
# Usage:
#   run-phase2.sh <plugin-slug>                    # Single plugin
#   run-phase2.sh --start 1 --end 10               # Range from plugins_sorted_numbered.txt
#   run-phase2.sh --start 1 --end 10 --threads 2   # Parallel (careful with quota!)
#
# Features:
#   - Index-based range for quota management
#   - Lightweight prompt for plugins with 0 findings (still analyzed, not skipped)
#   - Skip already-analyzed plugins (override with --force)

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "${BIN_DIR}/.." && pwd)"          # updated-scripts/
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"         # tools/
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"           # project root

# Defaults
SLUG=""
START_IDX=""
END_IDX=""
THREADS=1
FORCE=false
PLUGIN_LIST_FILE="${ROOT_DIR}/plugins_sorted_numbered.txt"

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --start) START_IDX="$2"; shift 2 ;;
        --end) END_IDX="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --list) PLUGIN_LIST_FILE="$2"; shift 2 ;;
        -*) echo "Unknown option: $1"; exit 1 ;;
        *) SLUG="$1"; shift ;;
    esac
done

# Build plugin list
WORK_LIST=$(mktemp)

if [ -n "$SLUG" ]; then
    # Single plugin mode
    echo "$SLUG" > "$WORK_LIST"
elif [ -n "$START_IDX" ] && [ -n "$END_IDX" ]; then
    # Range mode from sorted list
    if [ ! -f "$PLUGIN_LIST_FILE" ]; then
        echo "[!] Plugin list not found: $PLUGIN_LIST_FILE"
        echo "    Generate with: ls plugins/ | sort > plugins_sorted_numbered.txt"
        exit 1
    fi
    # Extract slugs for range (handle numbered or plain list)
    awk -v start="$START_IDX" -v end="$END_IDX" '
        NR >= start && NR <= end {
            # Strip leading number/dot/space if present
            gsub(/^[0-9]+[\.\)\s]+\s*/, "")
            if ($0 != "") print $0
        }
    ' "$PLUGIN_LIST_FILE" > "$WORK_LIST"
    
    TOTAL=$(wc -l < "$WORK_LIST")
    echo "=== PHASE 2: Range $START_IDX–$END_IDX ($TOTAL plugins) ==="
    echo "  Threads: $THREADS"
else
    echo "Usage:"
    echo "  run-phase2.sh <plugin-slug>"
    echo "  run-phase2.sh --start 1 --end 10 [--threads 2] [--force]"
    rm "$WORK_LIST"
    exit 1
fi

# Process function (called per plugin, supports parallel)
process_plugin() {
    local SLUG="$1"
    local IR_FILE="${ROOT_DIR}/reports/${SLUG}-ir.json"
    local SEMGREP_FILE="${ROOT_DIR}/reports/${SLUG}-semgrep.json"
    local OUTPUT="${ROOT_DIR}/reports/${SLUG}-phase2.json"
    local PLUGIN_DIR="${ROOT_DIR}/plugins/${SLUG}"

    # Skip if already done (unless --force)
    if [ "$FORCE" = "false" ] && [ -f "$OUTPUT" ]; then
        echo "[SKIP] $SLUG (already analyzed)"
        return 0
    fi

    # Check plugin source exists
    if [ ! -d "$PLUGIN_DIR" ]; then
        echo "[MISS] $SLUG (no source in plugins/)"
        return 0
    fi

    # Count findings from Phase 1
    local ANOM_COUNT=0
    local SEMGREP_COUNT=0
    if [ -f "$IR_FILE" ]; then
        ANOM_COUNT=$(python3 -c "import json; print(len(json.load(open('$IR_FILE')).get('anomalies',[])))" 2>/dev/null || echo "0")
    fi
    if [ -f "$SEMGREP_FILE" ]; then
        SEMGREP_COUNT=$(python3 -c "import json; print(len(json.load(open('$SEMGREP_FILE')).get('results',[])))" 2>/dev/null || echo "0")
    fi
    local TOTAL_FINDINGS=$((ANOM_COUNT + SEMGREP_COUNT))

    # Determine prompt mode
    local PROMPT=""
    if [ "$TOTAL_FINDINGS" -gt 0 ]; then
        # === FULL DEEP ANALYSIS ===
        echo "[DEEP] $SLUG ($ANOM_COUNT anomalies + $SEMGREP_COUNT semgrep)"
        PROMPT="Audit plugin \`$SLUG\`. Phase 1 IR: \`${ROOT_DIR}/reports/${SLUG}-ir.json\`. Semgrep: \`${ROOT_DIR}/reports/${SLUG}-semgrep.json\`. Source code: \`${ROOT_DIR}/plugins/${SLUG}/\`. Output: \`${ROOT_DIR}/reports/${SLUG}-phase2.json\`"
    else
        # === LIGHTWEIGHT SCAN (no Phase 1 findings) ===
        echo "[LITE] $SLUG (0 findings — lightweight scan)"
        PROMPT="Quick security scan of plugin \`$SLUG\`. Phase 1 found NO anomalies. Source code: \`${ROOT_DIR}/plugins/${SLUG}/\`. Scan entry points for obvious auth/access issues, unsafe SQL, and unescaped output. Brief analysis only — focus on high-impact patterns. Output: \`${ROOT_DIR}/reports/${SLUG}-phase2.json\`"

        # If no IR exists at all, run Phase 1 extract first
        if [ ! -f "$IR_FILE" ]; then
            echo "  [!] No IR file — running Phase 1 extract..."
            if [ -f "${TOOLS_DIR}/vendor/autoload.php" ]; then
                php "${TOOLS_DIR}/bin/extract.php" "$PLUGIN_DIR" --db="${ROOT_DIR}/data/audit.db" 2>/dev/null || true
            fi
        fi
    fi

    # Run Codex CLI
    codex exec --full-auto \
        "$PROMPT" \
        2>"${ROOT_DIR}/reports/logs/${SLUG}-phase2.err" || {
            echo "  [!] Codex failed for $SLUG"
            return 1
        }

    # Verify output
    if [ -f "$OUTPUT" ]; then
        python3 -c "
import json
d = json.load(open('$OUTPUT'))
tp = d.get('true_positives', 0)
fp = d.get('false_positives', 0)
print(f'  → {tp} TP, {fp} FP, risk={d.get(\"overall_risk\",\"?\")}')" 2>/dev/null || true
    fi
}

export -f process_plugin
export FORCE ROOT_DIR TOOLS_DIR

# Execute
if [ "$THREADS" -gt 1 ]; then
    echo "  Running $THREADS threads in parallel..."
    cat "$WORK_LIST" | xargs -P "$THREADS" -I {} bash -c 'process_plugin "$@"' _ {}
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        process_plugin "$slug"
    done < "$WORK_LIST"
fi

rm "$WORK_LIST"
echo "=== Phase 2 Complete ==="
