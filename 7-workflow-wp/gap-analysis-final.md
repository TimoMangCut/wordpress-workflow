# WordPress Audit Pipeline — Gap Analysis

> **Mục đích:** Tổng hợp toàn bộ defects trong pipeline `offensive-agentic-timomangcut`.
> Mỗi gap có code evidence từ codebase thực tế. Document self-contained — reader không cần ngữ cảnh bên ngoài.
>
> **File priority:** SOUL.md → AGENTS.md → document này.
> **Tất cả gap fixes là code changes (PHP/Python/Bash). Không gap nào require LLM để fix.**

---

## 1. Hệ Thống Đang Được Review

### 1.1. Pipeline là gì

Đây là một automated security audit pipeline cho WordPress plugins. Pipeline quét source code của plugins, tìm vulnerabilities (SQL injection, XSS, CSRF, privilege escalation, arbitrary file upload/read/delete, SSRF, RCE, etc.), và produce structured reports.

Mục tiêu: tìm real, exploitable vulnerabilities với zero false positives. Phục vụ bug bounty research trên Patchstack platform.

Pipeline có hai chế độ vận hành:
- **Automation hoàn toàn:** Deploy local, chạy end-to-end không cần intervention.
- **Manual step-by-step:** Chạy từng phase bằng bash script riêng, kiểm soát quota LLM giữa các phase.

### 1.2. Ba Phase chính

**Phase 1 — Deterministic Collection (không dùng LLM)**

Quét plugin bằng tools tĩnh và custom IR parser:
- **Surface Map:** Liệt kê files, functions, classes — `tools/bin/surface-map.sh`
- **Semgrep SAST:** 15 custom rules quét known vulnerability patterns — `tools/bin/scan-semgrep.sh`
- **Psalm Taint Analysis:** Static taint analysis cho PHP — `tools/bin/scan-psalm.sh` (có fallback mechanism khi crash)
- **IR (Intermediate Representation) Parser:** Custom PHP-Parser AST-based extractor — `tools/bin/extract.php`
  - Dùng PHP-Parser để parse source code thành AST
  - Extract: entry points (WordPress hooks, REST routes, shortcodes, blocks, cron), sources (user input), sinks (dangerous operations), guards (nonce/capability checks)
  - Run AnomalyRules: 10 deterministic rules phát hiện structural security defects

Output files per plugin:
```
reports/<slug>-surface.txt      # File/function listing
reports/<slug>-semgrep.json     # Semgrep hits
reports/<slug>-psalm.sarif      # Psalm taint results (SARIF format, hoặc status JSON khi timeout/error)
reports/<slug>-ir.json          # IR: {metadata, entry_points, sources, sinks, guards, anomalies}
```

**Phase 2 — LLM Analysis (Codex)**

LLM (hiện dùng OpenAI Codex qua ChatGPT Teams) nhận TOÀN BỘ Phase 1 output + source code plugin. Một session duy nhất thực hiện:
- Đọc IR JSON (entry points, sources, sinks, guards, anomalies)
- Đọc Semgrep output (corroboration)
- Đọc Psalm SARIF (corroboration)
- Đọc source code trực tiếp
- Trace source → sink data flows cho mỗi entry point
- Check guards effectiveness (nonce, capability)
- Refute-first: cố gắng disprove mỗi potential finding
- Output structured JSON findings

Mỗi finding có verdict: TP (true positive), FP (false positive), REVIEW (uncertain — cần manual review).

Có chế độ quick triage cho low-signal plugins (ít entry points, không anomaly) → nếu quick triage tìm thấy issues → escalate sang deep analysis.

Sau LLM output: `phase2_postprocess.py` normalize fields, validate, downgrade TP→REVIEW khi evidence yếu.

Output files:
```
reports/<slug>-phase2.raw.json  # LLM raw output
reports/<slug>-phase2.json      # Sau postprocess
```

**Phase 3 — Deterministic Gate + Optional LLM Skeptic**

`phase3_gate.py` (1087 lines, deterministic, authoritative) cross-validate mỗi finding against IR ground truth:
- File exists check: file referenced trong finding có tồn tại trong plugin?
- Path reachable check: entry point → source → sink path có evidence trong IR?
- Auth consistency: finding claim auth level có match IR entry point auth level?
- Guard consistency: finding claim "no nonce" nhưng IR thấy nonce guard → contradiction?
- Code evidence: sink function có ở claimed line number?
- Reasoning quality: reasoning có file:line references? Có refutation attempt?

Gate output status per finding: CONFIRMED (high confidence) / PLAUSIBLE (good evidence) / UNCERTAIN (weak evidence) / REJECTED (contradicted by IR).

Optional LLM skeptic (`phase3_llm_review.py`): review PLAUSIBLE/UNCERTAIN findings, suggest corrections. Controlled bằng `--llm-mode` flag (auto/off/force).

Output:
```
reports/<slug>-phase3.json              # Gate results
reports/phase3/<index>-<slug>.md        # Markdown report (deterministic)
reports/phase3/<index>-<slug>.llm.md    # LLM review (nếu có)
```

### 1.3. Cây thư mục (files relevant cho gap analysis)

