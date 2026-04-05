# IMPLEMENTATION-PLAN.md — WordPress Audit Pipeline Upgrade

> **Trạng thái:** 🟡 WAVE 3 IN PROGRESS — Wave 1 ✅ Wave 2 ✅ Wave 3 pending
> **Last updated:** 2026-04-04
> **Nguồn sự thật canonical:** `git log` + `change_manifest_session_N.json` + file này. Session cards = planning queue only, status trong đó KHÔNG canonical.
> **Nguồn tham chiếu:**
> - `gap-analysis-final.md` — 31 gaps với code evidence
> - `multi-agent-plan.md` — kiến trúc multi-agent
> - `skill-sets-framework.md` — schema contracts + SKILL SETs

---

## 0. Đọc trước khi làm bất cứ điều gì

### 0.1. Nguyên tắc bất biến

1. **Code fixes TRƯỚC multi-agent.** Wave 1 → validate → Wave 2 → validate → Wave 3 → validate → multi-agent. Không shortcut.
2. **Mỗi session = 1 git commit.** Bắt đầu session = `git status` sạch (chỉ untracked files là acceptable, modified/staged thì KHÔNG). Kết thúc session = commit + test pass + change_manifest.json generated.
3. **Test PHẢI pass trước khi sang session tiếp theo.** Không có "fix sau". Nếu test fail → investigate trong session hiện tại.
4. **Downstream propagation trong cùng session.** Nếu fix IR thêm field mới → prompt template đọc field đó → update cùng session, không defer.
5. **Không bao giờ để silent failure.** Mọi fix phải có path để verify bằng test command cụ thể.
6. **Nguồn sự thật canonical là `git log` + `change_manifest_session_N.json` + file này.** Session cards là planning queue; trạng thái trong session_cards KHÔNG canonical và KHÔNG được dùng để kiểm tra tiến độ.
7. **"Implemented but not wired" ≠ "Done".** Feature chỉ được coi là hoàn tất khi downstream đọc được output của nó. Mỗi wrap-up phải trả lời: (a) feature đã wired chưa? (b) downstream đã đọc field mới chưa? (c) plan/manifest/git có cùng kể một câu chuyện không?

### 0.2. Context budget

```
Overhead cố định mỗi session (system prompts tự động load): ~6.5K tokens
Safe ceiling per session: 200K tokens
Mọi session trong plan này: < 65K tokens (cách xa ceiling)

File sizes (tokens ≈ lines × 12):
  EntryPointVisitor.php  451 lines → ~5.5K
  IRBuilder.php          382 lines → ~4.5K
  SourceSinkVisitor.php  298 lines → ~3.5K
  GuardVisitor.php       155 lines → ~2K
  AnomalyRules.php       380 lines → ~5K
  phase3_gate.py        1135 lines → ~14K
  run-phase2.sh         1053 lines → ~12K
  run-phase3.sh          755 lines → ~9K
  phase2_postprocess.py  345 lines → ~4K
  phase3_llm_review.py   602 lines → ~7K
```

### 0.3. Review loop — ai làm gì

```
Trong session (tôi — self-review):
  Trước khi commit: đọc lại từng change, verify không break downstream,
  verify test command output match expectation.

Giữa sessions (tôi — dedicated review session):
  Đọc change_manifest.json (10-20K) + đoạn gap spec liên quan (3-5K)
  → verify alignment với gap spec → sign off hoặc flag issue.
  KHÔNG load toàn bộ workspace trong review session.

Wave boundary (user — bạn):
  Tôi generate wave_N_results.json (benchmark comparison)
  Bạn review file đó → approve hoặc reject → next wave.
  Chỉ 4 lần user review cho toàn bộ plan.
```

### 0.4. Change manifest format (cuối mỗi session)

Mỗi session kết thúc bằng việc tôi tạo/update file này:

```
reports/logs/implementation/change_manifest_session_N.json
```

Format:
```json
{
  "session": N,
  "date": "YYYY-MM-DD",
  "gaps_addressed": ["IR-01", "IR-06"],
  "files_modified": [
    {
      "file": "tools/src/Extractor/Visitors/EntryPointVisitor.php",
      "functions_changed": ["handleHook", "resolveStringArg"],
      "lines_affected": "90-125",
      "behavior_before": "silent return null khi hook name dynamic",
      "behavior_after": "append to unresolved_hooks[] với classifyExpression()"
    }
  ],
  "downstream_updated": ["tools/config/phase2-prompt-template.md"],
  "test_command": "php tools/bin/extract.php plugins/test-plugin/ | python3 -c \"import json,sys; d=json.load(sys.stdin); print(len(d.get('unresolved_hooks',[])))\"",
  "test_result": "PASS: output=3 (expected >0 for test-plugin with dynamic hooks)",
  "known_issues": [],
  "next_session": "Session 2 — IR-04 (GuardVisitor.php)"
}
```

---

## 1. Trạng thái tổng quan

```
PRE-WORK   [x] Session 0  — Benchmark setup
WAVE 1     [x] Session 1  — IR-01, IR-06, IR-09
           [x] Session 2  — IR-04 + AR-01 (mandatory co-deploy)      2026-04-03
           [x] Session 3  — IR-07, IR-08                            2026-04-03
           [x] Session 4  — P2-01/G-04, P2-02, P2-03, P2-04          2026-04-03
           [x] Session 5  — AR-02, G-04 gate-side, O-01, O-02, O-03      2026-04-03
           [x] Session 6  — Wave 1 Validation → USER REVIEW ①         2026-04-03
WAVE 2     [x] Session 7  — IR-03                                   2026-04-03
           [x] Session 8  — IR-05, IR-10                           2026-04-03
           [x] Session 9  — P2-05, G-01, G-02   ← 2026-04-03
           [x] Session 10 — A-02 (impl, not wired), L-01 (no-op), L-02   ← 2026-04-04
           [x] Session 11 — Wave 2 Validation → USER REVIEW ②   ← 2026-04-04
WAVE 3     [x] Session 12 — IR-02 (call chain depth=2) ← HARDEST   ← 2026-04-04
           [x] Session 13 — A-01 (coverage gap report)   <- 2026-04-04
           [x] Session 14 — Wave 3 Validation → USER REVIEW ③   <- 2026-04-04
INFRA      [x] Session 15 — Schema contracts (contracts/*.schema.json)   <- 2026-04-04
           [x] Session 16 — IR Slicing script (prepare_agent_inputs.py)   <- 2026-04-04
           [x] Session 17 — Deterministic Merge (merge_agent_outputs.py)   ← 2026-04-04
           [x] Session 18 — Orchestration (orchestrate-agents.sh + docs)   ← 2026-04-04
           [x] Session 19 — G-05: Gate update cho stored flows   ← 2026-04-04
SKILL SETS [ ] Session 20 — SKILL SETs Agents A-D
           [ ] Session 21 — SKILL SET Claude Code Verify
DEPLOY     [ ] Session 22 — Step 4 Benchmark → USER REVIEW ④
           [x] Session 23 — First multi-agent pipeline run (Wave 4, S1+S2)   ← 2026-04-05
```

