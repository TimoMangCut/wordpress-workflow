# Multi-Agent Architecture Plan — WordPress Audit Pipeline

> **Mục đích:** Define kiến trúc multi-agent cho pipeline `offensive-agentic-timomangcut`.
> Document self-contained — reader không cần conversation history.
>
> **Prerequisite đọc:** `GAP-ANALYSIS.md` — 31 defects cần fix TRƯỚC multi-agent deployment.
> **Prerequisite deploy:** Gap fixes Wave 1 + Wave 2 PHẢI hoàn thành và validated trước khi deploy multi-agent.

---

## 1. Hệ Thống Hiện Tại

### 1.1. Pipeline hiện tại

Automated security audit pipeline cho WordPress plugins. Tìm vulnerabilities phục vụ Patchstack bug bounty.

3 phases:
- **Phase 1 (Deterministic):** Semgrep SAST + Psalm taint analysis + custom IR parser (PHP-Parser AST). Không LLM.
- **Phase 2 (LLM Analysis):** Codex (OpenAI, qua ChatGPT Teams) đọc Phase 1 output + source code → trace data flows → produce findings.
- **Phase 3 (Deterministic Gate + LLM Skeptic):** `phase3_gate.py` cross-validate findings vs IR. Optional LLM review.

Pipeline có hai chế độ vận hành:
- **Automation hoàn toàn:** Deploy trên local server, chạy end-to-end.
- **Manual step-by-step:** Chạy từng phase bằng bash script, kiểm soát quota giữa phases.

Multi-agent sẽ cần support CẢ HAI modes. Orchestration scripts phải handle: full-auto (dispatch all agents, merge, verify tự động) VÀ step-by-step (chạy từng agent, review intermediate output).

Chi tiết architecture, cây thư mục, data flow: xem `GAP-ANALYSIS.md` section 1.

### 1.2. Vấn đề cần giải quyết

**Phase 2 hiện tại gánh quá nhiều trong MỘT LLM session:**

Trong một session duy nhất, Codex phải:
- Đọc IR JSON (hàng trăm entry points, sources, sinks, guards, anomalies)
- Đọc Semgrep output (hàng chục hits)
- Đọc Psalm SARIF (corroboration)
- Đọc source code (5K-50K LOC per plugin)
- Trace source → sink cho MỖI entry point
- Check guard effectiveness (nonce, capability)
- Refute-first: attempt disprove mỗi potential finding
- Output structured JSON với reasoning

**Context window pressure:** Khi input lớn (large plugins, nhiều entry points), LLM phải xử lý quá nhiều information trong một session. Biểu hiện cụ thể:
- Miss vulnerabilities (đặc biệt stored/second-order flows spanning nhiều entry points)
- Produce shallow reasoning (brief dismissal thay vì thorough refutation)
- Hallucinate file:line references (nhớ sai location)
- Drop context giữa findings (finding thứ 10 chất lượng thấp hơn finding thứ 1)

**Đây là lý do Phase 3 tồn tại:** không tin tưởng hoàn toàn Phase 2. Phase 3 gate cross-validate, Phase 3 LLM skeptic double-check.

### 1.3. Multi-agent giải quyết gì

Chia Phase 2 thành nhiều agents, mỗi agent xử lý PHẦN NHỎ HƠN:
- **Context window nhỏ hơn per agent** → deeper analysis per task
- **Mỗi agent focused** → less distraction, less context switching
- **Song song** → faster total execution time
- **Specialized** → stored flow detection riêng, anomaly verification riêng

---

## 2. Ranh Giới: Code Fixes vs Agent Work

**Đây là phân biệt quan trọng nhất trong document này.**

`GAP-ANALYSIS.md` documents 31 defects. **TẤT CẢ gap fixes là code changes** — PHP, Python, Bash. Deterministic. KHÔNG cần LLM:

```
IR gaps (IR-01 đến IR-10):    Sửa PHP trong tools/src/Extractor/ và tools/src/Rules/
P2/P3 gaps (P2-01 đến G-04): Sửa Python/Bash trong tools/bin/
Architecture gaps (A-01, A-02): Thêm scripts mới
```