```
offensive-agentic-timomangcut/
├── AGENTS.md                              # Project-level reasoning rules (WordPress audit)
├── WORKFLOW-GUIDE.md                      # Hướng dẫn vận hành pipeline
├── WORDPRESS-PLUGIN-RESEARCH.md           # Prompt framework cho LLM SAST
├── plugins/                               # Target WordPress plugin source code
├── reports/                               # All pipeline outputs
│   ├── logs/                              # Error logs per phase
│   ├── phase3/                            # Markdown reports
│   └── quota-ledger.jsonl                 # Token usage tracking
├── data/
│   └── audit.db                           # SQLite state store
└── tools/
    ├── src/
    │   ├── Extractor/
    │   │   ├── IRBuilder.php              # Orchestrate IR extraction (382 lines)
    │   │   │   Phase 1: build SymbolTable
    │   │   │   Phase 2: find entry points across files
    │   │   │   Phase 3: for each EP, extract callback body → run Guard + SourceSink visitors
    │   │   │   Phase 4: file-level scan for files without entry points
    │   │   │   Phase 5: extract metadata
    │   │   ├── SymbolTable.php            # Index of all function/class/method declarations
    │   │   │   findMethod(class, method), findFunction(name), findMethodInAllClasses(method)
    │   │   └── Visitors/
    │   │       ├── EntryPointVisitor.php   # Detect WordPress hooks, REST routes, shortcodes, blocks, cron (451 lines)
    │   │       │   HOOK_TYPE_MAP: wp_ajax_nopriv_ → ajax_nopriv, wp_ajax_ → ajax_priv, etc.
    │   │       │   EXACT_HOOKS: admin_init, init, wp_loaded, rest_api_init, template_redirect
    │   │       │   AUTH_LEVELS: per entry point type
    │   │       ├── GuardVisitor.php        # Detect nonce checks, capability checks, is_admin() (155 lines)
    │   │       │   Detects: wp_verify_nonce, check_ajax_referer, check_admin_referer, current_user_can, is_admin
    │   │       │   Tracks: guard-after-side-effect pattern, check_ajax_referer $die=false
    │   │       └── SourceSinkVisitor.php   # Map user input sources + dangerous sinks (298 lines)
    │   │           Sources: superglobals ($_GET, $_POST, etc.), REST API methods, shortcode/block attrs
    │   │           Sinks: SQL ($wpdb methods), file ops, output, eval, include, redirect, deserialization, remote requests
    │   │           Storage writes: update_option → option_update, update_post_meta → meta_update
    │   │           Sanitizers: 40+ known functions (esc_html, sanitize_text_field, absint, etc.)
    │   │           Tracks: $wpdb->prepare() usage (proximity-based detection)
    │   └── Rules/
    │       └── AnomalyRules.php           # 10 deterministic security rules (380 lines)
    │           Rule01: missing nonce in state-changing handlers
    │           Rule02: missing capability in admin operations
    │           Rule03: flawed nonce pattern (check_ajax_referer $die=false, guard after side-effect)
    │           Rule04: SQL without prepare() (with user input + entry point scoping)
    │           Rule05: unescaped output in shortcode/block
    │           Rule06: is_admin() used as authorization
    │           Rule07: REST route with __return_true permission
    │           Rule08: nopriv handler with sensitive operations
    │           Rule09: wp_redirect() with user input (vs wp_safe_redirect)
    │           Rule10: cross-handler guard inconsistency (outlier detection)
    ├── bin/
    │   ├── extract.php                    # CLI entry point for IR extraction
    │   ├── scan-semgrep.sh               # Semgrep scanner
    │   ├── scan-psalm.sh                 # Psalm scanner (with fallback mechanism)
    │   ├── scan-all.sh                   # Run all Phase 1 tools for one plugin
    │   ├── batch.sh                      # Batch Phase 1 across all plugins
    │   ├── run-phase2.sh                 # Phase 2 runner (587 lines)
    │   │   Features: interactive mode, index range, quick triage → deep escalation
    │   │   Quota control: --interactive, --start-index, --end-index, --threads
    │   ├── phase2_postprocess.py         # Normalize Phase 2 output, downgrade weak TPs
    │   ├── run-phase3.sh                 # Phase 3 runner
    │   │   LLM modes: --llm-mode auto|off|force
    │   │   Optional: --apply-review (apply LLM field corrections)
    │   ├── phase3_gate.py                # Deterministic validation gate (1087 lines)
    │   ├── phase3_llm_review.py          # LLM skeptic reviewer
    │   ├── phase3_apply_review.py        # Apply LLM corrections to Phase 2 output
    │   ├── phase3_write_md.py            # Generate markdown reports
    │   └── quota-report.py               # Token usage statistics
    ├── config/
    │   ├── semgrep-wp-rules/             # 15 custom Semgrep rules (01-sqli through 15-rest-api)
    │   ├── old_semgrep/                  # Deprecated ruleset (14 rules, missing REST API rule)
    │   ├── phase2-prompt-template.md     # Phase 2 LLM prompt template
    │   ├── system-prompt-phase2.md       # Phase 2 system prompt
    │   ├── phase3-prompt-template.md     # Phase 3 LLM prompt
    │   ├── system-prompt-phase3.md       # Phase 3 system prompt
    │   ├── progpilot-wp-*.json           # Progpilot config (alternative scanner)
    │   └── psalm-wp*.xml                 # Psalm configs (primary + fallback variants)
    └── forks/
        └── psalm-plugin-wordpress/       # Forked WordPress Psalm plugin (custom patches)
```

### 1.4. Data Flow Chi Tiết

```
Plugin Source Code (plugins/<slug>/)
      │
      ├──→ surface-map.sh → reports/<slug>-surface.txt
      ├──→ scan-semgrep.sh → reports/<slug>-semgrep.json
      ├──→ scan-psalm.sh → reports/<slug>-psalm.sarif
      └──→ extract.php (IRBuilder)
           │
           ├── Phase 1: SymbolTable.build() — index all functions, classes, methods
           ├── Phase 2: EntryPointVisitor — detect hooks, REST routes, shortcodes, blocks, cron
           ├── Phase 3: Per entry point callback body:
           │   ├── GuardVisitor — detect nonce/capability checks
           │   └── SourceSinkVisitor — detect sources + sinks
           ├── Phase 4: File-level scan — sources/sinks in files without entry points
           ├── Phase 5: Metadata extraction — plugin name, version, LOC
           └── AnomalyRules.run() — 10 deterministic rules
                │
                ▼
           reports/<slug>-ir.json
           {
             "metadata": { plugin_slug, version, files_analyzed, total_loc },
             "entry_points": [ { id, type, hook_name, callback, auth_level, file, line } ],
             "sources": [ { id, entry_point_id, type, variable, key, file, line } ],
             "sinks": [ { id, entry_point_id, category, function_called, uses_prepared_statement, file, line } ],
             "guards": [ { entry_point_id, type, function_called, is_effective, notes, file, line } ],
             "anomalies": [ { id, rule_id, type, severity, cwe_id, entry_point_id, description, evidence } ]
           }
                │
                ▼
      Phase 2: run-phase2.sh
           │
           ├── Check signal level: anomalies? unauth EPs? sensitive sinks? SQL sinks?
           ├── Low signal + no force-deep → quick triage mode (lightweight LLM pass)
           │   └── Quick finds TP/REVIEW? → escalate to deep analysis
           ├── Deep analysis: full LLM session with IR + Semgrep + source code
           └── phase2_postprocess.py: normalize types, downgrade weak TPs
                │
                ▼
           reports/<slug>-phase2.json
           {
             "plugin_slug", "analysis_summary", "overall_risk",
             "findings": [ {
               finding_id, verdict (TP|FP|REVIEW), vuln_type, cwe_id, severity,
               auth_required, confidence, entry_point_id,
               source_function, source_file_path, source_line_number,
               sink_function, sink_file_path, sink_line_number,
               reasoning, poc_description, cvss_vector, remediation,
               patchstack_eligible, storage_key (for stored flows)
             } ],
             "negative_findings": [...],
             "out_of_scope": [...]
           }
                │
                ▼
      Phase 3: phase3_gate.py (deterministic, authoritative)
           │
           ├── Per finding: resolve entry_point_id (exact match or fuzzy)
           ├── Run checks: file_exists, path_reachable, auth_consistent,
           │   guard_consistent, sanitizer_claim, code_evidence,
           │   semgrep_corroboration, psalm_corroboration, reasoning_quality,
           │   patchstack_eligible
           ├── Compute weighted confidence score (0.0-1.0)
           ├── Assign status: CONFIRMED / PLAUSIBLE / UNCERTAIN / REJECTED
           ├── For stored/second-order flows: _check_stored_2hop() validates write→read path
           └── Optional: phase3_llm_review.py for PLAUSIBLE/UNCERTAIN findings
                │
                ▼
           reports/<slug>-phase3.json + reports/phase3/<index>-<slug>.md
```

### 1.5. Giá trị cốt lõi (từ SOUL.md)

Toàn bộ pipeline design driven by these values:

- **"I want the work to speak, so I do not have to."** — Output phải tự defend, không cần tác giả giải thích.
- **Zero false positives:** "I would rather miss a real vulnerability than report a ghost." — FP erodes trust, trains people to ignore findings.
- **Refute-first:** Thử disprove finding trước khi accept. Mỗi finding phải survive refutation.
- **Every rejection needs a reopening condition:** Khi reject, phải nói rõ evidence nào sẽ reverse verdict. Close with door unlocked.
- **Evidence hierarchy 5 tiers:**
  - Tier 1: Traced code path / reproducible PoC (strongest)
  - Tier 2: Framework documented behavior
  - Tier 3: Developer docs, code comments
  - Tier 4: Pattern similarity (suggestive only)
  - Tier 5: Model prior, grep match without context (weakest — never sufficient alone)
- **Finding states:** SIGNAL → HYPOTHESIS → UNCERTAIN → CONFIRMED / REJECTED / RISK_NOTE
- **Impact grounded in context:** IDOR in loan application ≠ IDOR in notification preferences.

