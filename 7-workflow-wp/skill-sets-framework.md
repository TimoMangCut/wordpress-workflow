# Framework Prerequisites & SKILL SET Plan

> **Mục đích:** Define framework prerequisites VÀ SKILL SETs cho pipeline `offensive-agentic-timomangcut`.
> Document self-contained — reader không cần conversation history.
>
> **Đọc trước:** `GAP-ANALYSIS.md` (31 defects) và `MULTI-AGENT-PLAN.md` (architecture).
> **Build order:** Framework (this doc Part 2) → Code fixes → Validate → SKILL SETs → Validate → Deploy.

---

## 1. Context

### 1.1. Hệ thống là gì

Automated security audit pipeline cho WordPress plugins. 3 phases: Phase 1 (deterministic IR/Semgrep/Psalm) → Phase 2 (LLM analysis) → Phase 3 (deterministic gate + optional LLM skeptic). Phục vụ Patchstack bug bounty.

Pipeline có hai modes: automation hoàn toàn (local deploy) và manual step-by-step (kiểm soát quota). Multi-agent cần support cả hai.

Chi tiết: xem `GAP-ANALYSIS.md` section 1 (pipeline description, file tree, data flow).

### 1.2. Existing Document Hierarchy

Pipeline đã có hệ thống document phân cấp quản lý behavior:

**SOUL.md** (root config — `~/.claude/` hoặc `~/.codex/`)

Identity và values. CONSTANT — không thay đổi theo project. Nội dung cốt lõi:
- "I want the work to speak, so I do not have to." — Output phải tự defend.
- **Zero false positives:** "I would rather miss a real vulnerability than report a ghost." FP erodes trust.
- **Refute-first:** Thử disprove finding trước khi accept.
- **Every rejection needs reopening condition.** Close with door unlocked.
- **Evidence hierarchy 5 tiers:**
  - Tier 1 (strongest): Traced code path / reproducible PoC
  - Tier 2: Framework documented behavior
  - Tier 3: Developer docs, code comments
  - Tier 4: Pattern similarity ("this looks like CVE-XXXX") — suggestive only
  - Tier 5 (weakest): Model prior, grep match without context — never sufficient alone
- **Finding states:** SIGNAL → HYPOTHESIS → UNCERTAIN → CONFIRMED / REJECTED / RISK_NOTE
- **Impact grounded in context:** IDOR in loan application ≠ IDOR in notification preferences.
- **Developers deserve respect:** Describe code, not people.
- Khi conflict: **SOUL.md luôn thắng**.

**AGENTS.md** (project level — workspace root)

Project-specific routing cho WordPress audit workspace. Nội dung:
- Local review focus: unauthenticated entry points, AJAX/REST routes, nonce/capability enforcement, privilege escalation, file operations, SQL injection, deserialization, SSRF, RCE
- Ground exploitability in WordPress behavior + project docs
- Separate exploitability từ reportability (bounty rules)
- Output exactly one of: CONFIRMED, UNCERTAIN, RISK_NOTE, REJECTED per issue
- Reference docs: `wp-context.md` (WordPress security primitives), `patchstack-rules-summary.md`

**CLAUDE.md** (project level hoặc root config)

Reasoning methodology — HOW to think khi review security. 10 sections:
- Context gathering (application context, review context)
- Triage & scoping (deep trace vs standard vs light scan)
- Tool protocol (grep = discovery, AI = reasoning)
- 5-stage analysis workflow: SIGNAL → HYPOTHESIS → CONTEXT → REFUTE → IMPACT → VERDICT
- Evidence standard (Tier 1 required to CONFIRM, Tier 4-5 never sufficient)
- Critical rules: evidence-based only, refute first, severity honesty, negative findings valuable, uncertainty honest
- Output formats: Finding Report (Type A), Review Summary (Type B), Risk Memo (Type C)
- Interaction modes: interactive (ask, think out loud) vs autonomous (narrow claims, state assumptions)
- Quality gates: 10-point checklist before any finding reaches CONFIRMED

**SKILL.md** (security-review skill — `tools/` hoặc skills folder)

Domain knowledge base — WHAT to know. Cross-language, cross-framework. Nội dung:
- Document ingestion protocol (architecture → stack → config → known issues)
- Attack surface mapping (entry points, sensitive operations, trust boundaries)
- Authentication & authorization audit checklist
- Data flow analysis patterns
- Framework-specific security knowledge (Spring, .NET, Django, Node)
- Anomaly detection patterns (complexity smells, trust boundary violations)
- Commonly missed issues (second-order injection, mass assignment, TOCTOU, logic flaws)
- Severity calibration (context-dependent, banking/financial context)

**Override order:** SOUL.md → AGENTS.md → CLAUDE.md → SKILL.md → project docs. Specific overrides generic. Khi project docs contradict generic knowledge — project docs win, UNLESS the contradiction itself is the finding.

### 1.3. Tại Sao Framework Trước SKILL SETs

`GAP-ANALYSIS.md` gap IR-07 là bài học: `SourceSinkVisitor.php` không produce data types mà `phase3_gate.py` kỳ vọng. Broken contract giữa hai modules vì không có shared schema.

Multi-agent tăng số interfaces:
```
Phase 1 IR → IR Slicing Script → Agent A input
Phase 1 IR → Agent B input
Phase 1 IR → Agent C input (anomalies)
Phase 1 IR → Agent D input (unresolved hooks + gaps)
Agent A output → Merge Script
Agent B output → Merge Script
Agent C output → Merge Script
Agent D output → Merge Script
Merge output → Claude Code Verify
Verify output → Phase 3 Gate
```

