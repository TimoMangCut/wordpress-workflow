#!/bin/bash
# scan-progpilot.sh — Run Progpilot taint analysis with WordPress config

set -e

PLUGIN_DIR="$1"
if [ -z "$PLUGIN_DIR" ]; then
    echo "Usage: $0 <plugin-directory>"
    exit 1
fi

SLUG=$(basename "$PLUGIN_DIR")
BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$(cd "${BIN_DIR}/.." && pwd)"          # updated-scripts/
TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"         # tools/
ROOT_DIR="$(cd "${TOOLS_DIR}/.." && pwd)"           # project root
CONFIG="${SCRIPT_DIR}/config/progpilot-wp.json"
REPORTS="${ROOT_DIR}/reports"
OUTPUT="${REPORTS}/${SLUG}-progpilot.json"
ERRLOG="${REPORTS}/logs/${SLUG}-progpilot.err"

mkdir -p "$REPORTS" "$REPORTS/logs"

# Find progpilot
PROGPILOT=""
if [ -f "${TOOLS_DIR}/vendor/bin/progpilot" ]; then
    PROGPILOT="${TOOLS_DIR}/vendor/bin/progpilot"
elif command -v progpilot &>/dev/null; then
    PROGPILOT="progpilot"
elif [ -f "${TOOLS_DIR}/bin/progpilot.phar" ]; then
    PROGPILOT="php ${TOOLS_DIR}/bin/progpilot.phar"
else
    echo "[-] Progpilot not found, skipping"
    echo "[]" > "$OUTPUT"
    exit 0
fi

echo "[*] Progpilot: $SLUG"

# Run with WP config, capture errors
TMPOUT=$(mktemp)
if [ -f "$CONFIG" ]; then
    if $PROGPILOT --configuration "$CONFIG" "$PLUGIN_DIR" > "$TMPOUT" 2>"$ERRLOG"; then
        # Verify valid JSON
        if python3 -c "import json; json.load(open('$TMPOUT'))" 2>/dev/null; then
            mv "$TMPOUT" "$OUTPUT"
        else
            echo "  [!] Invalid JSON output"
            echo "[]" > "$OUTPUT"
            rm -f "$TMPOUT"
        fi
    else
        echo "  [!] Progpilot error (exit $?)"
        [ -s "$ERRLOG" ] && head -3 "$ERRLOG" | sed 's/^/      /'
        echo "[]" > "$OUTPUT"
        rm -f "$TMPOUT"
    fi
else
    echo "  [!] Config not found: $CONFIG"
    if $PROGPILOT "$PLUGIN_DIR" > "$TMPOUT" 2>"$ERRLOG"; then
        mv "$TMPOUT" "$OUTPUT"
    else
        echo "[]" > "$OUTPUT"
        rm -f "$TMPOUT"
    fi
fi

COUNT=$(python3 -c "import json; d=json.load(open('$OUTPUT')); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo "?")
echo "[+] $COUNT findings"
