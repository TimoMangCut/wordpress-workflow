#!/bin/bash
# scan-all.sh - Full Phase 1 pipeline for a single plugin
# Pipeline: surface-map -> semgrep -> psalm (optional) -> IR extract + rules -> SQLite -> threat context
# Usage: scan-all.sh <plugin-directory>

set -euo pipefail

PLUGIN_DIR="${1:-}"
if [ -z "${PLUGIN_DIR:-}" ]; then
    echo "Usage: $0 <plugin-directory>"
    exit 1
fi

if [ ! -d "$PLUGIN_DIR" ]; then
    echo "[ERROR] Plugin directory not found"
    echo "  - path: $PLUGIN_DIR"
    exit 1
fi

PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"

SLUG=$(basename "$PLUGIN_DIR")
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DB="${ROOT_DIR}/data/audit.db"
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-1024M}"

source "${SCRIPT_DIR}/bin/report-paths.sh"
source "${SCRIPT_DIR}/bin/console-ui.sh"
resolve_report_dirs "${ROOT_DIR}/reports"
ensure_report_dirs
ARTIFACT_FRESHNESS_BIN="${SCRIPT_DIR}/bin/artifact_freshness.py"
THREAT_CONTEXT_PATH="$(threat_context_path_for_slug "$SLUG")"
THREAT_PROFILES_PATH="${SCRIPT_DIR}/data/threat-profiles.json"
PHASE1_ERR_LOG="$(logs_phase1_run_err_path "$SLUG")"
PHASE1_LIVE_LOG="$(logs_phase1_run_live_path "$SLUG")"

reset_log_file "$PHASE1_ERR_LOG"
reset_log_file "$PHASE1_LIVE_LOG"
append_log_marker "$PHASE1_ERR_LOG" "phase1 start slug=${SLUG} plugin_dir=${PLUGIN_DIR}"
append_log_marker "$PHASE1_LIVE_LOG" "phase1 start slug=${SLUG} plugin_dir=${PLUGIN_DIR}"

log_section "PHASE 1: $SLUG"

resolve_php_bin() {
    local candidate

    if [ -n "${PHP_BIN:-}" ]; then
        if [ -x "${PHP_BIN}" ]; then
            echo "${PHP_BIN}"
            return 0
        fi
        if command -v "${PHP_BIN}" >/dev/null 2>&1; then
            command -v "${PHP_BIN}"
            return 0
        fi
    fi

    for candidate in \
        php \
        php8.4 php84 \
        php8.3 php83 \
        php8.2 php82 \
        php8.1 php81 \
        /opt/homebrew/bin/php \
        /usr/local/bin/php \
        /usr/bin/php
    do
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done

    return 1
}

freshness_is_fresh() {
    local output="$1"
    shift

    local cmd=(python3 "$ARTIFACT_FRESHNESS_BIN" is-fresh --output "$output")
    local path
    for path in "$@"; do
        [ -n "$path" ] || continue
        [ -e "$path" ] || continue
        cmd+=(--input "$path")
    done

    "${cmd[@]}" >/dev/null 2>&1
}

# --- Step 1: Surface Map (fast grep, always run) ---
if [ -f "${SCRIPT_DIR}/bin/surface-map.sh" ]; then
    log_stage "[1/5] Surface Map"
    append_log_marker "$PHASE1_ERR_LOG" "step=surface-map start"
    append_log_marker "$PHASE1_LIVE_LOG" "step=surface-map start"
    if ! run_command_with_live_logs "$PHASE1_LIVE_LOG" "$PHASE1_ERR_LOG" bash "${SCRIPT_DIR}/bin/surface-map.sh" "$PLUGIN_DIR"; then
        append_log_marker "$PHASE1_ERR_LOG" "step=surface-map failed"
        append_log_marker "$PHASE1_LIVE_LOG" "step=surface-map failed"
        log_warn_block "surface-map failed" "slug" "$SLUG" "errlog" "$PHASE1_ERR_LOG" "live_log" "$PHASE1_LIVE_LOG"
    else
        append_log_marker "$PHASE1_ERR_LOG" "step=surface-map done"
        append_log_marker "$PHASE1_LIVE_LOG" "step=surface-map done"
    fi
else
    log_stage "[1/5] Surface Map --- SKIPPED"
fi

# --- Step 2: Semgrep (primary taint scanner) ---
if [ -f "${SCRIPT_DIR}/bin/scan-semgrep.sh" ]; then
    log_stage "[2/5] Semgrep"
    append_log_marker "$PHASE1_ERR_LOG" "step=semgrep start"
    append_log_marker "$PHASE1_LIVE_LOG" "step=semgrep start"
    if ! run_command_with_live_logs "$PHASE1_LIVE_LOG" "$PHASE1_ERR_LOG" bash "${SCRIPT_DIR}/bin/scan-semgrep.sh" "$PLUGIN_DIR"; then
        append_log_marker "$PHASE1_ERR_LOG" "step=semgrep failed"
        append_log_marker "$PHASE1_LIVE_LOG" "step=semgrep failed"
        log_warn_block "semgrep failed" "slug" "$SLUG" "errlog" "$PHASE1_ERR_LOG" "live_log" "$PHASE1_LIVE_LOG"
    else
        append_log_marker "$PHASE1_ERR_LOG" "step=semgrep done"
        append_log_marker "$PHASE1_LIVE_LOG" "step=semgrep done"
    fi
