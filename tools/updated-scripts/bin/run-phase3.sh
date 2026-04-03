#!/bin/bash
# run-phase3.sh — Phase 3 Semantic Validation
# Usage:
#   run-phase3.sh <plugin-slug>                    # Single plugin
#   run-phase3.sh --start 1 --end 10               # Range
#   run-phase3.sh --start 1 --end 10 --threads 4   # Parallel (no LLM, safe to parallelize)

set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "${BIN_DIR}/.." && pwd)"          # updated-scripts/
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"         # tools/
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"           # project root

SLUG=""
START_IDX=""
END_IDX=""
THREADS=1
FORCE=false
PLUGIN_LIST_FILE="${ROOT_DIR}/plugins_sorted_numbered.txt"

while [[ $# -gt 0 ]]; do
    case $1 in
        --start) START_IDX="$2"; shift 2 ;;
        --end) END_IDX="$2"; shift 2 ;;
        --threads) THREADS="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --list) PLUGIN_LIST_FILE="$2"; shift 2 ;;
        -*) shift ;;
        *) SLUG="$1"; shift ;;
    esac
done

WORK_LIST=$(mktemp)

if [ -n "$SLUG" ]; then
    echo "$SLUG" > "$WORK_LIST"
elif [ -n "$START_IDX" ] && [ -n "$END_IDX" ]; then
    if [ ! -f "$PLUGIN_LIST_FILE" ]; then
        echo "[!] Plugin list not found: $PLUGIN_LIST_FILE"
        exit 1
    fi
    awk -v start="$START_IDX" -v end="$END_IDX" '
        NR >= start && NR <= end {
            gsub(/^[0-9]+[\.\)\s]+\s*/, "")
            if ($0 != "") print $0
        }
    ' "$PLUGIN_LIST_FILE" > "$WORK_LIST"
    TOTAL=$(wc -l < "$WORK_LIST")
    echo "=== PHASE 3: Range $START_IDX–$END_IDX ($TOTAL plugins, $THREADS threads) ==="
else
    echo "Usage:"
    echo "  run-phase3.sh <plugin-slug>"
    echo "  run-phase3.sh --start 1 --end 10 [--threads 4] [--force]"
    rm "$WORK_LIST"
    exit 1
fi

# Process function
validate_plugin() {
    local SLUG="$1"
    local PHASE2="${ROOT_DIR}/reports/${SLUG}-phase2.json"
    local PHASE3="${ROOT_DIR}/reports/${SLUG}-phase3.json"

    # Skip if no Phase 2 output
    if [ ! -f "$PHASE2" ]; then
        return 0
    fi

    # Skip if already validated
    if [ "$FORCE" = "false" ] && [ -f "$PHASE3" ]; then
        return 0
    fi

    python3 "${TOOLS_DIR}/bin/phase3-validate.py" "$SLUG" \
        --reports-dir "${ROOT_DIR}/reports" \
        --plugins-dir "${ROOT_DIR}/plugins" 2>/dev/null || echo "[!] Phase 3 error: $SLUG"
}

export -f validate_plugin
export FORCE ROOT_DIR TOOLS_DIR

if [ "$THREADS" -gt 1 ]; then
    cat "$WORK_LIST" | xargs -P "$THREADS" -I {} bash -c 'validate_plugin "$@"' _ {}
else
    while IFS= read -r slug; do
        [ -z "$slug" ] && continue
        validate_plugin "$slug"
    done < "$WORK_LIST"
fi

rm "$WORK_LIST"

# Summary
echo ""
echo "=== ACTIONABLE FINDINGS ==="
python3 -c "
import json, glob
total = 0
for f in sorted(glob.glob('${ROOT_DIR}/reports/*-phase3.json')):
    d = json.load(open(f))
    a = len(d.get('actionable_findings', []))
    if a > 0:
        print(f'  {d[\"plugin_slug\"]}: {a} actionable')
        total += a
print(f'  Total: {total}')
" 2>/dev/null