### Dependency graph (PHẢI đọc trước khi bắt đầu session)

```
Session 2 (IR-04) PHẢI xong trước Session 7 (IR-03)
Session 3 (IR-07) PHẢI xong trước Session 5 (G-04 gate-side)
Session 2 (IR-04) PHẢI xong trước Session 5 (AR-02)
Session 8 (IR-10) PHẢI xong trước Session 12 (IR-02)
Session 6 (Wave 1 validate) PHẢI xong trước Session 7
Session 11 (Wave 2 validate) PHẢI xong trước Session 12
[PRE-12 STABILIZATION] PHẢI xong trước Session 12 — xem Section 1.1 bên dưới
Session 14 (Wave 3 validate) PHẢI xong trước Session 15
Sessions 15-19 PHẢI xong trước Session 20
Session 22 CẦN benchmark sẵn từ Session 0
```

### 1.1. Pre-Session-12 Stabilization Checklist

Chạy checklist này trước khi bắt đầu Session 12. Nếu bất kỳ item nào fail → fix trước, không bỏ qua.

```
SYNC STATE
[ ] git status sạch (không có modified files, chỉ untracked là OK)
[ ] IMPLEMENTATION-PLAN.md session markers đồng bộ với git log
[ ] change_manifest_session_N.json tồn tại cho mọi session đã chạy (1–11)

WIRING AUDIT (A-02)
[ ] generate_threat_context.py được gọi trong scan-all.sh hoặc run-single-plugin.sh
    → Nếu chưa: đánh dấu A-02 là "implemented, not wired" trong IMPLEMENTATION-PLAN
    → Wire hoặc ghi rõ wiring là scope của session nào
[ ] phase2-prompt-template.md có section đọc threat-context output
    → Nếu chưa: tương tự — flag, không giả vờ A-02 đã "done"

CONTRACT MINIMUM (thay vì dời toàn bộ Session 15)
[ ] Tạo contracts/ir.schema.json — tối thiểu: required fields của IR JSON (entry_points, guards, sources, sinks, unresolved_hooks, metadata)
[ ] Tạo contracts/finding.schema.json — tối thiểu: required fields (finding_id, verdict, severity, sink_file_path, sink_line_number, entry_point_id)
[ ] Tạo contracts/threat-context.schema.json — tối thiểu: plugin_slug, matched_categories, priority_vulns, method
[ ] Verify phase2_postprocess.py FINDING_SCHEMA (P2-05) align với contracts/finding.schema.json

SCRIPT CANONICAL CHECK
[ ] tools/updated-scripts/ đã có LEGACY.md (đánh dấu không dùng)
[ ] Mọi pipeline step dùng tools/bin/ không phải tools/updated-scripts/

GIT HYGIENE — RULE: repo-safe shared config = tracked; machine-local/secrets = ignored
  - Tracked (portable, no secrets): .codex/config.toml, .claude/settings.json
  - Ignored (machine-local): .claude/settings.local.json, *.local.toml, *.local.json
  - Rule: phân tách shared vs local, KHÔNG ignore cả directory nếu chứa shared config

ARTIFACT FRESHNESS
[ ] reports/backwpup-threat-context.json được regenerate từ current generate_threat_context.py
[ ] benchmark/results/wave2_summary.json verdict = APPROVED

Nếu không kịp hoàn thành contract minimum trước Session 12:
→ Tạo contracts/ directory với stub files và TODO comment
→ Ghi rõ trong Session 12 change_manifest rằng contracts chưa có
→ Session 15 giữ nguyên nhưng contracts/ phải được tạo trước khi Session 15 bắt đầu
```

---

## 2. Open Decisions (PHẢI lock trước Session 18)

| # | Câu hỏi | Trả lời hiện tại | Cần lock |
|---|---------|-----------------|----------|
| 1 | Orchestration: file-based handoff vs direct CLI? | File-based (plan) | Session 18 |
| 2 | Agent A: 5 EP groups hay consolidate? | 5 groups (plan) | Session 15 |
| 3 | Claude Code verify: top-3 hay top-5? | **top-3** ✅ (locked Session 24 — context budget, S5 skill set design) | Session 19 |
| 4 | Agent prompts: reuse phase2 hay write new? | **write new** ✅ (locked Session 24 — SKILL SETs S1-S5 are purpose-built, implemented Sessions 20-21) | Session 20 |
| **5** | **Codex accounts:** | **4-8 (confirmed)** | ✅ |
| **6** | **Parallel limit:** | **1 (serial-by-default)** ✅ (locked Session 24 — quota safety; use --parallel-limit N to override) | Session 18 |

> **Action cần làm trước Session 18:** Test chạy 2 Codex agents song song, measure quota hit rate. Quyết định concurrency ceiling từ kết quả thực tế.

---

## 3. Session Specs chi tiết

### Session 0 — Benchmark Setup

```
Status: [ ] PENDING
Est. context: ~30K tokens
Rollback: không cần (chỉ tạo files mới)
Gate trước khi proceed: compare.py chạy được + ít nhất 3 ground truth files
```

**Việc cần làm (chính xác):**

1. Tạo `benchmark/` directory structure:
   ```
   benchmark/
   ├── ground-truth/       ← JSON files per plugin
   ├── compare.py          ← script so sánh pipeline output vs ground truth
   └── README.md           ← methodology
   ```

2. Tạo `benchmark/compare.py` với các metrics:
   - `Quality Score = TP / (TP + FP + FN)`
   - `Decision Rate = (TP+FP) / (TP+FP+REVIEW_HIT+REVIEW_MISS)`
   - Input: `reports/<slug>-phase3.json` + `benchmark/ground-truth/<slug>.json`
   - Output: `benchmark/results/run_<timestamp>.json`

3. Populate 5+ ground truth files từ plugins đã manually verified.
   **Schema canonical từ `skill-sets-framework.md:373-409`** — không dùng schema khác:
   ```json
   {
     "plugin_slug": "plugin-name",
     "plugin_version": "x.y.z",
     "verified_by": "manual_review",
     "verified_date": "YYYY-MM-DD",
     "findings": [
       {
         "vuln_type": "sqli",
         "entry_point_type": "ajax_nopriv",
         "hook_name": "wp_ajax_nopriv_search",
         "sink_file": "includes/search.php",
         "sink_line_approx": 45,
         "severity": "critical",
         "description": "..."
       }
     ],
     "confirmed_clean_areas": ["admin page rendering", "settings sanitization"]
   }
   ```

