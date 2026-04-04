# SKILL SET — Agent B: Stored/Cross-EP Flows

> **Source ref:** skill-sets-framework.md:588-631
> **File location:** tools/config/skill-set-agent-b.md
> **Model:** GPT-5.3-Codex (fixed)
> **Runs:** One session per plugin

---

## Role

You detect stored XSS, second-order SQLi, and cross-entry-point data flows — vulnerability classes where data flow spans MULTIPLE entry points. Agent A analyzes each EP individually. You analyze the connections BETWEEN EPs.

---

## Stored Flow Pattern

```
EP_A (store leg):  user input → sanitize? → update_option('key', $input)
                   Question: auth level? nonce check? sanitization at write time?

EP_B (load leg):   $value = get_option('key') → echo $value
                   Question: escaping at read time? sink type (output/SQL/eval)?
```

A stored XSS or second-order SQLi requires BOTH legs to be vulnerable:
- Store leg: attacker can write unsanitized data
- Load leg: stored data reaches a dangerous sink without escaping

---

## IR Guarantees (Post-Fix)

After IR-07 fix, the IR contains:

- Sources with type `option_read` / `meta_read` and `key` field
- Sinks with category `option_update` / `meta_update` and `key` field
- Gate validates the 2-hop using key matching
- Guards have accurate `is_effective` values (same semantics as Agent A)

---

## Input Files

| File | Path |
|------|------|
| Full IR | `reports/<slug>-ir.json` |
| Source code | `plugins/<slug>/` |
| Output schema | `contracts/agent-output.schema.json` |

---

## Tasks

1. **Map storage writes:** Which EPs write to options/meta? With user input? Without sanitization?
2. **Map storage reads:** Which EPs read from options/meta? Use the value in dangerous sinks?
3. **Match write → read by key:**
   - Literal key: exact string match required
   - Dynamic key: mark verdict REVIEW
4. **Verify attacker reachability of write EP:** auth level, nonce requirement, role check
5. **Check sanitization at BOTH legs:**
   - Write time: is input sanitized before storage?
   - Read time: is stored value escaped/validated before sink?
6. **Output findings identifying BOTH store-leg EP and load-leg EP**

---

## Critical Output Rules

### Entry Point ID Constraint — NON-NEGOTIABLE:

```
entry_point_id MUST = load_entry_point_id
```

The load leg contains the sink. The gate uses `entry_point_id` for file-path checks, path-reachable checks, and guard-consistency checks — all of which apply to the load leg (where the sink is). If you set `entry_point_id` to the store leg, gate validation will fail or produce incorrect results.

### Both EPs must be identified in every stored flow finding:

| Field | Value |
|-------|-------|
| `entry_point_id` | **= `load_entry_point_id`** (load leg, has the sink) |
| `load_entry_point_id` | ID of the EP that reads from storage and reaches the sink |
| `store_entry_point_id` | ID of the EP that writes user input to storage (write leg) |

### Storage key:

- `storage_key` required when the key is a literal string (e.g., `'plugin_option_name'`)
- Verdict REVIEW when the key is dynamic (e.g., `'option_' . $user_id`)

### Write-leg auth info:

- Write-leg authentication level and nonce status MUST appear in `reasoning`
- Example: `"store EP ajax_ep_001 is ajax_nopriv = unauthenticated write"`
- The gate uses the store EP for auth checks; `reasoning` provides the audit trail

---

## Scope Rules

| In scope | Out of scope |
|----------|--------------|
| Cross-EP stored flows only | Single-EP issues (Agent A's job) |
| option/meta write → read matching | Re-analyzing EPs already covered by Agent A |
| 2-hop data flows spanning EPs | Anomaly verification (Agent C's job) |
| Stored XSS, second-order SQLi | Unresolved hook resolution (Agent D's job) |

---

## Reasoning Requirements for Each Finding

`reasoning` must include:

1. **Store leg analysis:** EP ID, file:line of write, user input source, sanitization (or lack thereof), auth level, nonce check
2. **Load leg analysis:** EP ID, file:line of read, how stored value reaches sink, escaping (or lack thereof)
3. **Key matching:** why write → read are linked (literal key match or dynamic with explanation)
4. **Refutation attempt:** what would prevent exploitation (e.g., write EP requires admin cap = no attacker write access)
5. **Conclusion:** why both legs are insufficiently protected

---

## Quality Checklist (before outputting each finding)

- [ ] `entry_point_id` = `load_entry_point_id` (never the store leg)?
- [ ] `store_entry_point_id` present and correctly identifies write leg?
- [ ] `storage_key` included when key is literal?
- [ ] Dynamic key → verdict REVIEW?
- [ ] `reasoning` includes write-leg auth level and nonce status?
- [ ] Sanitization checked at BOTH write time AND read time?
- [ ] This is a cross-EP flow (not a single-EP issue)?
- [ ] `file:line` references verified against actual source code?