Mỗi `→` là potential broken contract. **Framework (schema contracts + failure modes + orchestration) phải exist trước khi SKILL SETs define agent behavior.**

### 1.4. Phân Biệt Quan Trọng

```
Gap fixes        = CODE CHANGES (PHP/Python/Bash). Deterministic. KHÔNG LLM.
Phase 1          = HOÀN TOÀN DETERMINISTIC. Không có LLM agent. Mọi improvement từ code fixes.
SKILL SETs       = Per-agent INSTRUCTIONS cho Phase 2 agents + Claude Code verify.
Phase 2.5 merge  = DETERMINISTIC Python script. Không SKILL SET.
Threat context   = DETERMINISTIC keyword matching. Không LLM.
```

---

## 2. Framework Prerequisites — Build TRƯỚC SKILL SETs

### 2.1. Schema Contracts

**Tạo:** `contracts/` folder.

```
contracts/
├── ir-output.schema.json          # Phase 1 IR output (entry_points, sources, sinks, guards, anomalies, unresolved_hooks, coverage_gaps)
├── ir-slice.schema.json           # IR slice per EP group (subset of ir-output)
├── phase2-finding.schema.json     # Per-finding schema (verdict, file:line, reasoning)
├── agent-output.schema.json       # Per-agent output (findings + agent metadata)
├── merge-output.schema.json       # Python merge output (findings + merge_stats)
├── phase3-gate-input.schema.json  # What gate expects (= merge-output or phase2-output)
├── phase3-gate-output.schema.json # What gate produces (validation results)
└── README.md                      # Schema versioning rules
```

**Mỗi schema phải define:**
- Required fields với types chính xác
- Optional fields với default values
- Allowed values (enums): `verdict ∈ {TP, FP, REVIEW}`, `severity ∈ {critical, high, medium, low, informational}`, `auth_required ∈ {none, subscriber, contributor, author, editor, admin, system, unknown}`
- Nullable: `"type": ["string", "null"]` khi field có thể absent
- Version number: schema changes = version bump + migration notes

**Ví dụ — ir-output.schema.json (excerpt, prevents IR-07 recurrence):**
```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "ir-output.schema.json",
  "version": "2.0.0",
  "properties": {
    "sources": {
      "type": "array",
      "items": {
        "required": ["id", "type", "file", "line"],
        "properties": {
          "type": {
            "enum": [
              "superglobal_get", "superglobal_post", "superglobal_request",
              "superglobal_cookie", "superglobal_files", "superglobal_server",
              "rest_param", "rest_params", "rest_json", "rest_body",
              "rest_body_params", "rest_query_params", "rest_url_params",
              "rest_header", "rest_headers", "rest_array_access",
              "shortcode_attr", "block_attr",
              "option_read", "meta_read"
            ]
          },
          "key": { "type": ["string", "null"] }
        }
      }
    },
    "sinks": {
      "type": "array",
      "items": {
        "required": ["id", "category", "function_called", "file", "line"],
        "properties": {
          "key": {
            "type": ["string", "null"],
            "description": "Storage key for option_update/meta_update. Required for stored 2-hop."
          }
        }
      }
    },
    "guards": {
      "items": {
        "properties": {
          "is_effective": {
            "type": ["boolean", "null"],
            "description": "true=confirmed effective, false=confirmed ineffective, null=unknown"
          }
        }
      }
    }
  }
}
```

**Agent output schema — minimum required fields (`agent-output.schema.json`):**