4. Chạy pipeline hiện tại trên tất cả benchmark plugins → record baseline:
   ```bash
   python3 benchmark/compare.py --all > benchmark/results/baseline.json
   ```

**Test gate:** `python3 benchmark/compare.py <slug>` exit 0, output valid JSON.

---

### Session 1 — IR-01, IR-06, IR-09

```
Status: [ ] PENDING
Files sẽ đọc: EntryPointVisitor.php (5.5K), phần IR-01/06/09 của gap-analysis (~4K)
Est. context: ~40K tokens
Dependencies: Session 0 complete
Downstream phải update trong cùng session: tools/config/phase2-prompt-template.md
```

**IR-01: Dynamic hook names — log thay vì silent drop**

File: `tools/src/Extractor/Visitors/EntryPointVisitor.php`

*Trước (dòng 90-96 hiện tại):*
```php
$hookName = $this->resolveStringArg($node->args[0]);
if ($hookName === null) return;  // ← silent drop
```

*Sau:*
```php
$hookName = $this->resolveStringArg($node->args[0]);
if ($hookName === null) {
    $this->unresolvedHooks[] = [
        'file'          => $this->currentFile,
        'line'          => $node->getStartLine(),
        'function'      => $funcType,
        'hook_arg_type' => $this->classifyExpression($node->args[0]->value),
        // classifyExpression returns one of:
        // 'concatenation' | 'constant' | 'method_call' | 'variable' | 'other'
    ];
    return;
}
```

Thêm method `classifyExpression(Node $expr): string`:
```php
private function classifyExpression(Node $expr): string {
    if ($expr instanceof Node\Expr\BinaryOp\Concat) return 'concatenation';
    if ($expr instanceof Node\Expr\ClassConstFetch) return 'constant';
    if ($expr instanceof Node\Expr\PropertyFetch) return 'property';
    if ($expr instanceof Node\Expr\MethodCall) return 'method_call';
    if ($expr instanceof Node\Expr\Variable) return 'variable';
    return 'other';
}
```

IRBuilder phải output `unresolved_hooks` trong IR JSON (hiện tại field này không tồn tại). Check IRBuilder.php — nếu chưa collect từ EntryPointVisitor → thêm vào `buildIR()` output.

**IR-06: Security-sensitive filter hooks**

File: `tools/src/Extractor/Visitors/EntryPointVisitor.php`

Thêm constant (đặt cạnh `HOOK_TYPE_MAP`):
```php
private const SECURITY_SENSITIVE_FILTERS = [
    'upload_mimes'               => ['type' => 'filter_upload',     'auth' => 'editor'],
    'wp_handle_upload_prefilter' => ['type' => 'filter_upload',     'auth' => 'contributor'],
    'wp_handle_sideload_prefilter'=> ['type' => 'filter_upload',    'auth' => 'admin'],
    'user_has_cap'               => ['type' => 'filter_capability', 'auth' => 'none'],
    'authenticate'               => ['type' => 'filter_auth',       'auth' => 'none'],
    'the_content'                => ['type' => 'filter_output',     'auth' => 'contributor'],
    'comment_text'               => ['type' => 'filter_output',     'auth' => 'none'],
    'wp_mail'                    => ['type' => 'filter_mail',       'auth' => 'unknown'],
];
```

Trong `handleFilter()` (hoặc tạo nếu chưa có): check nếu hook name match `SECURITY_SENSITIVE_FILTERS` → create entry point với type/auth từ map.

**IR-09: Disable output_return trong Phase 4**

File: `tools/src/Extractor/Visitors/SourceSinkVisitor.php`

Thêm constructor flag `$isFileLevel = false`. Khi `$isFileLevel === true`, skip detection của `output_return` sink type trong `leaveNode()`.

IRBuilder.php Phase 4 loop: khởi tạo `SourceSinkVisitor($file, null, true)` (file-level = true).

**Downstream update (CÙNG SESSION):**

File: `tools/config/phase2-prompt-template.md`

Thêm section đọc `unresolved_hooks`:
```
## Unresolved Hooks
IR contains hooks with dynamic names that could not be statically resolved.
Review `ir.unresolved_hooks[]` — for each entry, attempt to trace the dynamic
expression in source code to determine actual hook name. If resolved, analyze
as standard entry point. If unresolvable, note as REVIEW.
```

**Test command:**
```bash
php tools/bin/extract.php plugins/<plugin-with-dynamic-hooks>/
# Verify: output IR JSON contains 'unresolved_hooks' array (non-empty for qualifying plugins)
# Verify: output IR contains new filter EPs for plugins using upload_mimes etc.
# Verify: IR does NOT contain output_return sinks from Phase 4
```

---

### Session 2 — IR-04 + AR-01 (mandatory co-deploy)

```
Status: [ ] PENDING
Files sẽ đọc: GuardVisitor.php (2K), AnomalyRules.php (5K)
Est. context: ~25K tokens
Dependencies: Session 1 complete
⚠️ CRITICAL: IR-04 và AR-01 (Rule03 fix) PHẢI deploy cùng nhau.
   Deploy IR-04 mà không fix AR-01 Rule03 → Rule03 sẽ flood false anomalies.
```

**IR-04: `current_user_can()` và `wp_verify_nonce()` — check AST context**

File: `tools/src/Extractor/Visitors/GuardVisitor.php`

*Trước (dòng 99-118):*
```php
'is_effective' => true,  // LUÔN true nếu không guard-after-side-effect
```

*Sau — check AST parent context:*
```php
// Khi detect current_user_can() hoặc wp_verify_nonce():
// 1. Nằm trong If condition → is_effective: true
// 2. Nằm trong Assignment ($var = ...) → is_effective: false
// 3. Khác → is_effective: null  (PHP null, KHÔNG phải string "null")

private function determineEffectiveness(Node $callNode): ?bool {
    $parent = $this->getParentNode($callNode);
    if ($parent instanceof Node\Stmt\If_) {
        return true;   // used as if-condition → effective
    }
    if ($parent instanceof Node\Expr\Assign) {
        return false;  // assigned to variable, not used in branch → ineffective
    }
    return null;       // PHP null — unknown
}
```

> **CRITICAL type note:** Return type phải là `?bool`. PHP `null` là falsy → `$guard['is_effective']` check trong `hasGuardType()` sẽ trả false cho null (đúng). String `"unknown"` là truthy → sẽ break.

**AR-01 Rule03: PHẢI fix cùng lúc**

File: `tools/src/Rules/AnomalyRules.php`

