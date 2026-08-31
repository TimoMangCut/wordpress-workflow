# contracts/ — Review and Legacy Schema Versioning

Contracts in this directory now cover two authorities:

- `methodology-review.schema.json` is the canonical output contract for the source-first IDE review.
- Phase/agent schemas are legacy interfaces retained for historical pipeline reproduction.

A consumer must validate the contract it explicitly uses. File presence or a legacy phase schema does not make an artifact authoritative for the methodology workflow.

---

## Schema Files

| File | Version | Produced by | Consumed by |
|------|---------|-------------|-------------|
| `methodology-review.schema.json` | 1.1.0 | Single-agent methodology review (Kiro/Claude/Codex/Antigravity) | IDE report, optional persistence/resume |
| `ir-output.schema.json` | 2.3.0 | `tools/bin/extract.php` | legacy prep, required structural evidence for methodology reconciliation |
| `ir-slice.schema.json` | 1.3.0 | `tools/bin/prepare_agent_inputs.py` | Agents A1–A5 |
| `agent-output.schema.json` | 1.0.0 | Agents A1–A5, B, C, D | merge script |
| `phase2-finding.schema.json` | 1.1.0 | Phase 2 agents (item schema) | merge script, gate |
| `merge-output.schema.json` | 1.0.0 | merge script | phase3 gate |
| `phase3-gate-input.schema.json` | 1.0.0 | (same shape as merge-output) | `tools/bin/phase3_gate.py` |
| `phase3-gate-output.schema.json` | 1.0.0 | `tools/bin/phase3_gate.py` | reporting, downstream |
| `finding.schema.json` | stub | AppSec reviewer | manual review |
| `threat-context.schema.json` | stub | threat-context script | phase2 agents |

---

## Versioning — Semver

Schema versions follow **semantic versioning (MAJOR.MINOR.PATCH)**:

```
MAJOR — breaking change (existing consumers must be updated)
MINOR — additive change (new optional field; backwards-compatible)
PATCH — clarification only (description, comment, no field change)
```

### Breaking change (MAJOR bump required)

Any of the following requires a MAJOR version bump:

- Removing a field that is currently in `required[]`
- Renaming a field
- Changing a field's type (e.g., `string` → `integer`)
- Removing a value from an `enum`
- Adding a new field to `required[]` without a default

### Non-breaking change (MINOR bump)

- Adding a new optional field (not in `required[]`)
- Adding a new value to an `enum`
- Making a required field optional (removing it from `required[]`)

### No-op (PATCH bump)

- Updating `description` text
- Adding or editing `_comment` fields
- Reformatting JSON (whitespace, key order)

---

## Migration Policy

When a MAJOR version bump is made:

1. **Update `version` field** in the schema file.
2. **Add a migration note** to this README under the `## Migration Log` section (see below).
3. **Update all consumers** before merging — do not leave a pipeline stage on an old schema version.
4. **Tag the old version** in git if the old format needs to be reproduced (e.g., for historical benchmark runs).

Migration note format:
```
### ir-output.schema.json 1.x → 2.0.0
Date: YYYY-MM-DD
Breaking: <what changed>
Migration: <what consumers must do>
```

---

## Adding a New Schema

1. Create the file in `contracts/` following the draft-07 format.
2. Set `version` to `"1.0.0"`.
3. Add a row to the table above.
4. Document the producer and consumer in the table.

---

## Validation in Scripts

Python consumers use `jsonschema` (draft-07):

```python
import json, jsonschema

with open("contracts/agent-output.schema.json") as f:
    schema = json.load(f)

jsonschema.validate(instance=output, schema=schema)
# Raises jsonschema.ValidationError on mismatch — do not catch silently
```

PHP consumers (extractor) validate IR shape at runtime via internal checks,
not via this schema library. IR schema is the ground-truth reference.

---

## Migration Log

### Methodology review 1.0.0 → 1.1.0