**Multi-agent KHÔNG fix gaps.** Multi-agent giải quyết vấn đề KHÁC: Phase 2 context window pressure.

**Sequence bắt buộc:**
1. Deploy code fixes (Wave 1 → validate → Wave 2 → validate)
2. SAU KHI IR quality đủ → deploy multi-agent
3. Multi-agent trên IR chưa fix = garbage in, multi-garbage out

---

## 3. Economic Constraints

```
Codex (GPT-5.3-Codex) — ChatGPT Teams subscription:
  - Subscription-based, CÓ limit quota per account
  - Quota managed bằng account rotation trong cùng ChatGPT Business team
  - Rẻ hơn NHIỀU so với Claude Code API per-token
  - Model: CỐ ĐỊNH GPT-5.3-Codex — không mix nhiều models khác nhau
  - Role: TẤT CẢ analysis work (heavy lifting)
  - Với đủ context + input + prompt tốt: output tương đương Claude Code,
    không có sự khác biệt rõ rệt (cần validate trên benchmark trước deploy)

Claude Code (Anthropic API):
  - Pay-per-token, ĐẮT
  - Role: VERIFY merged output + ORCHESTRATE pipeline
  - Target: 70-80% token reduction so với nếu Claude Code làm full analysis
  - KHÔNG để Claude Code thực hiện full analysis — chỉ verify + dispatch

Python Scripts:
  - Cost: zero
  - Role: deterministic merge, schema validation, IR slicing, deduplication
  - KHÔNG dùng LLM cho aggregation/merge step
```

**Nguyên tắc kinh tế:** Maximize Codex work (lower marginal cost per finding) → minimize Claude Code tokens (expensive, chỉ verify) → deterministic scripts cho mọi thứ automatable.

---

## 4. Architecture

### 4.1. Tổng quan

```
Phase 1 — HOÀN TOÀN DETERMINISTIC (không LLM)
  ├── IR extraction (với tất cả gap fixes đã deploy)
  ├── Semgrep scan (15 custom rules)
  ├── Psalm taint analysis (với fallback)
  ├── Threat context (keyword matching từ threat-profiles.json — deterministic)
  └── Coverage gap report (deterministic)
  Output: -ir.json, -semgrep.json, -psalm.sarif, -threat-context.json

Phase 2 Prep — DETERMINISTIC
  └── IR Slicing: split IR thành per-group slices cho agents
  Output: -ir-slice-{group}.json, -semgrep-filtered-{group}.json

Phase 2 — MULTI-AGENT (Codex GPT-5.3-Codex)
  ├── Agent A (per EP group): AJAX unauth/auth, REST, shortcodes, other
  ├── Agent B: stored/cross-EP flows
  ├── Agent C: anomaly verification
  └── Agent D: unresolved hooks + coverage gap investigation
  Output: -agent-a1.json, -agent-a2.json, ..., -agent-d.json

Phase 2.5 — DETERMINISTIC MERGE (Python script)
  └── Dedup, conflict-flag, schema validate
  Output: -phase2-merged.json (archive) + copies to -phase2.json (canonical for gate)

Phase 2.9 — CLAUDE CODE VERIFY (minimal tokens)
  └── Spot-check top-N findings, resolve conflicts
  Output: overwrites -phase2.json (backup: -phase2-pre-verify.json)

Phase 3 — DETERMINISTIC GATE + optional LLM skeptic
  └── Cross-validate vs IR, confidence scoring
  Output: -phase3.json, markdown reports
```

**Phase 1 KHÔNG CÓ LLM agent.** Tất cả Phase 1 improvements đến từ code fixes.

### 4.2. Sơ đồ