*Tìm Rule03 (dòng khoảng 85-95):*
```php
// TRƯỚC — fires cho cả null lẫn false (SAI sau IR-04 fix)
if ($guard['type'] === 'nonce_check' && !$guard['is_effective']) {

// SAU — chỉ fire cho confirmed flawed
if ($guard['type'] === 'nonce_check' && $guard['is_effective'] === false) {
```

Apply strict `=== false` cho tất cả `is_effective` checks trong AnomalyRules.php.

**Test command:**
```bash
# Test 1: current_user_can trong if() → is_effective: true
# Test 2: $var = current_user_can() → is_effective: false
# Test 3: current_user_can() trong ternary → is_effective: null
# Test 4: Rule03 KHÔNG fire cho guards với is_effective: null
php tools/bin/extract.php plugins/<test-plugin>/
# Manually verify IR guard entries cho known patterns
```

---

### Session 3 — IR-07, IR-08

```
Status: [ ] PENDING
Files sẽ đọc: SourceSinkVisitor.php (3.5K), phần IR-07/08 của gap-analysis (~4K)
Est. context: ~25K tokens
Dependencies: không (độc lập với Session 1-2)
Downstream: gate đọc field mới tự động (gate đã expect key field — IR-07 gap)
```

**IR-07: Thêm storage reads vào SOURCES + key field cho storage writes**

File: `tools/src/Extractor/Visitors/SourceSinkVisitor.php`

*Thêm STORAGE_READ_MAP constant:*
```php
private const STORAGE_READ_MAP = [
    'get_option'       => 'option_read',
    'get_site_option'  => 'option_read',
    'get_post_meta'    => 'meta_read',
    'get_user_meta'    => 'meta_read',
    'get_term_meta'    => 'meta_read',
    'get_comment_meta' => 'meta_read',
];
```

Trong `enterNode()` hoặc `leaveNode()`, khi detect function call matching STORAGE_READ_MAP:
```php
// get_option('setting_key') → key = arg[0] (index 0)
// get_post_meta($post_id, 'meta_key') → key = arg[1] (index 1)
$key = $this->resolveStringArg($node->args[$keyArgIndex]);
$this->sources[] = [
    'id'             => 'src_' . (++$this->sourceCounter),
    'entry_point_id' => $this->entryPointId,
    'type'           => self::STORAGE_READ_MAP[$funcName],
    'key'            => $key,  // null nếu dynamic key
    'variable'       => null,
    'file'           => $this->currentFile,
    'line'           => $node->getStartLine(),
];
```

*Thêm key field vào storage write sinks:*

`addSink()` hiện không nhận key. Tạo overload hoặc thêm optional `$key = null`:
```php
private function addSink(string $category, string $functionCalled, int $line,
                          ?bool $usesPrepare, ?string $key = null): void {
    $this->sinks[] = [
        // ... existing fields ...
        'key' => $key,  // new field — null nếu dynamic
    ];
}
```

Key argument index per function:
- `update_option($key, $value)` → arg[0]
- `add_option($key, $value)` → arg[0]
- `update_post_meta($post_id, $key, $value)` → arg[1]
- `update_user_meta($user_id, $key, $value)` → arg[1]
- `update_site_option($key, $value)` → arg[0]

**IR-08: Tăng $wpdb->prepare() proximity window**

File: `tools/src/Extractor/Visitors/SourceSinkVisitor.php`

```php
// TRƯỚC
if ($prepareLine < $sinkLine && ($sinkLine - $prepareLine) <= 10) {

// SAU
if ($prepareLine < $sinkLine && ($sinkLine - $prepareLine) <= 30) {
```

**Test command:**
```bash
php tools/bin/extract.php plugins/<plugin-with-stored-flows>/
# Verify: IR sources[] chứa option_read/meta_read entries
# Verify: IR sinks[] có key field cho update_option/update_post_meta
# Verify: gate _check_stored_2hop() không còn trả max 0.65
```

---

### Session 4 — P2-01/G-04, P2-02, P2-03, P2-04

```
Status: [ ] PENDING
Files sẽ đọc: phase2-prompt-template.md (61 lines), run-phase2.sh (200 lines relevant),
              phase2_postprocess.py (4K), phase3_gate.py (100 lines relevant)
Est. context: ~35K tokens
Dependencies: không
```

**P2-01: Bắt buộc fp_reason + fp_evidence cho FP findings**

File: `tools/config/phase2-prompt-template.md`

Thêm vào required fields section:
```
For FP verdict (MANDATORY — no exceptions):
  "fp_reason": "one sentence: what specific defense makes this not exploitable",
  "fp_evidence": {"defense": "defense_type", "file": "path/to/file.php", "line": 42}

Allowed defense types: no_user_input_reachable | sanitized_before_sink |
  hardcoded_value | internal_call_only | capability_required_enforced |
  nonce_enforced | dead_code | other
```

**G-04 (gate-side của P2-01): Gate validate FP evidence**

File: `tools/bin/phase3_gate.py`

Trong `_validate_finding()`, nhánh `verdict == "FP"`:
```python
# TRƯỚC
if verdict == "FP":
    return {"validation_status": "ACCEPTED_FP", "confidence_score": 1.0, "checks": {}}

# SAU
if verdict == "FP":
    checks = {}
    issues = []
    # Run file existence check on fp_evidence.file
    fp_ev = finding.get("fp_evidence") or {}
    if fp_ev.get("file"):
        file_ok = self._check_file_exists(fp_ev["file"])
        checks["fp_evidence_file_exists"] = file_ok
        if not file_ok:
            issues.append(f"FP evidence file not found: {fp_ev['file']}")
    # Check fp_reason present
    if not finding.get("fp_reason"):
        issues.append("FP finding missing fp_reason — evidence-free dismissal")
    return {
        "validation_status": "ACCEPTED_FP",
        "confidence_score": 1.0,
        "checks": checks,
        "issues": issues,  # populated nếu có problems
    }
```

**P2-02: Dismissed signals tracking**

File: `tools/bin/phase2_postprocess.py`

Thêm `--semgrep-report` argument. Sau khi load cả hai, tìm Semgrep hits không xuất hiện trong bất kỳ finding nào:
```python
def find_dismissed_signals(phase2_data, semgrep_data):
    finding_locations = set()
    for f in phase2_data.get("findings", []):
        if f.get("source_file_path") and f.get("source_line_number"):
            finding_locations.add((f["source_file_path"], f["source_line_number"]))
    dismissed = []
    for result in semgrep_data.get("results", []):
        path = result.get("path")
        line = result.get("start", {}).get("line")
        if (path, line) not in finding_locations:
            dismissed.append({"file": path, "line": line,
                              "rule": result.get("check_id")})
    return dismissed
# Output: phase2_data["dismissed_signals"] = dismissed
```