else
    log_stage "[2/5] Semgrep --- MISSING"
fi

# --- Step 3: Psalm taint analysis (cross-file taint -> SARIF, non-blocking) ---
log_stage "[3/5] Psalm Taint"
if [ -f "${SCRIPT_DIR}/bin/scan-psalm.sh" ]; then
    append_log_marker "$PHASE1_ERR_LOG" "step=psalm start"
    append_log_marker "$PHASE1_LIVE_LOG" "step=psalm start"
    if ! run_command_with_live_logs "$PHASE1_LIVE_LOG" "$PHASE1_ERR_LOG" bash "${SCRIPT_DIR}/bin/scan-psalm.sh" "$PLUGIN_DIR"; then
        append_log_marker "$PHASE1_ERR_LOG" "step=psalm failed"
        append_log_marker "$PHASE1_LIVE_LOG" "step=psalm failed"
        log_warn_block "psalm failed (non-blocking)" "slug" "$SLUG" "errlog" "$PHASE1_ERR_LOG" "live_log" "$PHASE1_LIVE_LOG"
    else
        append_log_marker "$PHASE1_ERR_LOG" "step=psalm done"
        append_log_marker "$PHASE1_LIVE_LOG" "step=psalm done"
    fi
else
    log_warn "SKIPPED: scan-psalm.sh not found or psalm not installed"
fi

# --- Step 4: IR Extraction + Deterministic Rules + SQLite Store ---
log_stage "[4/5] IR Extract + Rules"
if [ -f "${SCRIPT_DIR}/vendor/autoload.php" ] && [ -f "${SCRIPT_DIR}/bin/extract.php" ]; then
    PHP_RUNTIME="$(resolve_php_bin || true)"
    if [ -n "$PHP_RUNTIME" ]; then
        append_log_marker "$PHASE1_ERR_LOG" "step=extract start"
        append_log_marker "$PHASE1_LIVE_LOG" "step=extract start"
        if ! run_command_with_live_logs "$PHASE1_LIVE_LOG" "$PHASE1_ERR_LOG" "$PHP_RUNTIME" -d "memory_limit=${PHP_MEMORY_LIMIT}" "${SCRIPT_DIR}/bin/extract.php" "$PLUGIN_DIR" --db="$DB"; then
            append_log_marker "$PHASE1_ERR_LOG" "step=extract failed"
            append_log_marker "$PHASE1_LIVE_LOG" "step=extract failed"
            log_warn_block "extract failed" "slug" "$SLUG" "errlog" "$PHASE1_ERR_LOG" "live_log" "$PHASE1_LIVE_LOG"
        else
            append_log_marker "$PHASE1_ERR_LOG" "step=extract done"
            append_log_marker "$PHASE1_LIVE_LOG" "step=extract done"
        fi
    else
        log_warn "SKIPPED: php runtime not found (set PHP_BIN or add php/php8.x to PATH)"
    fi
else
    log_warn "SKIPPED: php-parser not installed (run: cd tools && composer install)"
fi

# --- Step 5: Threat Context (deterministic keyword matching) ---
if [ -f "${SCRIPT_DIR}/bin/generate_threat_context.py" ]; then
    log_stage "[5/5] Threat Context"
    if freshness_is_fresh "$THREAT_CONTEXT_PATH" "$PLUGIN_DIR" "$THREAT_PROFILES_PATH" "${SCRIPT_DIR}/bin/generate_threat_context.py"; then
        log_info "Skip ${SLUG}: threat context is fresh"
        append_log_marker "$PHASE1_ERR_LOG" "step=threat-context skipped freshness=true"
        append_log_marker "$PHASE1_LIVE_LOG" "step=threat-context skipped freshness=true"
    else
        append_log_marker "$PHASE1_ERR_LOG" "step=threat-context start"
        append_log_marker "$PHASE1_LIVE_LOG" "step=threat-context start"
        if ! run_command_with_live_logs "$PHASE1_LIVE_LOG" "$PHASE1_ERR_LOG" python3 "${SCRIPT_DIR}/bin/generate_threat_context.py" "$SLUG" \
            --plugins-dir "${ROOT_DIR}/plugins" \
            --reports-dir "${REPORTS_DIR}" \
            --profiles "${THREAT_PROFILES_PATH}"; then
            append_log_marker "$PHASE1_ERR_LOG" "step=threat-context failed"
            append_log_marker "$PHASE1_LIVE_LOG" "step=threat-context failed"
            log_warn_block "threat context generation failed" "slug" "$SLUG" "errlog" "$PHASE1_ERR_LOG" "live_log" "$PHASE1_LIVE_LOG"
        else
            append_log_marker "$PHASE1_ERR_LOG" "step=threat-context done"
            append_log_marker "$PHASE1_LIVE_LOG" "step=threat-context done"
        fi
    fi
else
    log_stage "[5/5] Threat Context --- MISSING"
fi

append_log_marker "$PHASE1_ERR_LOG" "phase1 end slug=${SLUG}"
append_log_marker "$PHASE1_LIVE_LOG" "phase1 end slug=${SLUG}"
log_section "DONE: $SLUG"
