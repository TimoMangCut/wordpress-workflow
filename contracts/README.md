# contracts/ — Schema Versioning Rules

Contracts in this directory define the data interfaces between pipeline stages.
All pipeline scripts validate against these schemas before passing data downstream.
Schema mismatch is a hard error — silent degradation is prohibited.

---

## Schema Files

| File | Version | Produced by | Consumed by |
|------|---------|-------------|-------------|
| `ir-output.schema.json` | 2.0.0 | `tools/bin/extract.php` | `tools/bin/prepare_agent_inputs.py`, agents |
| `ir-slice.schema.json` | 1.0.0 | `tools/bin/prepare_agent_inputs.py` | Agents A1–A5 |
| `agent-output.schema.json` | 1.0.0 | Agents A1–A5, B, C, D | merge script |
| `merge-output.schema.json` | 1.0.0 | merge script | phase3 gate |
| `phase3-gate-input.schema.json` | 1.0.0 | (same shape as merge-output) | `tools/bin/phase3_gate.py` |
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

### ir-output.schema.json stub → 2.0.0

Date: 2026-04-04 (Session 15)
Breaking: replaced informal stub (`ir.schema.json`) with full draft-07 schema.
Fields added to required: all top-level IR fields including `unresolved_hooks` (IR-01) and `coverage_gaps` (A-01).
Migration: old stub (`ir.schema.json`) is superseded — update any reference to point to `ir-output.schema.json`.

### finding.schema.json / threat-context.schema.json

Status: stubs pending full expansion. Verdict enum in `finding.schema.json` uses AppSec review states (`CONFIRMED`, `UNCERTAIN`, `RISK_NOTE`, `REJECTED`) — distinct from agent-output verdict enum (`TP`, `FP`, `REVIEW`). These are different schemas for different audiences. Do not conflate.