---

## 2. Tổng Quan Gaps

**Tổng: 31 gaps** — Critical: 3, High: 10, Medium: 11, Low: 7.

| ID | Severity | Layer | Type | Fix Effort | Fix Language |
|----|----------|-------|------|-----------|-------------|
| IR-02 | Critical | IR | false_negative | High | PHP |
| IR-07 | Critical | IR↔Gate | false_negative | Low | PHP |
| P2-01/G-04 | Critical | P2+Gate | false_negative | Medium | Prompt+Python |
| IR-01 | High | IR | false_negative | Low | PHP |
| IR-03 | High | IR | FP_passthrough | Medium | PHP |
| IR-04 | High | IR | FP_passthrough | Low | PHP |
| AR-01 | High | AnomalyRules | FP_passthrough | Low (fix IR-04) | PHP |
| P2-02 | High | P2 | false_negative | Low | Python |
| P2-04 | High | P2 Runner | false_negative | Low | Bash |
| A-01 | High | Architecture | false_negative | High | PHP |
| G-01 | High | Gate | FP_passthrough | Low (after IR-03/04) | Python |
| A-03 | High | Architecture | quality (preventive) | Medium | Python |
| IR-05 | Medium | IR | FN/FP | Medium | PHP |
| IR-06 | Medium | IR | false_negative | Low | PHP |
| IR-08 | Medium | IR | false_positive | Low | PHP |
| IR-10 | Medium | IR | false_negative | Medium | PHP |
| AR-02 | Medium | AnomalyRules | false_positive | Low | PHP |
| P2-03 | Medium | P2 Post | quality | Low | Python |
| P2-05 | Medium | P2 Post | quality | Low | Python |
| G-02 | Medium | Gate | quality | Medium | Python |
| G-03 | Medium | Gate | quality | Low (fix IR-07) | Python |
| G-05 | High | Gate | quality | Medium (multi-agent deploy) | Python |
| L-01 | Medium | P3 LLM | quality | Low | Bash |
| A-02 | Medium | Architecture | quality | Low | Python/Bash |
| IR-09 | Low | IR | noise | Low | PHP |
| L-02 | Low | P3 LLM | quality | Low | Python |
| O-01 | Low | Output | quality | Low | Python |
| O-02 | Low | Output | reproducibility | Low | Bash |
| O-03 | Low | Output | traceability | Low | Python |
| O-04 | Low | Architecture | reproducibility | Low | Decision |
| O-05 | Low | Architecture | traceability | Low | Cleanup |

---

## 3. Chi Tiết Từng Gap

