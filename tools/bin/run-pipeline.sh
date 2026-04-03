#!/bin/bash
# run-pipeline.sh - Phase 2 (analysis) + Phase 3 (gate-first validation + markdown).
# Usage: run-pipeline.sh [--slug specific-plugin]

set -euo pipefail

SPECIFIC_SLUG=""
TOOLS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"
source "${TOOLS_DIR}/bin/report-paths.sh"
source "${TOOLS_DIR}/bin/console-ui.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs

while [[ $# -gt 0 ]]; do
    case "$1" in
        --slug)
            SPECIFIC_SLUG="${2:-}"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

log_section "Phase 2 + 3 Pipeline"

# Find plugins with Phase 1 output
if [ -n "$SPECIFIC_SLUG" ]; then
    IR_FILES="${PHASE1_DIR}/${SPECIFIC_SLUG}-ir.json"
else
    IR_FILES=$(ls "${PHASE1_DIR}"/*-ir.json 2>/dev/null || true)
fi

if [ -z "$IR_FILES" ]; then
    log_error "No Phase 1 IR files found"
    exit 1
fi

for ir_file in $IR_FILES; do
    SLUG=$(basename "$ir_file" -ir.json)

    # Skip if already analyzed (unless specific slug requested)
    if compgen -G "${PHASE3_DIR}/*-${SLUG}.md" > /dev/null && [ -z "$SPECIFIC_SLUG" ]; then
        continue
    fi

    # Phase 2
    echo ""
    bash "${TOOLS_DIR}/bin/run-phase2.sh" --slug "$SLUG" || log_warn_block "Phase 2 error" "slug" "$SLUG"

    # Phase 3
    if [ -f "${PHASE2_DIR}/${SLUG}-phase2.json" ]; then
        log_stage "Phase 3: Gate Validation (+ optional LLM skeptic)"
        bash "${TOOLS_DIR}/bin/run-phase3.sh" --slug "$SLUG" || log_warn_block "Phase 3 error" "slug" "$SLUG"
    fi
done

echo ""
log_section "Pipeline Complete"

# Summary
for f in "${PHASE3_DIR}"/*.md; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f")"
done
