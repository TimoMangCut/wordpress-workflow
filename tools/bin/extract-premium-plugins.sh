#!/bin/bash
set -euo pipefail

BIN_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${BIN_DIR}/../.." && pwd)"

python3 "${BIN_DIR}/extract-premium-plugins.py" "$@"