Schema này PHẢI được tạo trước khi agents chạy. Merge script validate against schema — nếu file không tồn tại hoặc fields missing → hard error.

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "$id": "agent-output.schema.json",
  "version": "1.0.0",
  "type": "object",
  "required": ["agent_id", "plugin_slug", "findings"],
  "properties": {
    "agent_id": {
      "type": "string",
      "description": "Agent identifier: agent-a1, agent-a2, agent-b, agent-c, agent-d"
    },
    "plugin_slug": { "type": "string" },
    "execution_time_ms": { "type": "integer" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "required": ["finding_id", "verdict", "vuln_type", "severity"],
        "properties": {
          "finding_id": { "type": "string" },
          "verdict": { "enum": ["TP", "FP", "REVIEW"] },
          "vuln_type": { "type": "string" },
          "cwe_id": { "type": ["string", "null"] },
          "severity": { "enum": ["critical", "high", "medium", "low", "informational"] },
          "auth_required": {
            "enum": ["none", "subscriber", "contributor", "author", "editor", "admin", "system", "unknown"]
          },
          "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
          "entry_point_id": {
            "type": ["string", "null"],
            "description": "Primary EP for gate resolution. For single-EP findings: the EP. For stored/cross-EP flows: MUST = load_entry_point_id (load-leg has the sink). Gate uses this for file/path/guard checks."
          },
          "store_entry_point_id": {
            "type": ["string", "null"],
            "description": "For stored/cross-EP flows (Agent B): EP that writes to storage with user input. Null for single-EP. Gate needs this for write-leg auth validation (see GAP G-05)."
          },
          "load_entry_point_id": {
            "type": ["string", "null"],
            "description": "For stored/cross-EP flows (Agent B): EP that reads from storage and hits sink. Null for single-EP. Must equal entry_point_id when present."
          },
          "source_function": { "type": ["string", "null"] },
          "source_file_path": { "type": ["string", "null"] },
          "source_line_number": { "type": ["integer", "null"] },
          "sink_function": { "type": ["string", "null"] },
          "sink_file_path": { "type": ["string", "null"] },
          "sink_line_number": { "type": ["integer", "null"] },
          "reasoning": { "type": ["string", "null"], "description": "Required for TP and REVIEW" },
          "fp_reason": { "type": ["string", "null"], "description": "Required for FP" },
          "fp_evidence": { "type": ["object", "null"], "description": "Required for FP: {defense, file, line}" },
          "review_reason": {
            "type": ["string", "null"],
            "description": "Required for REVIEW: why uncertain + what additional evidence or test would resolve"
          },
          "poc_description": { "type": ["string", "null"] },
          "storage_key": { "type": ["string", "null"], "description": "For stored/second-order flows" },
          "patchstack_eligible": { "type": ["boolean", "null"] },
          "remediation": { "type": ["string", "null"] }
        },
        "allOf": [
          {
            "if": { "properties": { "verdict": { "const": "TP" } } },
            "then": {
              "required": [
                "entry_point_id", "reasoning",
                "source_file_path", "source_line_number", "source_function",
                "sink_file_path", "sink_line_number", "sink_function"
              ]
            }
          },
          {
            "if": { "properties": { "verdict": { "const": "FP" } } },
            "then": {
              "required": ["fp_reason", "fp_evidence"]
            }
          },
          {
            "if": { "properties": { "verdict": { "const": "REVIEW" } } },
            "then": {
              "required": ["review_reason"]
            }
          },
          {
            "if": {
              "properties": { "store_entry_point_id": { "type": "string", "minLength": 1 } },
              "required": ["store_entry_point_id"]
            },
            "then": {
              "required": ["load_entry_point_id", "storage_key", "entry_point_id"],
              "properties": {
                "entry_point_id": {
                  "description": "MUST equal load_entry_point_id for stored/cross-EP flows"
                }
              }
            }
          }
        ]
      }
    },
    "negative_findings": {
      "type": "array",
      "description": "Areas reviewed and found secure"
    }
  }
}
```

**Validation rule:** Python scripts validate output against schema BEFORE passing downstream. Schema mismatch = hard error with descriptive message, NOT silent degradation.

**RISK NOTE — Reasoning structure:** Schema hiện chỉ enforce `reasoning` là free-text string. Nhưng SOUL.md và CLAUDE.md (AppSec review workflow) yêu cầu mỗi finding mature phải có documented refutation attempts với code references (`file:line`). Gate hiện chỉ chấm reasoning quality bằng heuristic (`_assess_reasoning_quality()` trong `phase3_gate.py`). Schema enforcement cho structured refutation (ví dụ: `refutation_attempts: [{claim, result, file, line}]` thay vì free-text) là improvement cho **v2**, không blocking v1. V1 dựa vào prompt discipline + gate heuristic. Nhưng nếu reasoning quality thấp trong production, đây là điểm cần nâng cấp đầu tiên.

---

### 2.2. Failure Mode Protocol

**Tạo:** `FAILURE-MODES.md`

| Phase | Condition | Action | Log |
|-------|-----------|--------|-----|
| Phase 1 | Semgrep crash | Continue pipeline (non-blocking) | error type + stderr |
| Phase 1 | Psalm timeout | Fallback config (existing mechanism) | primary_status, fallback_used |
| Phase 1 | IR parser crash | Skip plugin, flag for manual review | parse error + file |
| Phase 2 Prep | IR slice empty for group | Skip that agent (no EPs) — not an error | group name |
| Phase 2 | Agent timeout >15min | Kill, retry 1x. Still fail → skip agent | agent name, retry count |
| Phase 2 | Agent malformed JSON | Python repair attempt. Fail → reject agent output | parse error, agent name |
| Phase 2 | Agent empty findings | Accept (plugin may be clean for this group) | agent_empty: true |
| Phase 2 | All agents fail | Fallback: single-agent Phase 2 (current pipeline) | multi_agent_fallback: true |
| Merge | Schema validation fail | Reject offending agent output, merge remaining | which fields failed |
| Merge | Conflict rate > 50% findings | Flag, escalate Claude Code to full review | conflict_rate, conflicting_ids |
| Merge | Script crash | Fallback: single-agent Phase 2 | traceback |
| Phase 3 | Gate crash | HARD ERROR — gate is authoritative, cannot skip | traceback |
| Phase 3 | Claude Code verify fail/timeout | Accept gate output without verify | unverified: true |

**Log format:** `reports/logs/<slug>-failures.json`
```json
{
  "failures": [
    {
      "phase": "phase2",
      "agent": "agent-a2",
      "failure_type": "timeout",
      "timestamp": "2025-...",
      "retry_count": 1,
      "resolution": "skipped",
      "impact": "AJAX auth findings may be incomplete"
    }
  ]
}
```

---

### 2.3. Orchestration Protocol

**Tạo:** `ORCHESTRATION.md`

Xem `MULTI-AGENT-PLAN.md` section 11 cho chi tiết. Tóm tắt:

File-based handoff. Claude Code dispatch → bash launches agents → agents write output files → bash polls → Python merge → Claude Code verify.

Support dual mode: automation (end-to-end) và manual (step-by-step với quota control).

Per-agent timeout: 15 min. Total Phase 2: 45 min. Exceeded → abort remaining, merge what exists.

---

### 2.4. Benchmark Validation Set

**Tạo:** `benchmark/` folder.

```
benchmark/
├── ground-truth/
│   ├── plugin-a.json
│   ├── plugin-b.json
│   └── ... (10+ plugins)
├── compare.py              # Compare pipeline output vs ground truth
└── README.md               # How to add entries, methodology
```

**Ground truth format:**

`verified_by` controls benchmark semantics for the plugin:
- `"manual_review"` — independent human code audit or exploit attempt. QS measures pipeline accuracy against real ground truth (canonical use).
- `"pipeline_derived"` — findings are the pipeline's own CONFIRMED output, promoted to regression-reference data. QS measures pipeline self-consistency only; does **not** constitute independent security evaluation.

```json
{
  "plugin_slug": "plugin-a",
  "plugin_version": "2.1.0",
  "verified_by": "manual_review",
  "verified_date": "2025-...",
  "findings": [
    {
      "vuln_type": "sqli",
      "entry_point_type": "ajax_nopriv",
      "hook_name": "wp_ajax_nopriv_search",
      "sink_file": "includes/search.php",
      "sink_line_approx": 45,
      "severity": "critical",
      "description": "Unprepared $wpdb->query with $_POST['search_term']"
    },
    {
      "vuln_type": "stored_xss",
      "flow_type": "cross_ep",
      "store_entry_point_type": "ajax_priv",
      "store_hook_name": "wp_ajax_save_setting",
      "store_auth": "subscriber",
      "load_entry_point_type": "shortcode",
      "load_hook_name": "plugin_display",
      "storage_key": "plugin_custom_css",
      "sink_file": "includes/shortcode.php",
      "sink_line_approx": 92,
      "severity": "high",
      "description": "Subscriber writes unescaped CSS via AJAX → shortcode renders without esc_html"
    }
  ],
  "confirmed_clean_areas": [
    "REST routes — all use $wpdb->prepare()",
    "Shortcodes — proper esc_html() on all output"
  ]
}
```

**Metrics:**
- TP: pipeline finding verdict TP matches ground truth:
  - **Single-EP:** same vuln_type + same sink file ±10 lines
  - **Stored/cross-EP:** same vuln_type + same storage_key + same sink file ±10 lines (nếu ground truth có `flow_type: "cross_ep"`)
- FP: pipeline finding verdict TP NOT in ground truth
- FN: ground truth finding NOT confirmed by pipeline — either no finding at all, OR only REVIEW verdict (pipeline detected signal but failed to confirm)
- REVIEW_HIT: pipeline finding verdict REVIEW matches ground truth location
- REVIEW_MISS: pipeline finding verdict REVIEW NOT in ground truth
- Quality Score = TP / (TP + FP + FN)
- **Decision Rate** = (TP + FP) / (TP + FP + REVIEW_HIT + REVIEW_MISS) — measures how often pipeline reaches a verdict vs hedging

**REVIEW handling rule:** REVIEW findings are NOT counted as TP (pipeline didn't confirm) and NOT counted as FP (pipeline didn't assert). Nhưng nếu ground truth vuln chỉ có REVIEW finding (không có TP), nó vẫn tính FN — pipeline detected signal nhưng failed to confirm.

**Degradation detection:** Nếu Decision Rate giảm (nhiều REVIEW hơn) mà Quality Score giữ nguyên — pipeline đang hedge thay vì decide. Đây là "đẹp số giả" pattern: Quality Score cao vì FP thấp và FN thấp, nhưng thực tế pipeline đẩy uncertainty sang REVIEW thay vì resolve. Track Decision Rate alongside Quality Score.

**Accept criteria:** Deploy changes chỉ khi:
- Quality Score ≥ previous baseline trên ALL benchmark plugins
- Decision Rate không giảm quá 10% so với baseline (cho phép một ít REVIEW tăng nhưng không quá nhiều)

**Effort acknowledgment:** Populating ground truth requires manual security review per plugin. Estimate 2-4 hours per plugin (read source, verify vulns, confirm clean areas). Total initial investment: 20-40 hours for 10 plugins. Source: plugins đã manually reviewed qua bug bounty work. Existing reports/findings có thể seed initial ground truth.

Benchmark set grows over time from feedback loop (section 2.5).

---

### 2.5. Feedback Loop

**Tạo:** `feedback/` folder.

```
feedback/
├── <slug>-feedback.json     # Per-plugin post-verification feedback
└── aggregate.py             # Aggregate feedback into actionable improvements
```

**Format:**
```json
{
  "plugin_slug": "plugin-x",
  "review_date": "2025-...",
  "pipeline_version": "2.1",
  "findings_reviewed": [
    {
      "finding_id": "F001",
      "pipeline_verdict": "TP",
      "actual_verdict": "FP",
      "reason": "LLM hallucinated sink — $wpdb->prepare() correctly used at line 67",
      "action": "improve semgrep rule: exclude prepared queries",
      "component": "semgrep"
    },
    {
      "finding_id": null,
      "pipeline_verdict": null,
      "actual_verdict": "MISSED",
      "reason": "CSRF in form handler at includes/settings.php:120 — form uses admin_init hook, no AJAX",
      "action": "add admin_init form handlers to coverage gaps detection",
      "component": "IR/EntryPointVisitor"
    }
  ]
}
```

**Feedback → Improvement flow:**
```
FP do LLM hallucinate     → Adjust Phase 2 prompt constraints / add to agent rules
FP do Semgrep false hit    → Refine Semgrep rule
FP do IR false signal      → Fix AnomalyRules threshold
FN do IR miss entry point  → Add hook type to EntryPointVisitor
FN do Phase 2 miss         → Add to benchmark set, verify agent coverage
FN do agent scope gap      → Adjust agent scope / add agent
Recurring pattern          → Add to threat-profiles.json
```

Verified missed findings → add to benchmark ground truth. Benchmark grows organically.

---

## 3. SKILL SETs

### 3.0. Skill Hierarchy

```
SOUL.md (values — constant, governs ambiguity)
  └── AGENTS.md (project rules — WordPress audit specific)
        └── CLAUDE.md (reasoning methodology — reusable across projects)
              └── SKILL SETs (per-agent instructions — specific to multi-agent pipeline)
                    └── Schema Contracts (input/output enforcement)
