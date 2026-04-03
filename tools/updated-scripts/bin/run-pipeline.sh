#!/bin/bash
# run-pipeline.sh — Phase 2 (LLM) + Phase 3 (Validation) pipeline
# Usage:
#   run-pipeline.sh --start 1 --end 10                     # Range
#   run-pipeline.sh --start 1 --end 10 --threads 2         # Parallel Phase 2 (quota!)
#   run-pipeline.sh --start 1 --end 10 --p3-threads 4      # Parallel Phase 3 only
#   run-pipeline.sh --slug advanced-iframe                  # Single plugin
#
# Quota management:
#   --threads controls Phase 2 parallelism (LLM calls — be conservative!)
#   --p3-threads controls Phase 3 parallelism (deterministic — safe to max out)
#   Use --start/--end to split work across sessions/accounts

set -euo pipefail

SLUG=""
START_IDX=""
END_IDX=""
P2_THREADS=1
P3_THREADS=4
FORCE=false
PLUGIN_LIST_FILE="plugins_sorted_numbered.txt"

while [[ $# -gt 0 ]]; do
    case $1 in
        --start) START_IDX="$2"; shift 2 ;;
        --end) END_IDX="$2"; shift 2 ;;
        --threads) P2_THREADS="$2"; shift 2 ;;
        --p3-threads) P3_THREADS="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        --slug) SLUG="$2"; shift 2 ;;
        --list) PLUGIN_LIST_FILE="$2"; shift 2 ;;
        *) shift ;;
    esac
done

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "${BIN_DIR}/.." && pwd)"          # updated-scripts/

echo "========================================="
echo "  Phase 2 + 3 Pipeline"
if [ -n "$SLUG" ]; then
    echo "  Plugin: $SLUG"
elif [ -n "$START_IDX" ]; then
    echo "  Range: $START_IDX – $END_IDX"
fi
echo "  Phase 2 threads: $P2_THREADS"
echo "  Phase 3 threads: $P3_THREADS"
echo "========================================="

# Build args for sub-scripts
RANGE_ARGS=""
if [ -n "$SLUG" ]; then
    RANGE_ARGS="$SLUG"
elif [ -n "$START_IDX" ] && [ -n "$END_IDX" ]; then
    RANGE_ARGS="--start $START_IDX --end $END_IDX --list $PLUGIN_LIST_FILE"
else
    echo "Usage: run-pipeline.sh --start N --end M [--threads T] [--p3-threads T]"
    echo "       run-pipeline.sh --slug <plugin-slug>"
    exit 1
fi

FORCE_FLAG=""
[ "$FORCE" = "true" ] && FORCE_FLAG="--force"

# Phase 2
echo ""
echo "--- PHASE 2: Deep LLM Reasoning ---"
bash "${SCRIPT_DIR}/bin/run-phase2.sh" $RANGE_ARGS --threads "$P2_THREADS" $FORCE_FLAG

# Phase 3
echo ""
echo "--- PHASE 3: Semantic Validation ---"
bash "${SCRIPT_DIR}/bin/run-phase3.sh" $RANGE_ARGS --threads "$P3_THREADS" $FORCE_FLAG

echo ""
echo "========================================="
echo "  Pipeline Complete"
echo "========================================="