File: `tools/bin/run-phase2.sh` — update postprocess call:
```bash
python3 "${BIN_DIR}/phase2_postprocess.py" "$slug" \
    --reports-dir "$REPORTS_DIR" \
    --plugins-dir "$PLUGINS_DIR" \
    --phase2-path "$output_path" \
    --semgrep-report "${REPORTS_DIR}/${slug}-semgrep.json" \
    --in-place
```

**P2-03: `auth_required` normalization**

File: `tools/bin/phase2_postprocess.py`

```python
AUTH_NORMALIZE = {
    "unauthenticated": "none",
    "anonymous": "none",
    "public": "none",
    "any": "none",
    "any logged-in user": "subscriber",
    "any logged in user": "subscriber",
    "logged_in": "subscriber",
    "logged-in": "subscriber",
    "authenticated": "subscriber",
    "editor+": "editor",
    "administrator": "admin",
    "administrators": "admin",
    "super admin": "system",
    "network admin": "system",
}
VALID_AUTH = {"none","subscriber","contributor","author","editor","admin","system","unknown"}

def normalize_auth(value):
    if not isinstance(value, str): return "unknown"
    v = value.lower().strip()
    if v in VALID_AUTH: return v
    return AUTH_NORMALIZE.get(v, "unknown")
```

**P2-04: Quick triage escalate khi có unresolved_hooks**

File: `tools/bin/run-phase2.sh`

Sau IR-01 fix, `unresolved_hooks` field tồn tại. Trong quick triage logic (dòng ~340):
```bash
unresolved_count=$(python3 -c "
import json,sys
try:
    d=json.load(open('${ir_file}'))
    print(len(d.get('unresolved_hooks',[])))
except: print(0)
" 2>/dev/null || echo "0")

# Thêm vào điều kiện escalate sang deep:
if [ "$q_tp" -gt 0 ] || [ "$q_rv" -gt 0 ] || [ "$unresolved_count" -gt 0 ]; then
    providers_for_deep+=("$provider")
fi
```

**Test command:**
```bash
# Test P2-01: FP finding thiếu fp_reason → postprocess warning
# Test P2-02: compare dismissed_signals với semgrep output manually
# Test P2-03: input "administrator" → normalized "admin" trong output
# Test P2-04: plugin với dynamic hooks → không bị skip sang quick-only
```

---

### Session 5 — AR-02, O-01, O-02, O-03

```
Status: [ ] PENDING
Files sẽ đọc: AnomalyRules.php (5K), phase3_write_md.py (4K), run-phase2.sh (2K relevant)
Est. context: ~30K tokens
Dependencies: Session 2 (IR-04 xong để AR-02 chính xác)
```

**AR-02: Per-sink severity cho Rule04**

File: `tools/src/Rules/AnomalyRules.php`

```php
// TRƯỚC: EP-level — nếu EP có bất kỳ prepared → tất cả unprepared downgrade
$severity = isset($epHasPrepare[$sink['entry_point_id']]) ? 'medium' : 'critical';

// SAU: Per-sink — mỗi sink tự đánh giá
if ($sink['uses_prepared_statement'] === false) {
    $severity = 'critical';  // confirmed unprepared
} elseif ($sink['uses_prepared_statement'] === null) {
    $severity = 'high';      // unknown prepare status
} else {
    continue;               // uses_prepared_statement === true → skip
}
// Note: EP có prepare elsewhere không ảnh hưởng severity của sink này
```

**O-01, O-02, O-03: Output quality (low effort)**

O-01: `phase3_write_md.py` — thêm timestamp và pipeline version vào markdown header.

O-02: `run-phase2.sh` — ensure `set -euo pipefail` ở đầu (đã có, verify).
Thêm trap cleanup cho temp files nếu chưa có.

O-03: `phase2_postprocess.py` — thêm `pipeline_version` field vào output JSON.

**Test command:**
```bash
# Verify AR-02: plugin với mixed prepared/unprepared queries
# Unprepared sink trong EP có other prepared sinks → severity = 'critical' (không còn 'medium')
php tools/bin/extract.php plugins/<sql-test-plugin>/
```

---

### Session 6 — Wave 1 Validation (→ USER REVIEW ①)

```
Status: [ ] PENDING
Files sẽ đọc: benchmark/compare.py output, pipeline outputs trên benchmark set
Est. context: ~25K tokens
```

**Chạy toàn bộ pipeline trên benchmark set:**
```bash
# Với mỗi benchmark plugin:
bash tools/bin/scan-all.sh plugins/<slug>/
bash tools/bin/run-phase2.sh --slug <slug> --with-claude
bash tools/bin/run-phase3.sh --slug <slug>
python3 benchmark/compare.py <slug>

# Tổng hợp:
python3 benchmark/compare.py --all > benchmark/results/wave1_results.json
```

**Accept criteria:**
- Quality Score ≥ baseline cho TẤT CẢ benchmark plugins
- Decision Rate không giảm > 10%
- Không có regression trên bất kỳ plugin nào

**Output cho user review:**
```
benchmark/results/wave1_results.json
```

> **USER ACTION REQUIRED:** Review `benchmark/results/wave1_results.json`. Approve để tiếp tục Wave 2.

---

### Session 7 — IR-03

```
Status: [ ] PENDING
Files sẽ đọc: GuardVisitor.php (2K)
Est. context: ~20K tokens
Dependencies: Session 6 PASS, Session 2 (IR-04 đã xong)
```

**IR-03: Heuristic detection custom guard wrappers**

File: `tools/src/Extractor/Visitors/GuardVisitor.php`

Strict criteria: method call + wp_die()/wp_send_json_error()/exit() trong cùng if-block:
```php
// Pattern: if (!$this->verify_request()) { wp_die(); }
// Detect: MethodCall/StaticCall trong If condition → check if-body có early exit

private function detectCustomGuard(Node\Expr $callExpr): bool {
    // Returns true only if:
    // 1. Call is in If condition (not assignment, not argument)
    // 2. If-body contains wp_die() / wp_send_json_error() / exit() / return
    // is_effective = null (unknown — we don't know what the custom function checks)
    // KHÔNG dùng naming pattern: verify_*, check_*, validate_* → too many FPs
}
```

> **Lưu ý quan trọng:** Naming-based detection (tên method chứa "verify", "check") bị cấm. Chỉ structural detection (có early exit trong if-body). FP guard detection tệ hơn không detect.

**Test command:**
```bash
# Verify: $this->verify_request() trong if() với wp_die() → guard detected, is_effective: null
# Verify: $this->validate_data() trong if() KHÔNG có exit → không detect (data validation, not guard)
```

---