```
Plugin Source Code
       │
       ▼
Phase 1 (deterministic — IR, Semgrep, Psalm, threat context)
       │
       ▼
Phase 2 Prep: IR Slicing Script (deterministic)
       │
       ├─── IR slice AJAX unauth + source files + semgrep hits
       ├─── IR slice AJAX auth + ...
       ├─── IR slice REST + ...
       ├─── IR slice shortcodes + ...
       ├─── Full IR (cho Agent B, D)
       └─── Anomalies (cho Agent C)
       │
       ▼
                    ┌─────────────────────────┐
                    │   Claude Code Opus       │
                    │   (Orchestrator)         │
                    │   writes dispatch.json   │
                    └────────┬────────────────┘
                             │
           ┌─────────┬──────┼──────┬──────────┐
           ▼         ▼      ▼      ▼          ▼
      ┌────────┐┌────────┐┌────────┐┌────────┐
      │Codex   ││Codex   ││Codex   ││Codex   │
      │Agent A ││Agent B ││Agent C ││Agent D │
      │EP Group││Stored  ││Anomaly ││Unresol.│
      └───┬────┘└───┬────┘└───┬────┘└───┬────┘
          │         │         │         │
          ▼         ▼         ▼         ▼
     ┌──────────────────────────────────────┐
     │   Python Deterministic Merge         │
     │   (dedup, conflict, schema validate) │
     └─────────────────┬────────────────────┘
                       ▼
              ┌─────────────────┐
              │Claude Code Opus │
              │(Verify top-N)   │
              └────────┬────────┘
                       ▼
              ┌─────────────────┐
              │Phase 3 Gate     │
              │(deterministic)  │
              └─────────────────┘
```

---

## 5. Phase 1 (Deterministic — Không Thay Đổi Ngoài Code Fixes)

Sau khi deploy gap fixes (Wave 1 + 2 + 3), Phase 1 IR output chứa:

- **Entry points:** hooks, REST routes, shortcodes, blocks, cron, security-sensitive filters (IR-06 fix)
- **Unresolved hooks:** logged với file, line, arg type (IR-01 fix) — agents sẽ attempt resolve
- **Sources:** superglobals, REST params, shortcode/block attrs, **`option_read`, `meta_read` với key field** (IR-07 fix)
- **Sinks:** SQL, file ops, output, eval, redirect, deserialization, remote requests, **với `key` field cho storage writes** (IR-07 fix)
- **Guards:** nonce, capability checks **với accurate `is_effective`: true/false/null** (IR-04 fix)
- **Anomalies:** 10 rules **với per-sink severity** (AR-02 fix), accurate guard detection (AR-01 fix)
- **Coverage gaps:** files có WP security functions nhưng no entry point (A-01 fix) — **Wave 3, chưa có khi multi-agent deploy lần đầu**
- **Call chains:** depth=2 từ callbacks (IR-02 fix) — **Wave 3, chưa có khi multi-agent deploy lần đầu**
- **Threat context:** plugin category + priority vulns từ keyword matching (A-02 fix)

**LƯU Ý QUAN TRỌNG VỀ ROLLOUT ORDER:** Multi-agent deploy (Step 4 trong Migration) xảy ra SAU Wave 1+2 nhưng TRƯỚC Wave 3. Tại thời điểm multi-agent deploy lần đầu:
- `coverage_gaps` = `{}` (empty) — Agent D sẽ chỉ xử lý `unresolved_hooks`, không có coverage gaps để investigate
- Call chain depth = 0 (chưa implement) — IR vẫn chỉ thấy callback body, không follow `$this->method()`
- Benchmark ở Step 4 là **partial benchmark** — validate architecture THIẾU hai features này
- **Full architecture benchmark chỉ có sau Step 5** (Wave 3 deploy)

Agents phải handle gracefully khi fields này empty/missing — không crash, không assume data exists.

Output files: `-ir.json`, `-semgrep.json`, `-psalm.sarif`, `-threat-context.json`

---

## 6. Phase 2 Prep: IR Slicing (Deterministic)

**Đây là step mới cần build — script chia IR cho agents.**

Script: `tools/bin/prepare_agent_inputs.py`

Input: `-ir.json`, `-semgrep.json`