### IR-01: Dynamic Hook Names Dropped Silently
```
ID       : IR-01
Layer    : IR — tools/src/Extractor/Visitors/EntryPointVisitor.php
Severity : High
Type     : false_negative
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence — EntryPointVisitor.php dòng 90-96:**
```php
private function handleHook(Node\Expr\FuncCall $node, string $funcType): void
{
    if (count($node->args) < 2) return;
    $hookName = $this->resolveStringArg($node->args[0]);
    if ($hookName === null) return;  // ← SILENT DROP — no log, no flag, no warning
    $entryType = null;
    $auth = null;
```

`resolveStringArg()` (dòng cuối file) chỉ return non-null khi argument là `Node\Scalar\String_` (literal string). Khi hook name là dynamic expression, function trả null → `handleHook()` return silently → entry point KHÔNG được recorded trong IR.

**Patterns bị miss (phổ biến trong premium plugins):**
```php
add_action('wp_ajax_' . $this->action_name, [$this, 'handle']);       // concatenation
add_action('wp_ajax_nopriv_' . $prefix . '_handler', 'callback');     // prefix + suffix
add_action(self::HOOK_ACTION, [$this, 'process']);                     // class constant
add_action($this->get_hook_name(), [$this, 'handler']);                // method return
```

**Impact downstream:** Phase 2 nhận IR với zero entry points cho những AJAX handlers này. Phase 2 LLM không biết chúng tồn tại → vulnerability trong dynamic hook handler sẽ KHÔNG BAO GIỜ được found.

**Fix (PHP — EntryPointVisitor.php):**
Khi `resolveStringArg()` trả null, thay vì return silently, log thông tin vào `unresolved_hooks` array:
```php
if ($hookName === null) {
    $this->unresolvedHooks[] = [
        'file' => $this->currentFile,
        'line' => $node->getStartLine(),
        'function' => $funcType, // add_action hoặc add_filter
        'hook_arg_type' => $this->classifyExpression($node->args[0]->value),
        // classifyExpression: 'concatenation', 'constant', 'method_call', 'variable', 'other'
    ];
    return;
}
```
IRBuilder output `unresolved_hooks` vào IR JSON. Phase 2 prompt cần update để đọc section này.

---

### IR-02: Cross-Function Data Flow Bị Cắt Đứt
```
ID       : IR-02
Layer    : IR — tools/src/Extractor/IRBuilder.php
Severity : Critical
Type     : false_negative
Status   : CONFIRMED
Fix      : PHP code change (complex)
```

**Code evidence — IRBuilder.php dòng 86-109, Phase 3 loop:**
```php
// Phase 3: For each entry point, analyze its CALLBACK BODY specifically
// — not the entire file. This prevents guard/source/sink leaking between handlers.
foreach ($allEntryPoints as $ep) {
    // ...get callback file, line start, line end...

    // Extract ONLY the callback function/method body from AST
    $callbackBody = $this->extractCallbackBody(
        $ast, $ep['callback'], $cbLineStart, $cbLineEnd
    );
    // ...
    // Run GuardVisitor on callback body ONLY
    $guardVisitor = new GuardVisitor($cbFile, $ep['id']);
    $gt = new NodeTraverser();
    $gt->addVisitor($guardVisitor);
    $gt->traverse($callbackBody);

    // Run SourceSinkVisitor on callback body ONLY, with entry_point_id
    $ssVisitor = new SourceSinkVisitor($cbFile, $ep['id']);
    $st = new NodeTraverser();
    $st->addVisitor($ssVisitor);
    $st->traverse($callbackBody);  // ← chỉ traverse callback body
}
```

Design rationale hợp lý: isolate callback body tránh guard/source/sink leaking giữa handlers. Nhưng khi callback delegate sang helper method, sink nằm NGOÀI callback body → invisible.

**Pattern bị miss:**
```php
// Entry point callback
add_action('wp_ajax_nopriv_save', function() {
    $data = $_POST['payload'];        // SOURCE: trong callback body → captured ✓
    $this->save_to_db($data);         // CALL SITE: trong callback body → captured ✓ (nhưng body của save_to_db KHÔNG analyzed)
});

// Helper method — KHÔNG được traverse
private function save_to_db($input) {
    $wpdb->query($input);             // SINK: nằm trong method body khác → invisible ✗
}
```

**Impact downstream:** IR thấy source nhưng không thấy sink → `phase3_gate._check_path_reachable()` trả score thấp → finding UNCERTAIN/PLAUSIBLE thay vì CONFIRMED. Hoặc Phase 2 LLM không tạo finding vì không thấy connection trong IR.

**Fix (PHP — IRBuilder.php):**
Implement shallow call chain resolution với depth limit. Infrastructure sẵn có: `SymbolTable::findMethod(class, method)` trả `{file, line_start, line_end}`.

```php
// Khi SourceSinkVisitor gặp $this->method() trong callback body:
// 1. Lookup method trong SymbolTable
// 2. Parse body của method đó
// 3. Run SourceSinkVisitor trên method body, kế thừa entry_point_id
// 4. Depth limit = 2 (tránh infinite recursion)

private function resolveCallChain(
    array $callSiteNode, SymbolTable $symbols, string $entryPointId,
    int $depth = 0, int $maxDepth = 2
): array {
    if ($depth >= $maxDepth) return [];
    // resolve → parse body → run visitors → return sources/sinks
}
```

**Lưu ý:** Cần IR-10 (trait resolution) để call chain hoạt động với trait methods.

---

### IR-03: Custom Guard Functions Không Được Detect
```
ID       : IR-03
Layer    : IR — tools/src/Extractor/Visitors/GuardVisitor.php
Severity : High
Type     : false_positive_passthrough
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence:** GuardVisitor chỉ detect 5 WordPress core functions cứng:
- `wp_verify_nonce` → nonce_check
- `check_ajax_referer` → nonce_check
- `check_admin_referer` → nonce_check
- `current_user_can` → capability_check
- `is_admin` → is_admin_check

Nhiều well-structured plugins wrap security checks trong custom methods:
```php
$this->verify_request();                              // custom nonce wrapper
$this->check_permissions('edit_posts');                // custom capability wrapper
SecurityHelper::validate_nonce($_POST['_nonce']);       // static helper
if (!$this->is_authorized($user_id)) { wp_die('Unauthorized'); }
```

**Impact downstream:** `phase3_gate::_check_guard_consistency()` không thấy guard trong IR → không detect contradiction khi finding claim "no nonce check" → finding pass through với score cao dù guard tồn tại → **false positive pass through toàn bộ pipeline**.

**Fix (PHP — GuardVisitor.php):**
Heuristic detection. Output `is_effective: null` (unknown). Strict criteria: chỉ flag khi method call đi kèm `wp_die()` hoặc early return trong cùng block — KHÔNG chỉ dựa naming pattern vì regex matching tên method tạo quá nhiều FP (ví dụ `$this->verify_data()` là data validation, không phải security guard).

---

### IR-04: `current_user_can()` Return Value Không Được Validate
```
ID       : IR-04
Layer    : IR — tools/src/Extractor/Visitors/GuardVisitor.php
Severity : High
Type     : false_positive_passthrough
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence — GuardVisitor.php dòng 99-118:**
```php
if ($funcName === 'current_user_can') {
    $cap = isset($node->args[0]) ? $this->resolveStringArg($node->args[0]) : null;
    $guard = [
        'entry_point_id' => $this->entryPointId,
        'type' => 'capability_check',
        'function_called' => "current_user_can('{$cap}')",
        'file' => $this->currentFile,
        'line' => $node->getStartLine(),
        'is_effective' => true,      // ← LUÔN TRUE nếu không guard-after-side-effect
        'notes' => $cap,
    ];

    // CHỈ CHECK: guard sau side-effect → is_effective = false
    if ($this->firstSideEffectLine !== null &&
        $node->getStartLine() > $this->firstSideEffectLine) {
        $guard['is_effective'] = false;
        $guard['notes'] = "guard after side-effect at line {$this->firstSideEffectLine}";
    }
    // KHÔNG CHECK: return value có được dùng trong conditional hay không

    $this->guards[] = $guard;
}
```

**Pattern được mark sai:**
```php
// GuardVisitor mark is_effective: true — SAI
$has_cap = current_user_can('manage_options'); // chỉ assignment, KHÔNG dùng trong branching
update_option('critical_setting', $_POST['value']); // chạy unconditionally
```

**Pattern đúng (effective guard thực sự):**
```php
if (!current_user_can('manage_options')) {
    wp_die('Access denied');
}
update_option('critical_setting', $_POST['value']);
```

**Fix (PHP — GuardVisitor.php):**
Check AST context khi detect `current_user_can()`:
- Nằm trong `if (!current_user_can(...))` hoặc `if (current_user_can(...))` → `is_effective: true`
- Nằm trong assignment `$var = current_user_can(...)` → `is_effective: false`, notes: "return value assigned but not used in conditional"
- Không xác định context → `is_effective: null` (unknown)

**CRITICAL khi implement:** Dùng PHP `null`, KHÔNG phải string `"unknown"`. Lý do: `AnomalyRules::hasGuardType()` check `$guard['is_effective']` (PHP truthy). `null` = falsy (correct behavior), string `"unknown"` = truthy (sẽ break AR-01). Tương tự apply cho `wp_verify_nonce()`.

---

### IR-05: REST Permission Callback Không Được Analyze
```
ID       : IR-05
Layer    : IR — tools/src/Extractor/Visitors/EntryPointVisitor.php
Severity : Medium
Type     : false_negative | false_positive_passthrough
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence — EntryPointVisitor.php `inferRestAuth()`:**
```php
private function inferRestAuth(array $routeInfo): string
{
    $pc = $routeInfo['permission_callback'] ?? null;
    if ($pc === null) return 'none';
    if ($pc === '__return_true') return 'none';
    if ($pc === 'is_user_logged_in') return 'subscriber';
    return 'unknown';  // ← closure, named function, array callable = ALL unknown
}
```

Chỉ handle 3 literal cases. Closure callback (phổ biến nhất cho REST routes) → `auth_level: 'unknown'`.

**Impact:** Phase 3 gate `_check_auth_consistency()` trả neutral score (0.8) cho `auth_level = unknown`. Severity assessment không có ground truth.

**Fix (PHP):** Khi permission_callback là closure/arrow function, partial-analyze body:
- Chứa `current_user_can('manage_options')` → `admin`
- Chứa `is_user_logged_in()` → `subscriber`
- Always return `true` → `none`
- Else → `unknown` (không thay đổi, nhưng ít nhất tried)

---

### IR-06: Security-Sensitive Filter Hooks Không Capture
```
ID       : IR-06
Layer    : IR — tools/src/Extractor/Visitors/EntryPointVisitor.php
Severity : Medium
Type     : false_negative
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence:** `HOOK_TYPE_MAP` chỉ có 4 action prefixes. `EXACT_HOOKS` chỉ có 5 action names. KHÔNG có filter hooks dù nhiều filters có security impact trực tiếp:

```php
add_filter('upload_mimes', [$this, 'allow_all_mimes']);          // arbitrary file upload
add_filter('wp_handle_upload_prefilter', [$this, 'bypass']);     // upload bypass
add_filter('user_has_cap', [$this, 'grant_capabilities']);        // privilege escalation
add_filter('authenticate', [$this, 'custom_auth']);              // auth bypass
add_filter('the_content', [$this, 'render_content']);            // stored XSS
add_filter('wp_mail', [$this, 'modify_mail']);                   // email injection
```

**Fix (PHP — EntryPointVisitor.php):**
```php
private const SECURITY_SENSITIVE_FILTERS = [
    'upload_mimes'              => ['type' => 'filter_upload', 'auth' => 'editor'],
    'wp_handle_upload_prefilter'=> ['type' => 'filter_upload', 'auth' => 'contributor'],
    'user_has_cap'              => ['type' => 'filter_capability', 'auth' => 'none'],
    'authenticate'              => ['type' => 'filter_auth', 'auth' => 'none'],
    'the_content'               => ['type' => 'filter_output', 'auth' => 'contributor'],
    'wp_mail'                   => ['type' => 'filter_mail', 'auth' => 'unknown'],
];
```

---

### IR-07: Storage Reads Absent + Write Keys Missing — Stored 2-Hop Broken
```
ID       : IR-07
Layer    : IR — tools/src/Extractor/Visitors/SourceSinkVisitor.php ↔ tools/bin/phase3_gate.py
Severity : Critical
Type     : false_negative (stored/second-order permanently under-validated)
Status   : CONFIRMED
Fix      : PHP code change (SourceSinkVisitor.php)
```

**Đây là broken contract giữa hai modules — gap quan trọng nhất.**

**Code evidence phía consumer — phase3_gate.py:**

Dòng 147-148:
```python
STORAGE_WRITE_CATEGORIES = {"option_update", "meta_update"}
STORAGE_READ_TYPES = {"option_read", "meta_read"}
```

Dòng 213-223 — build storage indexes từ IR:
```python
# Storage writes from sinks
for sink in ir.get("sinks", []):
    if sink.get("category") in self.STORAGE_WRITE_CATEGORIES:
        key = sink.get("key")                    # ← expects 'key' field on sinks
        if isinstance(key, str) and key:
            self.storage_writes_by_key.setdefault(key, []).append(sink)

# Storage reads from sources
for src in ir.get("sources", []):
    if src.get("type") in self.STORAGE_READ_TYPES:  # ← expects 'option_read'/'meta_read' in sources
        key = src.get("key")
        if isinstance(key, str) and key:
            self.storage_reads_by_key.setdefault(key, []).append(src)
```

Dòng 524-566 — `_check_stored_2hop()`:
```python
def _check_stored_2hop(self, key):
    writes = self.storage_writes_by_key.get(key, [])
    reads = self.storage_reads_by_key.get(key, [])
    # ...
    # Condition A: user source + storage write → store_ok
    # Condition B: storage read + dangerous sink → load_ok
    if store_ok and load_ok: return 1.0    # full validation
    if store_ok or load_ok: return 0.65    # partial
    return 0.4                              # weak
```

**Code evidence phía producer — SourceSinkVisitor.php:**

Source types hiện có (dòng 21-28):
```php
private const SUPERGLOBAL_TYPES = [
    '_GET' => 'superglobal_get', '_POST' => 'superglobal_post',
    '_REQUEST' => 'superglobal_request', '_COOKIE' => 'superglobal_cookie',
    '_FILES' => 'superglobal_files', '_SERVER' => 'superglobal_server',
];
// + REST API methods, shortcode/block attrs
// KHÔNG CÓ: option_read, meta_read
```

SINK_MAP (dòng 34-55) có storage writes:
```php
'update_option' => 'option_update', 'update_post_meta' => 'meta_update',
'update_user_meta' => 'meta_update', 'update_site_option' => 'option_update',
'add_option' => 'option_update', 'add_post_meta' => 'meta_update',
// KHÔNG CÓ: get_option, get_post_meta, get_user_meta
```

`addSink()` (dòng 276-287) — KHÔNG có key field:
```php
private function addSink(string $category, string $functionCalled, int $line, ?bool $usesPrepare): void
{
    $this->sinks[] = [
        'id' => 'sink_' . (++$this->sinkCounter),
        'entry_point_id' => $this->entryPointId,
        'category' => $category,
        'function_called' => $functionCalled,
        'uses_prepared_statement' => $usesPrepare,
        'file' => $this->currentFile,
        'line' => $line,
        // KHÔNG CÓ 'key' field
    ];
}
```

**Hệ quả:**
1. `storage_reads_by_key` luôn rỗng → `load_ok` luôn `False`
2. `storage_writes_by_key` luôn rỗng (no key extracted) → `store_ok` phụ thuộc vào non-keyed matching
3. `_check_stored_2hop()` trả tối đa `0.65` → mọi stored finding capped PLAUSIBLE
4. Toàn bộ stored/second-order vulnerability class (stored XSS, second-order SQLi) bị systematic undervaluation — KHÔNG PHẢI vì finding sai, mà vì IR thiếu data

**Fix (PHP — SourceSinkVisitor.php) — CẢ READ LẪN WRITE:**

1. **Thêm storage reads vào SOURCES array** (quan trọng: gate build từ sources, KHÔNG sinks):
```php
private const STORAGE_READ_MAP = [
    'get_option'       => 'option_read',
    'get_site_option'  => 'option_read',
    'get_post_meta'    => 'meta_read',
    'get_user_meta'    => 'meta_read',
    'get_term_meta'    => 'meta_read',
    'get_comment_meta' => 'meta_read',
];
// Detect trong detectFuncSink() hoặc tạo detectStorageRead() mới
// Output vào sources array: { type: "option_read", key: "setting_name", ... }
```

2. **Extract key argument cho storage writes:**
```php
// update_option('setting_name', $value) → key = 'setting_name' (arg[0])
// update_post_meta($post_id, 'meta_key', $value) → key = 'meta_key' (arg[1])
// Thêm key field vào addSink() hoặc tạo addSinkWithKey()
```

---

### IR-08: `$wpdb->prepare()` Proximity Window Quá Hẹp
```
ID       : IR-08
Layer    : IR — tools/src/Extractor/Visitors/SourceSinkVisitor.php
Severity : Medium
Type     : false_positive
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence — SourceSinkVisitor.php `checkPrepareUsage()`:**
```php
foreach ($this->prepareLines as $prepareLine) {
    if ($prepareLine < $sinkLine && ($sinkLine - $prepareLine) <= 10) {
        return true;
    }
}
```

Window = 10 dòng. Real-world WordPress pattern thường 15-25 dòng (prepare → validation → error handling → logging → query).

**Fix (PHP):** Tăng window lên 30 dòng.

**Lưu ý:** `prepareLines` không reset giữa functions trong cùng file khi Phase 4 (file-level scan) chạy. Prepare ở function A có thể "match" sink ở function B nếu cách ≤ window lines. Nhưng Phase 3 (callback-scoped) không bị vì mỗi callback tạo SourceSinkVisitor mới.

---

### IR-09: `output_return` Captures Tất Cả Returns Trong Phase 4
```
ID       : IR-09
Layer    : IR — tools/src/Extractor/Visitors/SourceSinkVisitor.php
Severity : Low
Type     : IR noise
Status   : CONFIRMED
Fix      : PHP code change
```

Phase 4 file-level scan mark mọi `return $expr` là `output_return` sink. Helper functions trả data bình thường bị mark. IR bị inflate.

**Fix (PHP):** Trong Phase 4, disable `output_return` detection. Chỉ collect sinks có real security impact.

---

### IR-10: SymbolTable Không Resolve Trait Methods
```
ID       : IR-10
Layer    : IR — tools/src/Extractor/SymbolTable.php
Severity : Medium
Type     : false_negative
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence:** `collectDeclarations()` chỉ handle 3 node types:
```php
if ($node instanceof Node\Stmt\Function_) { /* collect */ }    // dòng 69
if ($node instanceof Node\Stmt\Class_) { /* collect */ }       // dòng 83
if ($node instanceof Node\Stmt\ClassMethod) { /* collect */ }  // dòng 99
// Node\Stmt\Trait_ → NOT handled
// Node\Stmt\TraitUse → NOT handled
```

**Impact:** `findMethod('MyPlugin', 'verify_nonce')` = null khi method defined trong trait. Ảnh hưởng callback resolution, guard detection, và future call chain (IR-02).

**Fix (PHP):** Collect `Trait_` declarations giống `Class_`. Post-processing: khi class có `use TraitName`, merge trait methods vào class method table. Cần handle: method aliasing (`use Trait { method as alias }`).

---

### AR-01: AnomalyRules Amplifies IR-04 Bug (Rules 01, 02, 10)
```
ID       : AR-01
Layer    : tools/src/Rules/AnomalyRules.php
Severity : High
Type     : false_positive_passthrough (amplification)
Status   : CONFIRMED
Fix      : Fix IR-04 first. REQUIRED: PHP change in AnomalyRules Rule03 (strict === false).
```

**Code evidence — AnomalyRules.php dòng 344-354:**
```php
private function hasGuardType(array $ir, string $epId, string $guardType): bool
{
    foreach ($ir['guards'] as $guard) {
        if ($guard['entry_point_id'] === $epId &&
            $guard['type'] === $guardType &&
            $guard['is_effective']) {   // ← PHP truthy check
            return true;
        }
    }
    return false;
}
```

3 rules gọi `hasGuardType()`:
- **Rule 01** `rule01_missingNonce()`: `$hasNonce = $this->hasGuardType($ir, $ep['id'], 'nonce_check')`
- **Rule 02** `rule02_missingCapability()`: `$hasCap = $this->hasGuardType($ir, $ep['id'], 'capability_check')`
- **Rule 10** `rule10_crossHandlerInconsistency()`: both nonce and cap checks

Khi IR-04 wrongly mark `is_effective: true` → tất cả 3 rules cho rằng guard tồn tại → không fire anomaly → false positive pass through.

**Fix:** Fix IR-04 trước (dùng `null` cho unknown). `null` = falsy trong PHP → `hasGuardType()` trả false cho unknown guards.

**REQUIRED — Rule 03 PHẢI sửa cùng lúc với IR-04 (Wave 1):** `rule03_flawedNoncePattern()` dòng 89 check `!$guard['is_effective']`. Khi IR-04 deploy `null` cho unknown → `!null` = true → Rule 03 fire cho MỌI guard với `is_effective: null` → flood false anomalies. Fix:
```php
// TRƯỚC (current): fires cho cả null lẫn false
if ($guard['type'] === 'nonce_check' && !$guard['is_effective']) {

// SAU (required): chỉ fire cho confirmed flawed
if ($guard['type'] === 'nonce_check' && $guard['is_effective'] === false) {
```
**Không phải optional. Deploy cùng IR-04 trong Wave 1.**

---

### AR-02: Rule04 False Positive Trên Mixed Prepare
```
ID       : AR-02
Layer    : tools/src/Rules/AnomalyRules.php — Rule04
Severity : Medium
Type     : false_positive
Status   : CONFIRMED
Fix      : PHP code change
```

**Code evidence — AnomalyRules.php Rule04:**
```php
$epHasPrepare = [];
foreach ($ir['sinks'] as $sink) {
    if ($sink['category'] === 'sql' && $sink['uses_prepared_statement'] === true
        && $sink['entry_point_id'] !== null) {
        $epHasPrepare[$sink['entry_point_id']] = true;
    }
}
// ...
$severity = isset($epHasPrepare[$sink['entry_point_id']]) ? 'medium' : 'critical';
```

Entry-point level: EP có BẤT KỲ prepared query → TẤT CẢ unprepared queries downgrade `medium`.

**Fix (PHP):** Per-sink severity. Sink `uses_prepared_statement: false` trong EP có prepare → `high` (not medium, not critical).

---

### P2-01 / G-04: FP Findings Bypass Toàn Bộ Pipeline Validation
```
ID       : P2-01 / G-04 (same issue, two enforcement points)
Layer    : Phase 2 prompt + tools/bin/phase3_gate.py
Severity : Critical
Type     : false_negative (real vulns marked FP silently)
Status   : CONFIRMED
Fix      : Prompt change + Python code change
```

**3 tầng vấn đề:**

**Tầng 1 — Phase 2 prompt** (`tools/config/phase2-prompt-template.md`):
Requires `reasoning` field cho TP và REVIEW findings. KHÔNG require reasoning cho FP. LLM có thể output:
```json
{"finding_id": "F001", "verdict": "FP", "vuln_type": "sqli"}
// Không lý do, không evidence, không refutation trail
```

**Tầng 2 — phase3_gate.py dòng 309-323:**
```python
# A finding with verdict=FP is not scored like a TP: it is accepted as "not a vuln".
if verdict == "FP":
    return {
        "finding_id": finding.get("finding_id"),
        "verdict": verdict,
        "validation_status": "ACCEPTED_FP",
        "confidence_score": 1.0,   # confidence CAO NHẤT — zero questioning
        "checks": {},              # ZERO checks chạy
        "check_scores": {},
        "check_notes": {},
        "issues": [],
    }
```

**Tầng 3 — Phase 3b LLM:** `phase3_llm_review.py` chỉ review PLAUSIBLE/UNCERTAIN. FP findings NEVER reviewed, kể cả `--llm-mode force`.

**Vi phạm SOUL.md:** "Every REJECTED finding must carry a reopening condition." FP = rejection without reopening condition.

**Fix:**
1. **Prompt (phase2-prompt-template.md):** Bắt buộc `fp_reason` + `fp_evidence` cho FP:
```json
{"finding_id": "F001", "verdict": "FP",
 "fp_reason": "query built with hardcoded strings, no user input path",
 "fp_evidence": {"defense": "no_user_input_reachable", "file": "includes/db.php", "line": 45}}
```
2. **Gate (phase3_gate.py):** Run `_check_file_exists()` + `_check_code_evidence()` cho FP. Không thay đổi status, chỉ thêm `issues` khi evidence contradicts.
3. **Phase 3b:** Spot-check sample FP findings.

---

### P2-02: Silent Dismissal — Signals Không Surface
```
ID       : P2-02
Layer    : Phase 2 Analysis
Severity : High
Type     : false_negative | traceability
Status   : INFERRED
Fix      : Python script (deterministic)
```

Phase 2 LLM có thể internally consider Semgrep signal → decide không report → finding hoàn toàn invisible. Không có record trong output.

**Fix (Python — deterministic, zero LLM cost):** Trong `phase2_postprocess.py`: so sánh Semgrep `results[].path:line` với Phase 2 findings `file_path:line_number`. Semgrep hit không xuất hiện ở bất kỳ finding nào (kể cả FP) = potential silent dismissal → log vào `dismissed_signals` section.

**Implementation dependency:** `phase2_postprocess.py` hiện tại KHÔNG load semgrep.json — chỉ load phase2.json. Cần update:
- Thêm `--semgrep-report` CLI argument: `python3 phase2_postprocess.py <slug> --semgrep-report reports/<slug>-semgrep.json`
- Thêm `load_json(semgrep_path)` call
- `run-phase2.sh` cần pass semgrep path khi gọi postprocess

---

### P2-03: `auth_required` Field Không Normalize
```
ID       : P2-03
Layer    : tools/bin/phase2_postprocess.py
Severity : Medium
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Python code change
```

Gate compare với hardcoded strings: `"none"`, `"subscriber"`, `"contributor"`, `"author"`, `"editor"`, `"admin"`, `"system"`. LLM output `"unauthenticated"`, `"any logged-in user"`, `"admin"` → partial match at best.

**Fix:** Normalize lookup table in `phase2_postprocess.py`.

---

### P2-04: Quick Triage False Negative Risk
```
ID       : P2-04
Layer    : tools/bin/run-phase2.sh
Severity : High
Type     : false_negative
Status   : CONFIRMED
Fix      : Bash code change
```

**Code evidence — run-phase2.sh dòng 340-342:**
```bash
if [ "$FORCE_DEEP" != true ] && [ "$anom_count" = "0" ] && [ "$unauth_ep" = "0" ] \
   && [ "$sensitive_sinks" = "0" ] && [ "$sql_sinks" = "0" ] && [ "$rest_json_sources" = "0" ]; then
    mode="quick"
fi
```

Quick triage 0 TP / 0 REVIEW → deep skipped. Nhưng `anom_count=0` có thể do IR miss entry points (IR-01).

**Fix (Bash):** Sau IR-01 fix, check `unresolved_hooks` count:
```bash
unresolved=$(python3 -c "import json; print(len(json.load(open('${ir}'))
    .get('unresolved_hooks',[])))" 2>/dev/null || echo "0")
if [ "$q_tp" -gt 0 ] || [ "$q_rv" -gt 0 ] || [ "$unresolved" -gt 0 ]; then
    # escalate to deep
fi
```

---

### P2-05: No Schema Validation
```
ID       : P2-05
Layer    : tools/bin/phase2_postprocess.py
Severity : Medium
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Python code change
```

Sai types (`"45"` string thay vì `45` int, `"yes"` thay vì `true`) → gate silently degrades.

**Fix:** jsonschema validation in postprocess. Soft warnings, không block.

---

### G-01: Gate Trusts IR Guard Completeness
```
ID       : G-01
Layer    : tools/bin/phase3_gate.py
Severity : High
Type     : false_positive_passthrough
Status   : CONFIRMED
Fix      : Python code change (after IR-03/IR-04)
```

Guard check binary: hoặc có effective guard, hoặc không. Không handle `is_effective: null`.

**Fix:** Sau IR-03/IR-04: khi guard `is_effective: null` → score trung tính (0.6) + note "potential guard detected, effectiveness unknown".

---

### G-02: Reasoning Quality Gameable
```
ID       : G-02
Layer    : tools/bin/phase3_gate.py — _assess_reasoning_quality()
Severity : Medium
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Python code change
```

Keyword heuristics ("however", "but") → +0.10 score. LLM viết "However, still exploitable" → bonus without actual refutation.

**Current code already has:** `re.search(r"[\w/.-]+\.php[:\s]+(?:line\s*)?\d+", reasoning)` → +0.25 cho file:line presence. Nhưng chỉ verify PATTERN tồn tại, không verify nó MATCH finding's claimed locations.

**Fix (Python — phase3_gate.py `_assess_reasoning_quality()`):**

Thay keyword bonus (+0.10) bằng cross-reference check:

```python
import re

def _assess_reasoning_quality(self, finding: dict) -> float:
    reasoning = text_from_any(finding.get("reasoning"))
    score = 0.0
    # ... existing length check ...

    # Extract ALL file:line references from reasoning text
    # Pattern: path/to/file.php:42 hoặc path/to/file.php line 42
    refs = re.findall(r'([\w/.-]+\.php)[:\s]+(?:line\s*)?(\d+)', reasoning)

    if not refs:
        # No file:line at all → no bonus (current behavior with +0.25 stays as-is)
        pass
    else:
        # For FP findings: cross-reference against fp_evidence location (not sink)
        # FP findings often lack sink_file_path — penalizing them is incorrect
        verdict = finding.get("verdict", "")
        if verdict == "FP":
            fp_ev = finding.get("fp_evidence") or {}
            check_file = _norm_path(fp_ev.get("file", ""))
            check_line = safe_int(fp_ev.get("line", 0))
            if not check_file:
                pass  # FP without fp_evidence → skip cross-ref, no bonus no penalty
            else:
                matched = any(
                    paths_match(_norm_path(rf), check_file) and abs(int(rl) - check_line) <= 10
                    for rf, rl in refs
                )
                score += 0.25 if matched else -0.10
        else:
            # For TP/REVIEW: cross-reference against sink AND source locations
            sink_file = _norm_path(finding.get("sink_file_path", ""))
            sink_line = safe_int(finding.get("sink_line_number", 0))
            source_file = _norm_path(finding.get("source_file_path", ""))
            source_line = safe_int(finding.get("source_line_number", 0))

            matched = False
            for ref_file, ref_line_str in refs:
                ref_file_norm = _norm_path(ref_file)
                ref_line = int(ref_line_str)

                # Check match against sink OR source (either is valid)
                if paths_match(ref_file_norm, sink_file) and abs(ref_line - sink_line) <= 10:
                    matched = True
                    break
                if paths_match(ref_file_norm, source_file) and abs(ref_line - source_line) <= 10:
                    matched = True
                    break

            if matched:
                score += 0.25  # file:line matches claimed location
            else:
                score -= 0.10  # file:line present but MISMATCHES → penalize

    # ... rest of scoring ...
```

**Path handling:** Use existing `_norm_path()` and `paths_match()` functions (already in phase3_gate.py) — they handle absolute vs relative, backslash normalization, suffix matching.

**Multiple files:** `re.findall` captures all references. Match any against sink OR source. Nếu reasoning mention 5 files, chỉ cần 1 match sink/source location.

---

### G-03: Dynamic Storage Keys Undervaluation
```
ID       : G-03
Layer    : tools/bin/phase3_gate.py — _check_stored_2hop()
Severity : Medium
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Python code change (mostly resolved by IR-07)
```

Root cause = IR-07. Fix IR-07 (storage reads + key extraction) sẽ resolve phần lớn.

---

### G-05: Gate Không Validate Write-Leg Auth Cho Stored Flows
```
ID       : G-05
Layer    : tools/bin/phase3_gate.py — _resolve_entry_point(), _check_auth_consistency(), _check_guard_consistency()
Severity : High
Type     : quality_degradation (stored findings scored on wrong EP context)
Status   : CONFIRMED
Fix      : Python code change (future — khi multi-agent deploy)
```

**Vấn đề:** Gate resolve MỘT `entry_point_id` cho mỗi finding. Stored/cross-EP findings có hai EPs: store-leg (write) và load-leg (read+sink). Schema define `entry_point_id = load_entry_point_id` (vì sink ở load-leg). Gate check auth và guards của load-leg EP.

Nhưng exploitability phụ thuộc write-leg auth: nếu store EP là `ajax_nopriv` (unauthenticated), vulnerability nghiêm trọng hơn nhiều so với store EP là `admin_post` (admin only). Gate hiện KHÔNG đọc `store_entry_point_id`, KHÔNG check write-leg auth/guards.

**Code evidence:**
- `_resolve_entry_point()` dòng 230: chỉ đọc `finding.get("entry_point_id")`
- `_check_auth_consistency()` dòng 627: dùng resolved EP auth
- `_check_guard_consistency()` dòng 664: dùng resolved EP guards

**Fix (Python — phase3_gate.py, khi multi-agent deploy):** Khi finding có `store_entry_point_id`:
1. Resolve CẢ HAI EPs
2. Auth check: dùng store-leg auth (write-leg determines attacker access)
3. Guard check: check guards ở CẢ HAI legs (store-leg cần nonce/cap, load-leg cần output escaping)
4. Severity: factor in cả write-leg auth level

**Timing:** Đây là code change cần deploy CÙNG LÚC với multi-agent Step 4 (khi Agent B bắt đầu produce stored findings).

---

### L-01: `--apply-review` Off By Default
```
ID       : L-01
Layer    : tools/bin/run-phase3.sh
Severity : Medium
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Bash code change
```

**Fix:** Default apply cho `entry_point_id`/line number corrections. Require flag chỉ khi correction thay đổi verdict.

---

### L-02: Markdown Contract Validation Quá Hẹp
```
ID       : L-02
Layer    : tools/bin/phase3_llm_review.py
Severity : Low
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Python code change
```

Contract chỉ check 3 labels. Thêm pattern checks cho Status Transition format và file:line references.

---

### O-01: Patchstack-Ineligible TPs In Actionable
```
ID       : O-01
Layer    : tools/bin/phase3_gate.py
Severity : Low
Type     : quality_degradation
Status   : CONFIRMED
Fix      : Python code change
```

**Fix:** Filter `patchstack_eligible is not False`. Tách section.

---

### O-02: Semgrep Ruleset Version Not Recorded
```
ID       : O-02
Layer    : tools/bin/scan-semgrep.sh
Severity : Low
Type     : reproducibility
Status   : CONFIRMED
Fix      : Bash code change
```

`old_semgrep/` (14 rules, missing `15-rest-api.yaml`) vs `semgrep-wp-rules/` (15 rules). Reports không record ruleset nào đã chạy.

**Fix:** Thêm ruleset metadata vào output.

---

### O-03: TP→REVIEW Downgrade No Structured Diff
```
ID       : O-03
Layer    : tools/bin/phase2_postprocess.py
Severity : Low
Type     : traceability
Status   : CONFIRMED
Fix      : Python code change
```

**Fix:** Preserve `original_verdict` field. Thêm `downgraded_tp_count`.

---

### O-04: Progpilot Output Dead End
```
ID       : O-04
Layer    : Pipeline Architecture — tools/bin/scan-progpilot.sh ↔ tools/src/Store/SQLiteStore.php
Severity : Low
Type     : reproducibility | resource_waste
Status   : CONFIRMED
Fix      : Decision: integrate hoặc remove
```

**Code evidence:**
- `scan-progpilot.sh` tồn tại, output `reports/<slug>-progpilot.json`
- `SQLiteStore.php` dòng 209 import findings với phase `'progpilot'` vào SQLite
- NHƯNG: `scan-all.sh` KHÔNG gọi `scan-progpilot.sh` (grep trả rỗng)
- Phase 2 prompt (`phase2-prompt-template.md`) KHÔNG reference progpilot
- `phase3_gate.py` KHÔNG reference progpilot (grep trả rỗng)

**Hệ quả:** Progpilot infrastructure tồn tại nhưng output KHÔNG BAO GIỜ được analysis pipeline sử dụng. Resource waste + false confidence rằng pipeline đang dùng Progpilot taint analysis khi thực tế không phải.

**Fix:** Quyết định một trong hai:
- **Integrate:** Thêm `scan-progpilot.sh` vào `scan-all.sh`, reference output trong Phase 2 prompt, thêm corroboration check trong gate. Effort: Medium.
- **Remove:** Xóa `scan-progpilot.sh`, xóa `progpilot-wp-*.json` configs, xóa SQLiteStore import code. Document reason. Effort: Low.

---

### O-05: Orphaned Scripts và Folders
```
ID       : O-05
Layer    : Pipeline Architecture — tools/updated-scripts/, tools/bin/phase3-filter.py, tools/bin/phase3-validate.py
Severity : Low
Type     : traceability
Status   : CONFIRMED
Fix      : Clean up hoặc document
```

**Code evidence:**
- `tools/updated-scripts/` chứa alternative implementations: `batch.sh`, `run-phase2.sh`, `run-phase3.sh`, `scan-all.sh`, `scan-semgrep.sh`, `phase3-validate.py`, etc.
- Folder KHÔNG được reference bởi bất kỳ active script nào (grep trả rỗng)
- `tools/bin/phase3-filter.py` và `tools/bin/phase3-validate.py` (trong bin/) KHÔNG được reference bởi `run-phase3.sh` hay `run-pipeline.sh` (grep trả rỗng)

**Hệ quả:** Confusion risk — model implement multi-agent có thể nhầm khi xử lý path conflicts (which `run-phase2.sh` is active?).

**Fix:** Decision:
- **Nếu deprecated:** Xóa `updated-scripts/` và orphaned scripts. Git history giữ lịch sử.
- **Nếu draft/experimental:** Move vào `tools/experimental/` với README giải thích purpose. Hoặc rename `updated-scripts/` thành `deprecated/`.

---

### A-01: Không Có False Negative Detection
```
ID       : A-01
Layer    : Pipeline Architecture
Severity : High
Type     : false_negative
Status   : CONFIRMED (by design absence)
Fix      : PHP code change (IRBuilder output)
```

Pipeline rất mạnh giảm FP. Gần như không có mechanism detect FN — vulnerabilities mà Phase 1 không identify entry point cho.

**Fix (PHP):** Coverage report trong Phase 1 output:
```json
"coverage_gaps": {
    "unresolved_hooks": 3,
    "files_with_wp_functions_no_ep": ["includes/forms.php"],
    "suspicious_patterns": [
        {"file": "includes/forms.php", "line": 45, "pattern": "wp_verify_nonce without entry point"}
    ]
}
```

---

### A-02: No Threat Context
```
ID       : A-02
Layer    : Pipeline Architecture
Severity : Medium
Type     : quality_degradation
Status   : INFERRED
Fix      : Python/Bash script (deterministic — NO LLM)
```

Pipeline scan mọi plugin với cùng ruleset/weight. Payment plugin và SEO plugin nhận cùng treatment.

**Fix (deterministic):** `tools/config/threat-profiles.json` chứa plugin categories → priority vuln types. Bash/Python script scan readme cho keywords → match category → output `reports/context/<slug>-threat-context.json`. Feed vào Phase 2 prompt. KHÔNG cần LLM.

---

### A-03: Multi-Agent Aggregation Risk (Preventive)
```
ID       : A-03
Layer    : Pipeline Architecture — Multi-Agent Plan
Severity : High (preventive)
Type     : quality_degradation | false_positive | false_negative
Status   : INFERRED (chưa implement)
Fix      : Python deterministic merge (xem MULTI-AGENT-PLAN.md)
```

Khi implement multi-agent: aggregation PHẢI deterministic (Python script). KHÔNG dùng LLM cho merge.

---

## 4. Dependency Graph

```
IR-04 ──→ AR-01      Fix IR-04 (null for unknown) → AR-01 hasGuardType auto-resolves.
                      REQUIRED: Rule 03 cần === false (strict) — deploy cùng IR-04 trong Wave 1.

IR-07 ──→ G-03       Fix IR-07 (storage reads + key extraction) → G-03 mostly resolves.

IR-01 ──→ P2-04      Fix IR-01 (log unresolved_hooks) → P2-04 uses count for escalation.

IR-03 }
      }──→ G-01      Fix both → gate handles is_effective: null.