```

**SKILL SETs chỉ tồn tại cho Phase 2 agents (S1-S4) và Claude Code verify (S5).**

Phase 1, Phase 2 Prep (IR slicing), Phase 2.5 (merge), Phase 3 gate — tất cả deterministic, KHÔNG CÓ SKILL SET. Behavior defined bằng code.

---

### S1. Agent A — Entry Point Group Analysis

```
File: skills/phase2-ep-analysis/SKILL.md
Model: GPT-5.3-Codex (fixed)
Runs: Multiple sessions — one per EP group (A1 through A5)
```

**Context cho agent:**

Bạn là security researcher analyzing MỘT NHÓM entry points trong WordPress plugin. Bạn nhận IR slice chỉ chứa entry points thuộc nhóm được giao (ví dụ: chỉ AJAX unauth). Context window nhỏ để bạn analysis sâu.

IR đã được enhance bởi deterministic code fixes:
- Guards có `is_effective` chính xác: `true` (confirmed effective), `false` (confirmed ineffective — guard after side-effect, $die=false, etc.), `null` (unknown — custom guard hoặc unchecked return value). Khi `null` → bạn PHẢI verify manually trong source code.
- Storage reads/writes có `key` field cho 2-hop matching.
- Anomalies có per-sink severity (không entry-point level).
- Bạn CÓ THỂ tin tưởng IR cho structural information. Bạn PHẢI verify trong source code cho exploitability.

**Input:**
- IR slice: `reports/<slug>-ir-slice-<group>.json` (filtered entry points + associated sources/sinks/guards)
- Source code: `plugins/<slug>/` (chỉ đọc files referenced trong IR slice)
- Semgrep hits: `reports/<slug>-semgrep-filtered-<group>.json`
- Threat context: `reports/<slug>-threat-context.json`
- Output schema: `contracts/agent-output.schema.json`

**Tasks:**
1. Read IR slice — understand entry points, sources, sinks, guards, anomalies cho group này
2. For each entry point:
   a. Read callback source code at file:line
   b. Identify user input sources → trace to dangerous sinks
   c. Check guards: `is_effective: true` (trust), `false` (not guarded), `null` (verify manually in code)
   d. Refute-first: attempt to prove NOT exploitable (check sanitizers, type casting, framework protections)
   e. Determine verdict
3. Output structured findings

**Output rules:**
- Every **TP** finding MUST include (schema-enforced): `entry_point_id`, `source_file_path` + `source_line_number`, `sink_file_path` + `sink_line_number`, `source_function`, `sink_function`, `reasoning` (hypothesis + trace + defenses + refutation + conclusion). Recommended: `poc_description` (not schema-enforced — some logic flaws lack simple PoC)
- Every **FP** finding MUST include: `fp_reason` (why not exploitable), `fp_evidence` (defense file:line)
- Every **REVIEW** finding MUST include: `review_reason` (why uncertain + what test/evidence would resolve)
- **Prompt update required:** `phase2-prompt-template.md` và `system-prompt-phase2.md` hiện KHÔNG yêu cầu `review_reason`. Cần thêm vào prompt: "REVIEW findings must include review_reason field explaining why uncertain and what would resolve."
- **DEPLOY ORDER CRITICAL:** Prompt update phải deploy TRƯỚC khi activate schema validation cho REVIEW conditional. Nếu schema enforce `review_reason` required mà prompt chưa yêu cầu → mọi REVIEW finding fail validation → hard error. Sequence: (1) update prompts/agent SKILL SETs → (2) validate agents output `review_reason` trên test run → (3) activate schema conditional. Cả ba nằm trong Step 4 của Migration Path.
- `file:line` references MUST match actual source code
- For stored/second-order: include `storage_key` when literal; verdict REVIEW when dynamic

**Scope rules:**
- KHÔNG analyze cross-EP stored flows (Agent B's job)
- KHÔNG deep-dive anomalies (Agent C's job)
- KHÔNG investigate unresolved hooks (Agent D's job)
- Stay within assigned EP group — do not expand scope
- If guard `is_effective: null` → check source code, determine, report your finding

**Prompt structure example:**
```
System: You are a security researcher performing source code review of a WordPress plugin.
Follow refute-first methodology: attempt to disprove each potential vulnerability before confirming it.
Evidence hierarchy: traced code path > framework behavior > pattern similarity.
Zero false positives: if you cannot prove exploitation, verdict is REVIEW, not TP.
[Include relevant SOUL.md values excerpt]
[Include WordPress security primitives from SKILL.md: roles, nonces, capabilities]

