# tools/updated-scripts — LEGACY / STAGING ONLY

**Canonical scripts live in `tools/bin/`.** This directory is NOT used by any active pipeline.

## Origin

This directory was created as a staging area during early pipeline development.
It contains older versions of scripts that have since been superseded by the
versions in `tools/bin/`.

## Status

| File | Canonical version | Notes |
|------|------------------|-------|
| `bin/run-phase3.sh` | `tools/bin/run-phase3.sh` | Canonical has `--llm-mode`, `report-paths.sh` integration |
| `bin/run-phase2.sh` | `tools/bin/run-phase2.sh` | Canonical |
| `bin/run-pipeline.sh` | `tools/bin/run-pipeline.sh` | Canonical |
| `bin/scan-all.sh` | `tools/bin/scan-all.sh` | Canonical |
| `bin/batch.sh` | `tools/bin/batch.sh` | Canonical |
| `config/progpilot-wp.json` | `tools/config/progpilot-wp.json` | Canonical |

## Do not use these files for development or debugging.

If you are looking for the active pipeline, use `tools/bin/`.
This directory will be removed in a future cleanup pass.