Date: 2026-09-01
Minor (additive, backward-compatible — 1.0.0 outputs still validate; `schema_version` accepts `1.0.0` or `1.1.0`).
Added optional fields for single-agent recall of WordPress-specific finding classes:
- `finding.storage_link` (`{store_surface_id, load_surface_id, storage_key, key_resolution?, store_auth_required?}`) — first-class anchoring for stored/second-order two-hop flows (stored XSS, second-order SQLi), scoring reachability on the write leg.
- `surface.auth_required` — normalized privilege enum (`none|subscriber|contributor|author|editor|admin|system|unknown`, same ladder as the legacy pipeline's `normalize_auth`) for comparable severity-by-privilege.
- `surface.resolution_confidence` (`high|medium|low`) — honesty signal for dynamically-resolved (`UNRESOLVED`→resolved) hooks.

### Methodology review 1.0.0

Date: 2026-08-28
Added: `methodology-review.schema.json` as the canonical unified review contract.
- Replaces Phase 2 `TP|FP|REVIEW` and Phase 3 gate translation in the default IDE workflow.
- Uses `CONFIRMED|UNCERTAIN|RISK_NOTE|REJECTED` directly.
- Keeps coverage, refutations, tool diagnostics, and post-verdict reportability explicit.
- Legacy schemas remain unchanged for historical pipeline reproduction.

### ir-output.schema.json 2.2.0 → 2.3.0

Date: 2026-04-04 (Session 15 post-review round 3, Codex finding P1)
Breaking: NO — MINOR bump. sources[].entry_point_id and sinks[].entry_point_id made nullable.
- Both fields were `required: string`. Actual IR has 2096 sources and 25494 sinks with entry_point_id=null (file-level items not tied to any entry point). Verified across ALL reports/phase1/*-ir.json.
- Guards and anomalies checked: 0 null entry_point_id — those fields remain required string.
- entry_point_id removed from required[] for sources and sinks (it is still present as a nullable property).
Migration: NO consumer existed yet.

### ir-slice.schema.json 1.2.0 → 1.3.0

Date: 2026-04-04 (Session 15 post-review round 3)
Breaking: NO — MINOR bump. sources[].entry_point_id and sinks[].entry_point_id made nullable to match ir-output 2.3.0.
Note: slice_ir_for_group() filters sources/sinks by entry_point_id membership, so in practice null-entry_point_id items will not appear in slices. Schema kept nullable for consistency and defensive validation.

### phase2-finding.schema.json 1.0.0 → 1.1.0

Date: 2026-04-04 (Session 15 post-review round 3, Codex finding P2)
Breaking: NO — MINOR bump. Added stored/cross-EP allOf conditional.
- phase2-finding claimed to mirror agent-output finding item schema but was missing the 4th allOf conditional (store_entry_point_id → require load_entry_point_id + storage_key + entry_point_id). Canonical source: skill-sets-framework.md:275-288.

### ir-output.schema.json 2.1.0 → 2.2.0

Date: 2026-04-04 (Session 15 post-review round 2, Codex finding P1)
Breaking: NO — MINOR bump. Added `static_method` and `function` callback types.
- Previous fix (2.1.0) only surveyed 2 artifacts (backwpup, call-chain-test), missing `function` in cartflows-ir.json and `static_method` in pretty-link-ir.json.
- Full survey of ALL reports/phase1/*-ir.json confirmed 5 types: method, static_method, function, closure, unresolved.
- `function` type: file/line_start/line_end nullable (built-in WP functions have no source file in repo).
Migration: NO consumer existed yet.

### ir-slice.schema.json 1.1.0 → 1.2.0

Date: 2026-04-04 (Session 15 post-review round 2)
Breaking: NO — MINOR bump. Added `static_method` and `function` callback types to match ir-output 2.2.0.

### ir-output.schema.json 2.0.0 → 2.1.0

Date: 2026-04-04 (Session 15 post-review, Codex findings P1)
Breaking: NO — MINOR bump. callback was changed from `string` to `oneOf` discriminated union; unresolved_hooks item shape corrected to match actual extractor output.
- `entry_points[].callback`: changed from `{"type":"string"}` to `oneOf[method|closure|unresolved]` object. Verified against backwpup-ir.json and call-chain-test-ir.json artifacts. Session 15 schema was wrong — extractor emits callback objects, never strings.
- `unresolved_hooks[]` items: changed required fields from `[hook_name, callback]` to `[file, line, function, hook_arg_type]`. Matches actual extractor output (backwpup-ir.json, 36 items). Old schema required fields that do not exist in any artifact.
Migration: NO consumer existed yet (Session 16 IR slicing not yet written). No migration steps needed.

### ir-slice.schema.json 1.0.0 → 1.1.0

Date: 2026-04-04 (Session 15 post-review)
Breaking: NO — MINOR bump. callback field in entry_points corrected to match ir-output 2.1.0 shape.

### Session 15 post-review additions

Date: 2026-04-04
Added: `phase2-finding.schema.json` (v1.0.0) — standalone finding item schema per skill-sets-framework.md:121.
Added: `phase3-gate-output.schema.json` (v1.0.0) — gate output contract per skill-sets-framework.md:125.
These were listed in source_ref but omitted from Session 15 initial output.

### ir-output.schema.json stub → 2.0.0

Date: 2026-04-04 (Session 15)
Breaking: replaced informal stub (`ir.schema.json`) with full draft-07 schema.
Fields added to required: all top-level IR fields including `unresolved_hooks` (IR-01) and `coverage_gaps` (A-01).
Migration: old stub (`ir.schema.json`) is superseded — update any reference to point to `ir-output.schema.json`.

### finding.schema.json / threat-context.schema.json

Status: stubs pending full expansion. Verdict enum in `finding.schema.json` uses AppSec review states (`CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, `REJECTED`) — distinct from agent-output verdict enum (`TP`, `FP`, `REVIEW`). These are different schemas for different audiences. Do not conflate.