Task: Analyze {EP_GROUP_TYPE} entry points for plugin `{SLUG}`.

Input files:
- IR slice: reports/{SLUG}-ir-slice-{GROUP}.json
- Source: plugins/{SLUG}/
- Semgrep: reports/{SLUG}-semgrep-filtered-{GROUP}.json
- Threat: reports/{SLUG}-threat-context.json

For each entry point in the IR slice:
1. Read callback at file:line in source code
2. Trace user input → dangerous sinks
3. Check guard effectiveness (is_effective: null means VERIFY MANUALLY)
4. Attempt refutation (sanitizers? type checks? framework protection?)
5. Output finding with verdict + evidence

Output strictly to: reports/{SLUG}-agent-{GROUP}.json
Schema: {agent-output.schema.json content}
```

---

### S2. Agent B — Stored/Cross-EP Flows

```
File: skills/phase2-stored-flows/SKILL.md
Model: GPT-5.3-Codex (fixed)
Runs: One session per plugin
```

**Context:**

Bạn detect stored XSS, second-order SQLi, cross-entry-point data flows — vulnerability class mà data flow spans NHIỀU entry points. Agent A analyze mỗi EP riêng. Bạn analyze connections GIỮA EPs.

Stored flow pattern:
```
EP_A (store leg): user input → sanitize? → update_option('key', $input)
                  Question: auth level? nonce check? sanitization at write time?