### Session 8 — IR-05, IR-10

```
Status: [x] COMPLETED — 2026-04-03
Files sẽ đọc: EntryPointVisitor.php (5.5K), SymbolTable.php (2K)
Est. context: ~28K tokens
Dependencies: Session 6 PASS
⚠️ IR-10 PHẢI xong trong session này vì Session 12 (IR-02) depend vào trait resolution
```

**IR-05: Partial-analyze REST permission_callback closures**

File: `tools/src/Extractor/Visitors/EntryPointVisitor.php`

Mở rộng `inferRestAuth()`:
```php
private function inferRestAuth(array $routeInfo): string {
    $pc = $routeInfo['permission_callback'] ?? null;
    if ($pc === null) return 'none';
    if ($pc === '__return_true') return 'none';
    if ($pc === 'is_user_logged_in') return 'subscriber';

    // NEW: analyze closure/arrow function body
    if ($routeInfo['permission_callback_ast'] instanceof Node\Expr\Closure
        || $routeInfo['permission_callback_ast'] instanceof Node\Expr\ArrowFunction) {
        return $this->analyzePermissionCallbackBody($routeInfo['permission_callback_ast']);
    }
    return 'unknown';
}

private function analyzePermissionCallbackBody(Node $closureNode): string {
    // Scan closure stmts for:
    // - current_user_can('manage_options'|'administrator') → 'admin'
    // - current_user_can('edit_posts'|'publish_posts') → 'author'
    // - current_user_can('read'|any basic cap) → 'subscriber'
    // - is_user_logged_in() → 'subscriber'
    // - return true (unconditional) → 'none'
    // - cannot determine → 'unknown'
}
```

> **Note:** `permission_callback_ast` cần được stored khi parsing REST route registration. Nếu EntryPointVisitor hiện chỉ store string, cần store AST node.

**IR-10: Trait resolution trong SymbolTable**

File: `tools/src/Extractor/SymbolTable.php`

```php
// Trong collectDeclarations(), thêm Trait_ handling:
if ($node instanceof Node\Stmt\Trait_) {
    $traitName = $node->name->toString();
    foreach ($node->stmts as $stmt) {
        if ($stmt instanceof Node\Stmt\ClassMethod) {
            $this->traitMethods[$traitName][$stmt->name->toString()] = [
                'file'       => $this->currentFile,
                'line_start' => $stmt->getStartLine(),
                'line_end'   => $stmt->getEndLine(),
            ];
        }
    }
}

// Thêm TraitUse resolution:
if ($node instanceof Node\Stmt\Class_) {
    foreach ($node->stmts as $stmt) {
        if ($stmt instanceof Node\Stmt\TraitUse) {
            foreach ($stmt->traits as $traitNameNode) {
                $traitName = $traitNameNode->toString();
                // merge trait methods vào class method table
                // Handle: aliasing (TraitUseAdaptation\Alias)
            }
        }
    }
}
```

---

### Session 9 — P2-05, G-01, G-02

```
Status: [ ] PENDING
Files sẽ đọc: phase2_postprocess.py (4K), phase3_gate.py sections liên quan (~6K)
Est. context: ~35K tokens
Dependencies: Session 3 (IR-07 xong để G-01 hoạt động đúng)
```

**P2-05: Schema validation trong postprocess**

File: `tools/bin/phase2_postprocess.py`

```python
# Soft validation — warning không block pipeline
import jsonschema

FINDING_SCHEMA = {
    "type": "object",
    "required": ["finding_id", "verdict"],
    "properties": {
        "verdict":         {"enum": ["TP", "FP", "REVIEW"]},
        "severity":        {"enum": ["critical","high","medium","low","informational"]},
        "confidence":      {"type": "number", "minimum": 0, "maximum": 1},
        "sink_line_number":{"type": ["integer","null"]},
        "source_line_number":{"type": ["integer","null"]},
    }
}
for finding in phase2_data.get("findings", []):
    try:
        jsonschema.validate(finding, FINDING_SCHEMA)
    except jsonschema.ValidationError as e:
        print(f"[WARN] Schema issue in {finding.get('finding_id')}: {e.message}", file=sys.stderr)
```

**G-01: Handle `is_effective: null` trong gate guard check**

File: `tools/bin/phase3_gate.py`

Trong `_check_guard_consistency()`:
```python
# TRƯỚC: binary — guard present or not
if any(g["is_effective"] for g in guards_for_ep):
    score = 0.9  # good

# SAU: three-state
effective_guards = [g for g in guards_for_ep if g.get("is_effective") is True]
unknown_guards   = [g for g in guards_for_ep if g.get("is_effective") is None]
broken_guards    = [g for g in guards_for_ep if g.get("is_effective") is False]

if effective_guards:
    score = 0.9
    note = "confirmed effective guard"
elif unknown_guards:
    score = 0.6   # neutral — potential guard, effectiveness unknown
    note = f"potential custom guard detected (is_effective=null): {[g['function_called'] for g in unknown_guards]}"
elif broken_guards:
    score = 0.2
    note = "guard detected but confirmed ineffective"
else:
    score = 0.1
    note = "no guard detected"
```

**G-02: Reasoning quality — cross-reference file:line**

File: `tools/bin/phase3_gate.py` — `_assess_reasoning_quality()`

```python
# Thay keyword bonus (+0.10 cho "however", "but") bằng:
# Cross-reference: file:line mentions trong reasoning có MATCH finding's claimed paths?

def _assess_reasoning_quality(self, finding, reasoning):
    score = 0.0
    if not reasoning or len(reasoning) < 50:
        return 0.0

    # Base score cho length
    if len(reasoning) > 200: score += 0.3
    if len(reasoning) > 500: score += 0.2  # longer = more thorough

    # File:line cross-reference (keep existing pattern)
    refs = re.findall(r"[\w/.-]+\.php[:\s]+(?:line\s*)?(\d+)", reasoning)
    if refs:
        score += 0.2
        # Bonus: if claimed sink_file appears in reasoning
        sink_file = finding.get("sink_file_path", "")
        if sink_file and os.path.basename(sink_file) in reasoning:
            score += 0.15  # references specific file

    # Refutation evidence: explicit "no [defense]" + why
    refutation_patterns = [r"no nonce", r"no capabilit", r"unescaped", r"unsanitized",
                           r"user.controlled", r"direct.*query", r"prepare\(\).*not"]
    refutation_count = sum(1 for p in refutation_patterns if re.search(p, reasoning, re.I))
    score += min(0.15, refutation_count * 0.05)

    # REMOVE: keyword bonus (+0.10 for "however", "but") — gameable

    return min(1.0, score)
```

---

### Session 10 — A-02, L-01, L-02