IR-04 }

P2-01 ══ G-04        Same issue at two enforcement points.

IR-02 ──→ IR-10      Trait resolution needed for call chain depth=2.
```

---

## 5. Implementation Waves

### Wave 1 — Quick Wins (effort thấp, impact cao)
`IR-07` · `IR-01` · `IR-04` + `AR-01/Rule03` (deploy cùng nhau) · `IR-06` · `IR-08` · `IR-09` · `AR-02` · `P2-03` · `P2-04` · `G-04` · `O-01` · `O-02` · `O-03` · `O-04` (decision: integrate hoặc remove Progpilot) · `O-05` (cleanup orphaned scripts)

### Wave 2 — Core Engineering (effort trung bình)
`IR-03` · `IR-05` · `IR-10` · `P2-01` · `P2-05` · `G-01` · `G-03` · `L-01` · `A-02`

### Wave 3 — Deep Engineering (effort cao)
`IR-02` · `A-01` · `A-03`

**Validate trên benchmark set sau MỖI wave trước khi proceed.**

**Tất cả fixes là code changes: PHP cho IR layer, Python cho P2/P3 layer, Bash cho runner scripts. Không fix nào require LLM.**

---

*Verified trên codebase `offensive-agentic-timomangcut`. Evidence tier: Tier 1 (traced code path) cho CONFIRMED items, Tier 3 (reasoning from design) cho INFERRED items.*
