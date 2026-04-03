#!/bin/bash
# scan-semgrep.sh — Run Semgrep with WordPress rules

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
RULES_DIR="${TOOLS_DIR}/config/semgrep-wp-rules"
REPORTS="${ROOT_DIR}/reports"
OUTPUT="${REPORTS}/${SLUG}-semgrep.json"
ERRLOG="${REPORTS}/logs/${SLUG}-semgrep.err"

mkdir -p "$REPORTS/logs"

# Check rules
if [ ! -d "$RULES_DIR" ] || [ -z "$(ls "$RULES_DIR"/*.yaml 2>/dev/null)" ]; then
    echo "[-] No rules in $RULES_DIR"
    exit 1
fi

# Activate venv for semgrep
VENV_PATH="${ROOT_DIR}/tmmc/bin/activate"
if [ -f "$VENV_PATH" ]; then
    source "$VENV_PATH"
elif [ -f "${HOME}/.venv/bin/activate" ]; then
    source "${HOME}/.venv/bin/activate"
fi

# Verify semgrep available
if ! command -v semgrep &>/dev/null; then
    echo "[-] semgrep not found. Activate venv: source $VENV_PATH"
    exit 1
fi

echo "[*] Semgrep: $SLUG"

TMPOUT=$(mktemp)

if semgrep --pro \
    --config "$RULES_DIR" \
    --json \
    --no-git-ignore \
    --timeout 60 \
    --max-target-bytes 2000000 \
    --exclude "vendor" \
    --exclude "node_modules" \
    --exclude ".git" \
    "$PLUGIN_DIR" > "$TMPOUT" 2>"$ERRLOG"; then

    mv "$TMPOUT" "$OUTPUT"
    python3 -c "
import json
with open('$OUTPUT') as f:
    data = json.load(f)
results = data.get('results', [])
print(f'[+] {len(results)} findings')
from collections import Counter
for rule, count in Counter(r['check_id'].split('.')[-1] for r in results).most_common(5):
    print(f'    {rule}: {count}')
" 2>/dev/null || echo "[+] Saved: $OUTPUT"
else
    EXIT_CODE=$?
    echo "  [!] Semgrep failed (exit $EXIT_CODE)"
    if [ -s "$ERRLOG" ]; then
        head -5 "$ERRLOG" | sed 's/^/      /'
    fi
    rm -f "$TMPOUT"
fi