```
Status: [x] COMPLETED 2026-04-04
Files sẽ đọc: run-phase3.sh (3K relevant), phase3_llm_review.py (7K)
Est. context: ~25K tokens
Dependencies: Session 6 PASS
```

**A-02: Threat context keyword matching (deterministic)**

Tạo file mới: `tools/bin/generate_threat_context.py`
```python
# Input: plugin source code directory
# Output: reports/<slug>-threat-context.json
# Logic: keyword matching từ threat-profiles.json (cần tạo)
# Categories: payment, user-management, file-management, api-integration, etc.
# Priority vulns per category (deterministic list — không LLM)
```

Tạo file: `tools/data/threat-profiles.json`:
```json
{
  "payment": {
    "keywords": ["stripe", "paypal", "woocommerce", "payment", "checkout", "order"],
    "priority_vulns": ["sqli_in_order_processing", "auth_bypass_checkout", "price_manipulation"]
  },
  "user_management": { ... }
}
```

**L-01: Phase 3 LLM quality (bash)**

File: `tools/bin/run-phase3.sh`

Đảm bảo `--llm-mode` được pass qua đúng. Verify log format nhất quán.

**L-02: Phase 3 LLM output structured logging**

File: `tools/bin/phase3_llm_review.py`

Thêm timing log vào errlog để phân biệt timeout vs normal completion.

---

### Session 11 — Wave 2 Validation (→ USER REVIEW ②)

Cấu trúc giống Session 6. Output: `benchmark/results/wave2_results.json`.

---

### Session 12 — IR-02: Cross-function call chain (HARDEST)

```
Status: [ ] PENDING
Files sẽ đọc: IRBuilder.php (4.5K), SymbolTable.php (2K), SourceSinkVisitor.php (3.5K)
Est. context: ~50K tokens
Dependencies: Session 11 PASS + Session 8 (IR-10 trait resolution xong) — BẮT BUỘC
⚠️ Session phức tạp nhất. Nếu estimate context vượt 60K → chia thành 2 sub-sessions.
```

**IR-02: Shallow call chain resolution trong IRBuilder.php**

```php
private function resolveCallChain(
    array $callExprNodes,    // method calls trong callback body
    SymbolTable $symbols,
    string $currentClass,
    string $entryPointId,
    int $depth = 0,
    int $maxDepth = 2,
    array &$visited = []     // prevent infinite recursion
): array {
    $additionalSources = [];
    $additionalSinks = [];

    foreach ($callExprNodes as $callNode) {
        if (!($callNode instanceof Node\Expr\MethodCall)) continue;
        $methodName = $callNode->name->toString();
        $key = "{$currentClass}::{$methodName}";
        if (isset($visited[$key])) continue;  // cycle detection
        $visited[$key] = true;

        $methodInfo = $symbols->findMethod($currentClass, $methodName);
        if (!$methodInfo) continue;  // không resolve → skip

        // Parse method body
        $methodBody = $this->extractCallbackBody(
            $this->getAst($methodInfo['file']),
            ['class' => $currentClass, 'method' => $methodName],
            $methodInfo['line_start'],
            $methodInfo['line_end']
        );

        // Run SourceSinkVisitor trên method body
        $ssv = new SourceSinkVisitor($methodInfo['file'], $entryPointId);
        // ... traverse + collect ...

        // Recurse nếu depth cho phép
        if ($depth < $maxDepth) {
            $nestedCalls = $this->extractMethodCalls($methodBody);
            [$nestedSrc, $nestedSink] = $this->resolveCallChain(
                $nestedCalls, $symbols, $currentClass,
                $entryPointId, $depth + 1, $maxDepth, $visited
            );
            $additionalSources = array_merge($additionalSources, $nestedSrc);
            $additionalSinks   = array_merge($additionalSinks, $nestedSink);
        }
    }
    return [$additionalSources, $additionalSinks];
}
```

**Test command:**
```bash
# Plugin có pattern: callback → $this->helper() → $wpdb->query($input)
# TRƯỚC fix: IR không có SQL sink cho pattern này
# SAU fix: IR có SQL sink với entry_point_id đúng
php tools/bin/extract.php plugins/<call-chain-test-plugin>/
```

---

### Session 13 — A-01: Coverage gap report

```
Status: [x] COMPLETED — 2026-04-04
Files sẽ đọc: IRBuilder.php (4.5K), EntryPointVisitor.php (2K relevant)
Est. context: ~30K tokens
Dependencies: Session 11 PASS
```

**A-01: `coverage_gaps` field trong IR**

File: `tools/src/Extractor/IRBuilder.php`

Trong Phase 4 (file-level scan), detect files có WP security functions nhưng no entry point:
```php
$securitySignals = ['wp_verify_nonce', 'check_ajax_referer', 'current_user_can',
                    'wp_die', '$wpdb', 'sanitize_'];
$coverageGaps = [];
foreach ($allFiles as $file) {
    if ($this->hasEntryPoints($file)) continue;  // đã có EP → skip
    $content = file_get_contents($file);
    $signals = [];
    foreach ($securitySignals as $sig) {
        if (str_contains($content, $sig)) $signals[] = $sig;
    }
    if (!empty($signals)) {
        $coverageGaps[] = [
            'file'    => $file,
            'signals' => $signals,
            'reason'  => 'has_security_functions_but_no_entry_point',
        ];
    }
}
// Output: IR['coverage_gaps'] = $coverageGaps
```

---

### Session 14 — Wave 3 Validation (→ USER REVIEW ③)

Output: `benchmark/results/wave3_results.json`.

---

### Session 15 — Schema contracts

```
Status: [ ] PENDING
Files sẽ đọc: skill-sets-framework.md section 2.1 (~5K), multi-agent-plan.md section 6 (~2K)
Est. context: ~20K tokens
Dependencies: Session 14 PASS
Output: contracts/*.schema.json (6 files)
```

Tạo `contracts/` directory với các files:
- `ir-output.schema.json` — IR output contract (phòng tránh IR-07 recurrence)
- `ir-slice.schema.json` — slice subset
- `agent-output.schema.json` — per-agent output (full schema từ skill-sets-framework.md)
- `merge-output.schema.json` — Python merge output
- `phase3-gate-input.schema.json` — what gate expects
- `contracts/README.md` — versioning rules

---

### Session 16 — IR Slicing script

```
Status: [ ] PENDING
Files sẽ đọc: multi-agent-plan.md section 6 (~3K), contracts/ir-slice.schema.json (1K)
Est. context: ~18K tokens
Output: tools/bin/prepare_agent_inputs.py
```

Implement `slice_ir_for_group()` từ spec trong multi-agent-plan.md section 6. Validate output against `ir-slice.schema.json`.

---