Output per agent:
```
reports/<slug>-ir-slice-ajax-unauth.json   # Agent A1: chỉ ajax_nopriv + admin_post_nopriv EPs
reports/<slug>-ir-slice-ajax-auth.json     # Agent A2: chỉ ajax_priv + admin_post EPs
reports/<slug>-ir-slice-rest.json          # Agent A3: chỉ rest_route EPs
reports/<slug>-ir-slice-shortcode.json     # Agent A4: shortcode + block EPs
reports/<slug>-ir-slice-other.json         # Agent A5: cron, init, template_redirect, filters
reports/<slug>-semgrep-filtered-{group}.json  # Semgrep hits filtered per group

# Agent B, D nhận full IR (không slice)
# Agent C nhận anomalies section từ IR
```

Slicing logic:
```python
def slice_ir_for_group(ir: dict, ep_types: set) -> dict:
    """
    Filter entry_points by type.
    Keep sources/sinks/guards matching filtered entry_point_ids.
    Keep metadata unchanged.
    """
    eps = [ep for ep in ir["entry_points"] if ep["type"] in ep_types]
    ep_ids = {ep["id"] for ep in eps}
    return {
        "metadata": ir["metadata"],
        "entry_points": eps,
        "sources": [s for s in ir["sources"] if s.get("entry_point_id") in ep_ids],
        "sinks": [s for s in ir["sinks"] if s.get("entry_point_id") in ep_ids],
        "guards": [g for g in ir["guards"] if g.get("entry_point_id") in ep_ids],
        "anomalies": [a for a in ir["anomalies"] if a.get("entry_point_id") in ep_ids],
        "unresolved_hooks": [],  # handled by Agent D, not per-group
        "coverage_gaps": {},     # handled by Agent D
    }
```

---

## 7. Phase 2: Multi-Agent (Codex GPT-5.3-Codex)

### 7.1. Agent A — Entry Point Group Analysis

Chạy NHIỀU sessions, mỗi session một EP group:
- **A1:** AJAX unauth (`ajax_nopriv`, `admin_post_nopriv`) — highest priority, unauthenticated
- **A2:** AJAX auth (`ajax_priv`, `admin_post`) — subscriber+ access
- **A3:** REST routes — permission_callback based auth
- **A4:** Shortcodes + blocks — contributor+ access
- **A5:** Other (cron, init, template_redirect, security filters)

Mỗi session nhận:
- IR slice (filtered cho group)
- Source code (chỉ files referenced trong IR slice)
- Semgrep hits (filtered cho relevant files)
- Threat context (`-threat-context.json`)

Output: structured JSON findings per schema.

**Group theo entry point type vì:** mỗi agent có complete context. KHÔNG group theo function (graph/taint/trace) — agent "graph" biết structure nhưng thiếu vulnerability context, agent "trace" biết path nhưng thiếu structural context.

### 7.2. Agent B — Stored/Cross-EP Flows

Input: **Full IR** (tất cả EPs) + source code.

Focus: stored XSS, second-order SQLi — vulnerability class data flow spans NHIỀU entry points.

```
Pattern: EP_A (write) → option/meta storage → EP_B (read) → dangerous sink
```

Sau IR-07 fix, IR có `option_read`/`meta_read` sources VÀ `option_update`/`meta_update` sinks cả hai với `key` field → Agent B có ground truth cho key matching.

Tasks:
1. Map storage writes: which EPs write with user input?
2. Map storage reads: which EPs read and use in sinks?
3. Match write → read by key (literal: exact. Dynamic: REVIEW)
4. Verify attacker reachability (auth level of write EP)
5. Check sanitization at write AND read time

**KHÔNG duplicate Agent A work.** Chỉ cross-EP flows.

### 7.3. Agent C — Anomaly Deep Dive

Input: AnomalyRules anomalies + source code.

AnomalyRules (10 rules) detect structural patterns nhưng KHÔNG verify exploitability. Agent C verify từng anomaly trong source code.

Quick, focused sessions. One anomaly = one finding output.

### 7.4. Agent D — Unresolved Hooks + Coverage Gaps

Input:
- `unresolved_hooks` từ IR (IR-01 fix output)
- `coverage_gaps` từ IR (A-01 fix output)
- Source code