EP_B (load leg): $value = get_option('key') → echo $value
                 Question: escaping at read time? sink type (output/SQL/eval)?
```

Sau IR-07 fix, IR chứa:
- Sources với type `option_read`/`meta_read` và `key` field
- Sinks với category `option_update`/`meta_update` và `key` field
- Gate sẽ validate 2-hop bằng key matching

**Input:** Full IR (`-ir.json`) + source code + output schema

**Tasks:**
1. Map storage writes: which EPs write to options/meta? With user input?
2. Map storage reads: which EPs read from options/meta? Use in dangerous sinks?
3. Match write → read by key (literal key: exact match; dynamic key: mark REVIEW)
4. Verify: attacker reachability of write EP (auth level, nonce requirement)
5. Check sanitization at BOTH write time AND read time
6. Output findings identifying both store-leg EP and load-leg EP

**Rules:**
- ONLY cross-EP flows — do NOT re-analyze single-EP issues (Agent A's job)
- `storage_key` required khi literal; verdict REVIEW khi dynamic
- Both EPs must be identified: `store_entry_point_id` + `load_entry_point_id`
- **`entry_point_id` MUST = `load_entry_point_id`** (load-leg has the sink → gate dùng EP này cho file/path checks)
- Write-leg auth info phải nằm trong `reasoning` (ví dụ: "store EP is ajax_nopriv = unauthenticated write")

---

### S3. Agent C — Anomaly Deep Dive

```
File: skills/phase2-anomaly-verify/SKILL.md
Model: GPT-5.3-Codex (fixed)
Runs: One session per plugin
```

**Context:**

AnomalyRules (10 deterministic rules in `tools/src/Rules/AnomalyRules.php`) flag structural security patterns. Rules detect patterns nhưng KHÔNG verify exploitability — chỉ AST-level matching. Bạn verify từng anomaly bằng cách đọc actual source code.

Anomaly types: missing_nonce (Rule01), missing_capability (Rule02), flawed_nonce_pattern (Rule03), unsanitized_sql (Rule04), potential_xss (Rule05), is_admin_as_auth (Rule06), rest_return_true (Rule07), nopriv_sensitive_op (Rule08), unsafe_redirect (Rule09), inconsistency (Rule10).

**Input:** Anomalies từ IR + source code at referenced locations

**Tasks:**
1. For each anomaly: read source code at `evidence.file:evidence.line`
2. Determine: is anomaly exploitable in production?
3. Check for defenses AnomalyRules did not detect (custom guards, framework protections, type constraints)
4. Verdict: TP (exploitable), FP (defense exists), REVIEW (uncertain)

**Rules:**
- One anomaly = one finding in output
- Do NOT discover new findings outside anomalies — chỉ verify what AnomalyRules flagged
- Quick, focused sessions — anomalies usually 5-20 per plugin
- FP findings: explain what defense prevents exploitation (file:line)

---

### S4. Agent D — Unresolved Hooks + Coverage Gaps

```
File: skills/phase2-unresolved/SKILL.md
Model: GPT-5.3-Codex (fixed)
Runs: One session per plugin
```

**Context:**

IR parser logs `unresolved_hooks` (dynamic hook names nó cannot resolve) và `coverage_gaps` (files with WordPress security functions but no associated entry point). Deterministic code cannot resolve these — cần đọc source code và reason about intent.

**Phân biệt:** IR-01 fix chỉ LOG unresolved hooks. Agent D attempt RESOLVE bằng tracing source code.

**Input:**
- `unresolved_hooks` section từ IR
- `coverage_gaps` section từ IR
- Source code
- Output schema

**Tasks:**

1. **For each unresolved hook:**
   a. Read source at logged file:line
   b. Trace dynamic expression:
      - Concatenation `'wp_ajax_' . $this->action_name` → find where `$this->action_name` is assigned (constructor, init method)
      - Class constant `self::HOOK_ACTION` → find constant definition
      - Method return `$this->get_hook_name()` → read method body
   c. If resolved → analyze like Agent A: trace source→sink, check guards, refute
   d. If cannot resolve → output REVIEW with note "dynamic hook, resolution failed, manual trace required"
   e. State confidence: `high` (found literal assignment), `medium` (inferred from naming), `low` (guessed)

2. **For each coverage gap:**
   a. Why does file have `wp_verify_nonce()` or `$wpdb->query()` but no entry point?
   b. Possibilities: dead code, template include, form handler via `admin_init`, standalone AJAX not using `wp_ajax_*`
   c. If vulnerability found → output finding
   d. Coverage gap findings default verdict REVIEW (need manual confirmation)

**Rules:**
- Unresolved hooks usually 5-15 per plugin → keep sessions short
- State assumptions explicitly for unresolved patterns
- Coverage gap findings are lower confidence by nature — be honest about uncertainty

---

### S5. Claude Code Verify

```
File: skills/verify/SKILL.md
Model: Claude Code Opus (Anthropic API)
Runs: One session per plugin (minimal tokens)
```

**Context:**

Bạn verify merged output từ 4 Codex agents. Input là structured JSON (`-phase2-merged.json`), KHÔNG raw source code. Mục tiêu: spot-check, KHÔNG re-analyze. MINIMIZE token usage.

Merged output chứa `merge_stats`:
- `total_findings`: tổng findings sau merge
- `duplicates_merged`: bao nhiêu duplicates merged
- `conflicts_flagged`: bao nhiêu conflicts (agents disagreed)
- `agents_missing`: agents nào failed/skipped
- `schema_errors`: validation errors

**Input:** `reports/<slug>-phase2-merged.json`

**Tasks:**
1. **Check merge stats:** Conflict rate > 50%? Missing critical agents (agent-b for stored flows)?
2. **Spot-check top-N (3-5) highest-severity findings:**
   - Reasoning chain coherent? Flows logically from hypothesis → trace → refutation → verdict?
   - File:line references plausible? (File path looks like WordPress plugin structure?)
   - Verdict supported by stated evidence?
   - If anything suspicious → access source code at referenced file:line to verify (one file read, minimal tokens)
3. **Resolve conflicts (if any):**
   - Read both agents' reasoning
   - Check source code at referenced location
   - Decide which agent correct → update verdict
4. **Flag errors:** If finding has obvious problems → note for re-run or manual review

**Rules:**
- MINIMIZE token consumption — read merged JSON, not raw source
- Access source code ONLY for: conflict resolution, suspicious high-severity findings
- Trust agents + Phase 3 gate for everything else — gate will independently validate
- Output: **overwrites** `reports/<slug>-phase2.json` (backup lưu thành `-phase2-pre-verify.json`). Gate đọc `-phase2.json` — không cần code change gate.

---

### S6. Python Merge Script (Developer Documentation — NOT LLM Skill)

```
File: tools/bin/merge_agent_outputs.py (code)
Docs: skills/merge/README.md (documentation for developers)
```

**Deterministic. NO LLM involvement.**

Logic:
1. Load all agent output files for plugin
2. Schema validate each against `contracts/agent-output.schema.json` (reject malformed, log error)
3. Collect all findings into flat list
4. Group by dedup key:
   - **Single-EP findings:** `(entry_point_id, sink_file_path, round(sink_line/5)*5, vuln_type_normalized)`
   - **Stored/cross-EP findings** (has `store_entry_point_id` or `load_entry_point_id`): `(store_entry_point_id, load_entry_point_id, storage_key, vuln_type_normalized)` — different key because same load-leg + different store-legs are DIFFERENT findings
5. Single finding per key → keep as-is
6. Duplicates (same key, same verdict) → merge: keep highest confidence, merge reasoning into `merged_evidence`, count `agent_agreement`
7. Conflicts (same key, different verdict) → preserve BOTH, flag `conflict: True`, include `conflicting_verdicts` list
8. Schema validate merged output against `contracts/merge-output.schema.json`
9. Compute `merge_stats`
10. **Create canonical `-phase2.json`:** Copy merged output thành `reports/<slug>-phase2.json`. Đây là file gate sẽ đọc. Verify step (S5) sau đó overwrite file này với corrections. Nếu verify fail/timeout → gate vẫn có merged output (chưa verify nhưng functional).

Output:
- `reports/<slug>-phase2-merged.json` (archive — full merge output với merge_stats)
- `reports/<slug>-phase2.json` (canonical — gate đọc file này)

---

## 4. Threat Profiles (Deterministic — NO LLM)

**File:** `tools/config/threat-profiles.json`

Detection: Python/Bash script scan plugin `readme.txt` + main file description cho keywords → match category → output `-threat-context.json`. Deterministic, runs as part of Phase 1.

```json
{
  "categories": {
    "woocommerce_payment": {
      "priority_vulns": ["sqli", "idor", "privilege_escalation", "csrf"],
      "high_value_patterns": ["transaction", "payment", "order", "refund", "balance", "checkout"],
      "attack_surfaces": ["checkout hooks", "payment gateway callbacks", "order status transitions", "refund processing"]
    },
    "form_builder": {
      "priority_vulns": ["stored_xss", "sqli", "file_upload", "csrf"],
      "high_value_patterns": ["submission", "upload", "field_render", "export", "import", "csv"],
      "attack_surfaces": ["form submission handlers", "file upload processors", "CSV/PDF export", "field rendering"]
    },
    "seo_plugin": {
      "priority_vulns": ["stored_xss", "open_redirect", "sqli"],
      "high_value_patterns": ["meta_update", "sitemap", "redirect", "canonical", "analytics"],
      "attack_surfaces": ["meta box save handlers", "redirect management", "sitemap generation", "analytics tracking"]
    },
    "membership": {
      "priority_vulns": ["privilege_escalation", "idor", "authentication_bypass", "csrf"],
      "high_value_patterns": ["role", "capability", "register", "login", "subscription", "member", "access", "restrict"],
      "attack_surfaces": ["registration hooks", "role assignment", "content restriction", "login/logout handlers", "subscription management"]
    },
    "backup_migration": {
      "priority_vulns": ["arbitrary_file_read", "arbitrary_file_write", "path_traversal", "rce", "deserialization"],
      "high_value_patterns": ["backup", "restore", "export", "import", "zip", "extract", "migrate", "clone"],
      "attack_surfaces": ["backup download endpoints", "restore handlers", "file extraction", "database import/export"]
    },
    "default": {
      "priority_vulns": ["sqli", "xss", "csrf", "idor", "file_upload"],
      "high_value_patterns": [],
      "attack_surfaces": []
    }
  },
  "detection_keywords": {
    "woocommerce_payment": ["woocommerce", "payment", "gateway", "checkout", "stripe", "paypal", "braintree"],
    "form_builder": ["form", "contact", "submission", "field", "gravity", "wpforms", "formidable", "ninja forms", "caldera"],
    "seo_plugin": ["seo", "sitemap", "meta", "canonical", "redirect", "yoast", "rank math", "all in one seo"],
    "membership": ["member", "subscription", "restrict", "access", "role", "register", "buddypress", "memberpress"],
    "backup_migration": ["backup", "migrate", "restore", "duplicator", "updraftplus", "all-in-one migration", "clone"]
  }
}
```

**Maintenance:** Manual curation. Update khi discover new patterns from feedback loop. Benchmark plugins should cover at least 3 categories.

---

## 5. Implementation Order

```
PHASE 0: Framework Prerequisites (this document Part 2)
  ├── Create contracts/ folder with all schemas
  ├── Create FAILURE-MODES.md
  ├── Create ORCHESTRATION.md
  ├── Create benchmark/ with 10+ plugins ground truth
  │     (Effort: ~20-40 hours. Source: existing manual reviews + bug bounty reports)
  ├── Create feedback/ structure
  └── Create tools/config/threat-profiles.json