### Session 17 — Deterministic Merge script

```
Status: [ ] PENDING
Files sẽ đọc: multi-agent-plan.md section 8 (~3K), contracts/agent-output.schema.json (2K),
              contracts/merge-output.schema.json (1K)
Est. context: ~18K tokens
Output: tools/bin/merge_agent_outputs.py
```

Implement `merge_agent_findings()` từ spec trong multi-agent-plan.md section 8.

Dedup key:
- Single-EP: `(entry_point_id, sink_file, sink_line ±5, vuln_type)`
- Stored/cross-EP: `(store_entry_point_id, load_entry_point_id, storage_key, vuln_type)`

---

### Session 18 — Orchestration + Failure modes

```
Status: [ ] PENDING
Files sẽ đọc: multi-agent-plan.md section 11-12 (~5K)
Est. context: ~20K tokens
Open Decision 6 PHẢI lock trước session này (parallel limit)
Output: tools/bin/orchestrate-agents.sh, FAILURE-MODES.md, ORCHESTRATION.md
```

Architecture: file-based handoff (confirmed từ Open Decision 1).

**Parallel limit — decision tree:**
```
4-8 accounts available:
  Test chạy 3 agents song song → quota hit rate < 20%? → parallel_limit = 3
  Test chạy 3 agents song song → quota hit rate ≥ 20%? → parallel_limit = 2
Default safe: parallel_limit = 2 (conservative, tăng sau nếu cần)
```

---

### Session 19 — G-05: Gate update cho stored flows

```
Status: [ ] PENDING
Files sẽ đọc: phase3_gate.py (14K — full), multi-agent-plan.md section 10 (~2K)
Est. context: ~35K tokens
Dependencies: Session 3 (IR-07), Session 15 (contracts)
Deploy cùng lúc với multi-agent Step 4
```

Trong `phase3_gate.py`:
- Khi finding có `store_entry_point_id`: resolve CẢ HAI EPs
- Check write-leg auth: store EP auth level → validate user input reachable
- Check load-leg auth: load EP auth level → standard gate checks

---

### Sessions 20-23 — SKILL SETs, Benchmark, Tuning

```
[x] Session 20: SKILL SETs Agents A-D   ← 2026-04-04
[x] Session 21: SKILL SET Claude Code Verify   ← 2026-04-04
[x] Session 22: Step 4 Benchmark (→ USER REVIEW ④)   ← 2026-04-04
[x] Session 23: First multi-agent pipeline run — Wave 4 S1+S2 for 3 benchmark plugins   ← 2026-04-05
[x] Session 24: Pipeline fixes (DI-23-01-03) + Open Decisions lock + Codex Round 3 (quota safety, provider routing, resume flag)   ← 2026-04-05
[x] Session 25: Agents C+D completion (all 3 plugins) + wave_4_results.json finalize + DI-23-03 benchmark decision (Option D)   ← 2026-04-05
[x] Session 26: Option D benchmark (compare.py) + DI-25-03 fix (accepted_fp in phase3_summary) + DI-25-02 root cause confirmed (Phase 1 extractor gap, DI-26-01) + LLM reviews (all 3 plugins) + S5 first run (backwpup)   ← 2026-04-05
[x] Session 27: DI-26-01 fix (Phase 1 extractor: resolve array callable permission_callbacks for REST EPs — 23/25 REST EPs now have capability_check guards, guard_consistent 0.1→0.6 for 17 findings) + benchmark re-run post fix   ← 2026-04-05
Session 28: DI-27-01 investigate/fix path_reachability_weak for backwpup REST EP findings + S5 for cartflows/pretty-link
```

Details sẽ được spec-out khi đến thời điểm (sau Session 19).

---

## 4. Rollback protocol

Mỗi session bắt đầu:
```bash
git status  # phải clean
git log --oneline -3  # verify starting point
```

Mỗi session kết thúc:
```bash
git add -p  # review từng hunk
git commit -m "Session N: fix IR-XX, IR-XX — [brief description]"
```

Nếu test fail sau commit:
```bash
git revert HEAD  # KHÔNG amend — tạo revert commit mới
# Investigate → fix trong session mới
```

---

## 5. Files sẽ được tạo mới (chưa tồn tại)

```
benchmark/
  ground-truth/*.json             ← Session 0
  compare.py                      ← Session 0
  results/*.json                  ← Sessions 6, 11, 14, 22

contracts/
  ir-output.schema.json           ← Session 15
  ir-slice.schema.json            ← Session 15
  agent-output.schema.json        ← Session 15
  merge-output.schema.json        ← Session 15
  phase3-gate-input.schema.json   ← Session 15
  README.md                       ← Session 15

tools/bin/
  prepare_agent_inputs.py         ← Session 16
  merge_agent_outputs.py          ← Session 17
  orchestrate-agents.sh           ← Session 18
  generate_threat_context.py      ← Session 10

tools/data/
  threat-profiles.json            ← Session 10

tools/config/
  skill-set-agent-a.md            ← Session 20
  skill-set-agent-b.md            ← Session 20
  skill-set-agent-c.md            ← Session 20
  skill-set-agent-d.md            ← Session 20
  skill-set-verify.md             ← Session 21

reports/logs/implementation/
  change_manifest_session_N.json  ← Mỗi session
  wave_N_results.json             ← Sessions 6, 11, 14, 22

FAILURE-MODES.md                  ← Session 18
ORCHESTRATION.md                  ← Session 18
```

---

## 6. Vấn đề chưa giải quyết (structural gaps)

### Agent D + Gate integration (chưa có giải pháp)

Agent D resolve dynamic hooks và output findings với entry points không tồn tại trong IR.
Gate `_check_path_reachable()` sẽ không tìm thấy entry_point_id → score thấp → UNCERTAIN/REJECTED.

**Phương án cần quyết định trước Session 19:**
- Option A: Agent D output dùng `entry_point_id: "resolved_dynamic:<hash>"` — gate skip path check cho prefix này
- Option B: IR-01 log + Agent D write resolved EPs vào IR supplement file → gate load supplement
- Option C: Agent D findings bypass gate path check, chỉ run file_exists + code_evidence checks

**Không implement Session 19 nếu chưa có quyết định này.**

### Benchmark chicken-and-egg

Session 0 cần benchmark → Session 6 cần benchmark.
Nhưng ground truth cần manual review (20-40 hours).

**Minimum viable path:**
- Session 0: chỉ cần 3 plugins với known output từ existing reports
- Đủ để detect regression, không đủ để measure improvement accurately
- Full 10-plugin benchmark → build incrementally trong các sessions 6, 11, 14

---

*Đây là living document. Update sau mỗi session bằng cách đánh dấu [x] và thêm actual results.*
