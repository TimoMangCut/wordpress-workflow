#!/bin/bash
# scan-semgrep.sh — Run Semgrep Pro with WordPress rules
# Writes to temp file first — won't create empty report on failure

set -e

PLUGIN_DIR="$1"
if [ -z "$PLUGIN_DIR" ]; then
    echo "Usage: $0 <plugin-directory>"
    exit 1
fi

SLUG=$(basename "$PLUGIN_DIR")
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
RULES_DIR="${SCRIPT_DIR}/config/semgrep-wp-rules"
source "${SCRIPT_DIR}/bin/report-paths.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
OUTPUT="${PHASE1_DIR}/${SLUG}-semgrep.json"
ERRLOG="${LOGS_DIR}/${SLUG}-semgrep.err"
SEMGREP_VENV="${SEMGREP_VENV:-${ROOT_DIR}/tmmc/bin/activate}"

# Check rules exist
if [ ! -d "$RULES_DIR" ] || [ -z "$(ls "$RULES_DIR"/*.yaml 2>/dev/null)" ]; then
    echo "[-] No rules found in $RULES_DIR"
    exit 1
fi

echo "[*] Semgrep Pro: $SLUG"

# Semgrep must run inside the expected venv for stable rule/runtime behavior.
if [ ! -f "$SEMGREP_VENV" ]; then
    echo "[-] required semgrep venv not found: $SEMGREP_VENV"
    exit 2
fi

# shellcheck disable=SC1090
. "$SEMGREP_VENV"

if ! command -v semgrep >/dev/null 2>&1; then
    echo "[-] semgrep not found in PATH (venv: $SEMGREP_VENV)"
    exit 127
fi

# Write to temp file — don't truncate output on failure
rm -f "$OUTPUT"
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

    # Success: move temp to final output
    mv "$TMPOUT" "$OUTPUT"

    # O-02: Inject ruleset metadata for reproducibility
    RULE_COUNT=$(ls "$RULES_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' ')
    SEMGREP_VERSION=$(semgrep --version 2>/dev/null | head -1 || echo "unknown")
    python3 - "$OUTPUT" "$RULES_DIR" "$RULE_COUNT" "$SEMGREP_VERSION" <<'PYEOF'
import json, sys
out_path, rules_dir, rule_count, semgrep_ver = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.loads(open(out_path).read())
data["_scan_meta"] = {
    "ruleset_path": rules_dir,
    "rule_count": int(rule_count),
    "semgrep_version": semgrep_ver.strip(),
}
open(out_path, "w").write(json.dumps(data, indent=2))
PYEOF

    # Print summary
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

    # Show first few lines of error for debugging
    if [ -s "$ERRLOG" ]; then
        echo "  [!] Error log:"
        head -5 "$ERRLOG" | sed 's/^/      /'
    fi

    rm -f "$TMPOUT"
    # Don't create empty output — let extract.php know there's no semgrep data
fi
