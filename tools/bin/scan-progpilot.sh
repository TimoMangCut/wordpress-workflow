#!/bin/bash
# scan-progpilot.sh — Run Progpilot taint analysis

set -e

PLUGIN_DIR="$1"
if [ -z "$PLUGIN_DIR" ]; then
    echo "Usage: $0 <plugin-directory>"
    exit 1
fi

SLUG=$(basename "$PLUGIN_DIR")
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG="${SCRIPT_DIR}/config/progpilot-wp.json"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
OUTPUT="${PHASE1_DIR}/${SLUG}-progpilot.json"

# Find progpilot
PROGPILOT=""
if [ -f "${SCRIPT_DIR}/vendor/bin/progpilot" ]; then
    PROGPILOT="${SCRIPT_DIR}/vendor/bin/progpilot"
elif [ -f "${SCRIPT_DIR}/bin/progpilot.phar" ]; then
    PROGPILOT="php ${SCRIPT_DIR}/bin/progpilot.phar"
else
    echo "[-] Progpilot not found, skipping"
    echo "[]" > "$OUTPUT"
    exit 0
fi

echo "[*] Progpilot: $SLUG"

if [ -f "$CONFIG" ]; then
    $PROGPILOT --configuration "$CONFIG" "$PLUGIN_DIR" > "$OUTPUT" 2>/dev/null || echo "[]" > "$OUTPUT"
else
    $PROGPILOT "$PLUGIN_DIR" > "$OUTPUT" 2>/dev/null || echo "[]" > "$OUTPUT"
fi

if [ -f "$OUTPUT" ]; then
    COUNT=$(python3 -c "import json; d=json.load(open('$OUTPUT')); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "?")
    echo "[+] $COUNT findings"
fi