**Đây là agent khác với IR gap fixes.** IR-01 fix chỉ LOG unresolved hooks. Agent D RESOLVE chúng bằng cách trace source code — ví dụ: tìm `$this->action_name = 'do_search'` trong constructor → resolve hook thành `wp_ajax_do_search` → analyze giống Agent A.

Coverage gaps: investigate tại sao file có `wp_verify_nonce` nhưng no entry point? Dead code? Template include? Standalone form handler?

**Tại sao Agent D thay vì Phase 1 Codex Enhancement:**
- Phase 1 HOÀN TOÀN deterministic — giữ nguyên tắc
- Agent D output findings (giống other agents) → merge bình thường
- Unresolved hooks thường ít (5-15 per plugin) → lightweight

---

## 8. Phase 2.5: Deterministic Merge

**Python script. KHÔNG LLM.**

Script: `tools/bin/merge_agent_outputs.py`

```python
def merge_agent_findings(agent_outputs: list[dict]) -> dict:
    """
    1. Load all agent outputs
    2. Schema validate each (reject malformed, log error)
    3. Group findings by dedup key:
       - Single-EP: (entry_point_id, sink_file, sink_line ±5, vuln_type)
       - Stored/cross-EP: (store_entry_point_id, load_entry_point_id, storage_key, vuln_type)
    4. Single finding → keep as-is
    5. Duplicates (same key, same verdict) → merge evidence, keep highest confidence,
       count agreements in 'agent_agreement' field
    6. Conflicts (same key, different verdict) → preserve BOTH, flag conflict=True,
       include conflicting_verdicts list
    7. Schema validate merged output
    8. Compute merge_stats: total_findings, duplicates_merged, conflicts_flagged,
       agents_missing, schema_errors
    """
```

**Tại sao KHÔNG LLM:**
- LLM khi merge sẽ drop nuance từ individual agent reasoning
- LLM có thể hallucinate connections giữa unrelated findings
- LLM không reliably distinguish duplicate vs distinct findings
- Deterministic dedup by structured keys = reproducible + auditable

---

## 9. Phase 2.9: Claude Code Verify

Input: `-phase2-merged.json` (structured, 2-5KB) — KHÔNG raw source code.

Job:
- Check merge_stats: high conflict rate? Missing agents?
- Spot-check top-N (3-5) highest-severity findings: reasoning coherent? file:line plausible?
- Resolve conflicts: read both agents' reasoning, decide verdict
- Flag obvious errors for re-run

**Token savings:** Claude Code nhận structured JSON, không đọc source code (trừ conflict resolution). 70-80% reduction vs full analysis.

Output: Claude Code verify step **overwrites** `reports/<slug>-phase2.json` (backup trước đó lưu thành `-phase2-pre-verify.json`). Gate vẫn đọc `-phase2.json` — không cần thay đổi file input path.

---

## 10. Phase 3: Gate + Report

**Phase 3 gate:** Gate vẫn đọc `-phase2.json` (không cần `--phase2-input` argument mới).

**Tuy nhiên, gate CẦN code change cho stored flows (G-05):** Khi multi-agent deploy (Step 4), Agent B produce findings với `store_entry_point_id`. Gate hiện chỉ resolve một `entry_point_id` — cần thêm logic: khi finding có `store_entry_point_id`, resolve CẢ HAI EPs, check write-leg auth/guards. Đây là code change trong `phase3_gate.py`, deploy CÙNG LÚC Step 4. Xem `GAP-ANALYSIS.md` gap G-05 cho chi tiết.

**Phase 3 LLM skeptic:** default `off` nếu Phase 2 multi-agent quality đủ tốt. Enable `auto` khi cần (edge cases, high-value plugins).

---

## 11. Orchestration

### File-Based Handoff

