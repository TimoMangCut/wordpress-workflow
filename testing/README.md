This directory stores generated workflow artifacts that were moved out of the
canonical runtime paths during cleanup.

Current policy:
- `testing/reports/phase1/`: archived Phase 1 outputs
- `testing/reports/phase2/`: archived Phase 2 outputs
- `testing/reports/phase3/`: archived Phase 3 outputs

Artifacts that were considered disposable runtime intermediates were deleted
instead of archived:
- top-level `reports/*.json` and orchestration sidecars
- `reports/logs/*`
- `data/audit.db`

Runtime output paths remain:
- `reports/phase1/`
- `reports/phase2/`
- `reports/phase3/`

These directories are intentionally left empty after cleanup so a fresh run can
regenerate canonical outputs from scratch.
