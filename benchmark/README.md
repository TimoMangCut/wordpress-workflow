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
│   ├── pretty-link.json    # verified_by: pipeline_derived  (regression reference)
│   └── backwpup.json       # verified_by: pipeline_derived  (regression reference)
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

Where:
- `TP` = a `CONFIRMED` pipeline finding matching GT
- `FP` = a `CONFIRMED` pipeline finding not matching GT
- `FN` = a GT finding not matched by any `CONFIRMED` pipeline finding
- `REVIEW_HIT` = an `UNCERTAIN` / `RISK_NOTE` pipeline finding that matches GT but remains unresolved
- `REVIEW_MISS` = an `UNCERTAIN` / `RISK_NOTE` pipeline finding that does not match GT
- `REJECTED` = closed findings excluded from QS and DR denominators

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
- `cartflows.json` — `manual_review`, GT=2. Independent evaluation anchored to two manually re-traced findings.
- `pretty-link.json` — `pipeline_derived`, GT=0. Regression reference only; current clean state is not a full independent clean certification.
- `backwpup.json` — `pipeline_derived`, GT=0. Regression reference only; current strict gate leaves the custom-cap REST BAC cluster unresolved rather than independently confirmed.

The accept criteria below apply to all plugins, but QS comparisons are only meaningful as independent evaluations for `manual_review` GT files.

## Accept Criteria (from skill-sets-framework.md:427-430)

- Quality Score ≥ previous baseline on ALL benchmark plugins
- Decision Rate does not drop more than 10% vs baseline
