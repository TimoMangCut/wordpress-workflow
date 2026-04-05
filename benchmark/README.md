# benchmark/

Pipeline quality benchmark — compares phase3 output against ground truth.

**Benchmark semantics vary by plugin** — see `ground-truth/` section below for details.

## Structure

```
benchmark/
├── compare.py              # Benchmark runner (Session 0)
├── README.md               # This file
├── ground-truth/           # Ground truth per plugin (semantics vary — see below)
│   ├── cartflows.json      # verified_by: manual_review  (independent GT)
│   ├── pretty-link.json    # verified_by: manual_review  (independent GT)
│   └── backwpup.json       # verified_by: pipeline_derived  (self-consistency reference)
└── results/
    ├── baseline.json       # Current baseline (auto-created on first run)
    └── run_<timestamp>.json
```

## Usage

```bash
# Single plugin
python3 benchmark/compare.py cartflows

# All plugins with ground truth
python3 benchmark/compare.py --all

# All plugins + save as new baseline
python3 benchmark/compare.py --all --save-baseline
```

## Metrics

- **Quality Score** = TP / (TP + FP + FN)
- **Decision Rate** = (TP + FP) / (TP + FP + REVIEW_HIT + REVIEW_MISS)

See `skill-sets-framework.md:412-433` for full definitions and accept criteria.

## Ground Truth Schema

See `skill-sets-framework.md:373-409` for canonical schema.
Fields: `plugin_slug`, `plugin_version`, `verified_by`, `verified_date`, `findings[]`, `confirmed_clean_areas[]`

### `verified_by` values and benchmark semantics

| `verified_by` | Meaning | QS interpretation |
|---|---|---|
| `manual_review` | Findings confirmed by independent human code audit or exploit attempt. Independent GT. | QS measures pipeline accuracy against real ground truth. |
| `pipeline_derived` | Findings are the pipeline's own CONFIRMED output, promoted to reference data. Not independently verified. | QS measures pipeline self-consistency (regression detection). Does **not** measure independent accuracy. |

**Current state (Wave 4):**
- `cartflows.json` — `manual_review`, GT=0 (no real vulnerabilities found). QS=N/A. Independent evaluation.
- `pretty-link.json` — `manual_review`, GT=0 (no real vulnerabilities found). QS=N/A. Independent evaluation.
- `backwpup.json` — `pipeline_derived`, GT=9. **QS=1.0 is a self-consistency metric**, not independent validation. The 9 findings are the Session 30 gate CONFIRMED output; the benchmark confirms the pipeline produces the same findings on re-run. Independent verification (manual exploit attempt) is required before treating these as confirmed vulnerabilities.

The accept criteria below apply to all plugins, but QS comparisons are only meaningful as independent evaluations for `manual_review` GT files.

## Accept Criteria (from skill-sets-framework.md:427-430)

- Quality Score ≥ previous baseline on ALL benchmark plugins
- Decision Rate does not drop more than 10% vs baseline