PHASE 1: Code Fixes — Wave 1 (GAP-ANALYSIS.md)
  ├── PHP: IR-07 (storage reads + key extraction — fix FIRST, highest ROI)
  ├── PHP: IR-01 (unresolved hooks logging)
  ├── PHP: IR-04 + AR-01/Rule03 (guard conditional check — use null; Rule03 strict === false — DEPLOY TOGETHER)
  ├── PHP: IR-06 (security filter hooks)
  ├── PHP: IR-08 (prepare window 30)
  ├── PHP: IR-09 (disable output_return Phase 4)
  ├── PHP: AR-02 (per-sink severity)
  ├── Python: P2-03 (auth normalization)
  ├── Bash: P2-04 (quick triage escalation with unresolved_hooks)
  ├── Python: G-04 (minimal FP checks in gate)
  ├── Python: O-01 (patchstack filter)
  ├── Bash: O-02 (ruleset version recording)
  ├── Python: O-03 (structured downgrade diff)
  ├── Decision: O-04 (Progpilot: integrate into pipeline or remove dead code)
  └── Cleanup: O-05 (remove/document orphaned scripts: updated-scripts/, phase3-filter.py, phase3-validate.py)
  → VALIDATE: run pipeline on benchmark set. Record baseline Quality Score.

PHASE 2: Code Fixes — Wave 2
  ├── PHP: IR-03 (custom guard heuristic)
  ├── PHP: IR-05 (REST permission callback)
  ├── PHP: IR-10 (trait method resolution)
  ├── Prompt+Python: P2-01 (FP reasoning requirement)
  ├── Python: P2-05 (schema validation in postprocess)
  ├── Python: G-01 (null effectiveness handling in gate)
  ├── Bash: L-01 (apply-review default for non-verdict corrections)
  └── Python/Bash: A-02 (threat context — deterministic keyword matching)
  → VALIDATE: Quality Score ≥ Wave 1 baseline.

