# benchmark/

Pipeline quality benchmark — compares phase3 output against manual ground truth.

## Structure

```
benchmark/
├── compare.py              # Benchmark runner (Session 0)
├── README.md               # This file
├── ground-truth/           # Manual ground truth per plugin
│   ├── cartflows.json
│   ├── pretty-link.json
│   └── backwpup.json
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

## Accept Criteria (from skill-sets-framework.md:427-430)

- Quality Score ≥ previous baseline on ALL benchmark plugins
- Decision Rate does not drop more than 10% vs baseline