```
1. Claude Code writes dispatch config:
   reports/<slug>-dispatch.json
   {
     "slug": "plugin-name",
     "agents": ["agent-a1", "agent-a2", "agent-b", "agent-c", "agent-d"],
     "inputs": {
       "agent-a1": "reports/<slug>-ir-slice-ajax-unauth.json",
       "agent-b": "reports/<slug>-ir.json",
       ...
     },
     "source_dir": "plugins/<slug>/",
     "timeout_seconds": 900
   }

2. Bash orchestrator reads dispatch, launches Codex CLI:
   tools/bin/orchestrate-agents.sh <slug>
   - Parallel execution where quota allows
   - Sequential fallback khi quota limited

3. Each agent writes output:
   reports/<slug>-agent-a1.json
   reports/<slug>-agent-a2.json
   ...

4. Bash polls completion (check output files exist + valid JSON)

5. Python merge:
   python3 tools/bin/merge_agent_outputs.py <slug>
   → reports/<slug>-phase2-merged.json (archive)
   → copies to reports/<slug>-phase2.json (canonical — gate reads this)

6. Signal ready:
   touch reports/<slug>-merge-ready

7. Claude Code reads merged, verifies, overwrites:
   cp reports/<slug>-phase2.json reports/<slug>-phase2-pre-verify.json  # backup merged version
   → overwrites reports/<slug>-phase2.json (with corrections)
   → if verify FAILS/TIMEOUT: -phase2.json from step 5 still exists → gate runs on merged (unverified) output

8. Phase 3 gate runs on -phase2.json (updated by step 7, or merged from step 5 if verify failed)
```

**Claude Code idle = 0 tokens.** Dispatch xong → Claude Code disconnect. Bash monitor. Claude Code reconnect khi ready.

### Dual Mode Support

```
AUTOMATION MODE:
  run-pipeline.sh <slug> --multi-agent
  → Phase 1 → Prep → dispatch → agents (parallel) → merge → verify → gate → report

MANUAL MODE:
  # Step 1: Phase 1
  bash tools/bin/scan-all.sh plugins/<slug>/
  
  # Step 2: Prep
  python3 tools/bin/prepare_agent_inputs.py <slug>
  
  # Step 3: Run agents one by one (quota control)
  codex run agent-a1 <slug>
  codex run agent-a2 <slug>
  # ... check quota, rotate account if needed ...
  codex run agent-b <slug>
  codex run agent-c <slug>
  codex run agent-d <slug>
  
  # Step 4: Merge
  python3 tools/bin/merge_agent_outputs.py <slug>
  
  # Step 5: Verify (uses Claude Code API tokens)
  # ... review merged output, decide whether to spend tokens ...
  
  # Step 6: Gate + Report
  bash tools/bin/run-phase3.sh --slug <slug>
```

---

## 12. Failure Modes

| Condition | Action |
|-----------|--------|
| Agent timeout (>15 min) | Retry 1x. Still fail → skip agent, flag `missing_agent: agent-a2` in merge output |
| Agent malformed JSON | Python merge attempt JSON repair (`json.loads` with error recovery). Fail → reject agent output, log error |
| Agent empty findings | Accept — plugin may be clean for this EP group. Log `agent_empty: true` |
| All agents fail | Fallback: single-agent Phase 2 (current pipeline). Log `multi_agent_fallback: true` |
| Merge conflict rate > 50% | Flag `high_conflict_rate`, escalate: Claude Code does full review instead of spot-check |
| Schema validation fail (agent output) | Reject offending agent, merge remaining. Log which fields failed |
| Claude Code verify fail/timeout | Accept gate output without verify, flag `unverified: true` |
| IR slicing produces empty slice | Skip that agent (no EPs in group). Not an error. |

**All failures logged to:** `reports/logs/<slug>-failures.json`

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

## 13. Validation

### 13.1. Benchmark Set

**Effort acknowledgment:** Populating benchmark ground truth requires manual security review of 10+ plugins. Estimate 2-4 hours per plugin (read code, verify vulns, confirm clean areas). Total: 20-40 hours one-time investment. Đây là effort đáng kể nhưng cần thiết — không có benchmark = không đo improvement.

**Source:** Plugins bạn đã manually verified qua bug bounty work. Existing reports với known TP/FP verdicts.

Minimum: 5 plugins với known vulns + 5 verified clean.