PHASE 3: Build Multi-Agent Infrastructure
  ├── Python: tools/bin/prepare_agent_inputs.py (IR slicing)
  ├── Python: tools/bin/merge_agent_outputs.py (deterministic merge)
  ├── Bash: tools/bin/orchestrate-agents.sh (dispatch + monitor)
  ├── JSON: contracts/*.schema.json (all interface schemas)
  ├── Write SKILL SETs: S1 (Agent A), S2 (Agent B), S3 (Agent C), S4 (Agent D), S5 (Claude verify)
  └── Write S6 documentation

PHASE 4: Deploy Multi-Agent Phase 2
  ├── Deploy G-05 code change in phase3_gate.py (stored-flow write-leg auth validation)
  ├── Update prompts: require review_reason for REVIEW, fp_reason for FP (align with schema)
  ├── Validate prompt changes: test run confirms agents output required fields BEFORE activating schema validation
  ├── Activate schema validation (review_reason, stored-flow conditionals)
  ├── Run multi-agent pipeline on benchmark set
  ├── Compare: Quality Score + Decision Rate vs single-agent baseline
  └── Accept ONLY IF Quality Score ≥ baseline AND Decision Rate không giảm >10% on ALL benchmarks
  → If regression → investigate, fix, re-validate

PHASE 5: Code Fixes — Wave 3
  ├── PHP: IR-02 (cross-function call chain depth=2)
  └── PHP: A-01 (coverage gap reporting)
  → Multi-agent agents benefit automatically from improved IR
  → VALIDATE on benchmark set

PHASE 6: Optimize
  ├── Tune agent prompts from benchmark results + feedback
  ├── Phase 3 LLM default off nếu Phase 2 quality đủ
  ├── Adjust merge thresholds based on real conflict data
  └── Ongoing improvement from feedback loop
```

**Nguyên tắc:**
- Code fixes TRƯỚC multi-agent
- Validate TRƯỚC mỗi phase transition
- Framework prerequisites (schemas, failure modes) TRƯỚC SKILL SETs
- Benchmark set investment TRƯỚC any deployment

---

*Framework prerequisites govern structure. SKILL SETs govern agent execution. Schema contracts prevent broken interfaces. Benchmark validates improvement. Feedback drives continuous refinement. Deploy framework first, validate, then build SKILL SETs on stable foundation.*