Metrics per pipeline run:
- TP, FP, FN counts (REVIEW findings: not counted as TP or FP; ground truth vuln with only REVIEW = FN)
- Quality Score = TP / (TP + FP + FN)
- Decision Rate = (TP + FP) / (TP + FP + REVIEW_HIT + REVIEW_MISS) — đo pipeline decide vs hedge

**Accept criteria:**
- Multi-agent Quality Score ≥ single-agent baseline trên ALL benchmark plugins
- Decision Rate không giảm quá 10% so với baseline (detect "đẹp số giả" — pipeline hedge thay vì decide)
- Regression trên ANY plugin → investigate trước khi deploy

Chi tiết metric definitions: xem `skill-sets-framework.md` section 2.4.

### 13.2. Codex ≈ Claude Code Quality

Trước multi-agent deploy: 5 plugins, cùng prompt, cả Codex và Claude Code. Compare finding quality per task type. Nếu gap lớn ở specific tasks → route task sang Claude Code (trả thêm tokens nhưng giữ quality).

---

## 14. Migration Path

```
Step 1: Deploy IR code fixes — Wave 1 (GAP-ANALYSIS.md)
  IR-07, IR-01, IR-04, IR-06, IR-08, IR-09, AR-02, P2-03, P2-04, G-04, O-01, O-02, O-03
  → Run current pipeline on benchmark set
  → Record baseline Quality Score

Step 2: Deploy IR code fixes — Wave 2
  IR-03, IR-05, IR-10, P2-01, P2-05, G-01, L-01, A-02
  → Validate: Quality Score ≥ Wave 1 baseline

Step 3: Build multi-agent infrastructure
  ├── tools/bin/prepare_agent_inputs.py (IR slicing)
  ├── tools/bin/merge_agent_outputs.py (deterministic merge)
  ├── tools/bin/orchestrate-agents.sh (dispatch + monitor)
  ├── contracts/*.schema.json (all schemas)
  ├── SKILL SETs for agents A-D + Claude verify
  └── FAILURE-MODES.md, ORCHESTRATION.md

Step 4: Deploy multi-agent Phase 2
  ├── Deploy G-05 code change in phase3_gate.py (stored-flow write-leg auth validation)
  ├── Update Phase 2 prompts: require review_reason, fp_reason (align with schema)
  ├── Run on benchmark set
  ├── Compare: multi-agent Quality Score + Decision Rate vs single-agent
  └── Accept chỉ khi ≥ baseline trên ALL benchmarks

Step 5: Deploy IR code fixes — Wave 3
  IR-02 (call chain depth=2), A-01 (coverage gap report)
  → Agents benefit automatically from improved IR

Step 6: Optimize
  ├── Tune agent prompts based on benchmark results + feedback
  ├── Phase 3 LLM default off nếu Phase 2 quality đủ
  └── Ongoing improvement from feedback loop
```

**Mỗi step validate trước khi proceed. Code fixes TRƯỚC multi-agent.**

---

## 15. Open Decisions

**Document status:** Plan này là **draft cho thảo luận và iterative refinement**. KHÔNG phải build-ready spec. Tất cả open decisions dưới đây PHẢI được locked trước khi chuyển sang implementation (Step 3 trong Migration Path). Mỗi decision cần: choice + rationale + owner.

Cần lock down trước khi build Step 3:

1. **Orchestration mechanism:** File-based handoff (recommended, 0 idle tokens) vs direct Codex CLI (simpler but potential idle cost)?
2. **Agent A session count:** 5 EP groups (ajax-unauth, ajax-auth, rest, shortcode, other) hay consolidate (e.g., merge shortcode+other)?
3. **Claude Code verify depth:** Top-3 hay top-5 findings? Severity threshold (chỉ critical+high)?
4. **Agent prompts:** Reuse Phase 2 prompt (sliced per group) hay write new per-agent?
5. **Quota rotation:** Bao nhiêu Codex accounts trong team? Auto-rotate script hay manual?
6. **Concurrency:** Bao nhiêu agents chạy parallel cùng lúc (phụ thuộc quota per account)?

**Khi tất cả 6 decisions locked → document chuyển status từ DRAFT sang READY FOR IMPLEMENTATION.**
