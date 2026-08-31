#!/usr/bin/env bash
# Run the PHP IR-extractor regression harness inside the audit Docker image.
#
# The extractor is the independent corroboration source the review methodology reconciles
# against; a silent regression there degrades recall without any signal. This harness locks
# its behaviour. It runs entirely in Docker (no local PHP/composer): the live extractor source
# (tools/src) and the tests (tools/tests-php) are mounted over the baked image, so it tests the
# CURRENT code without a rebuild.
#
# Usage: bash tools/bin/run-extractor-tests.sh
# Exit 0 = all checks green, 1 = a regression, 2 = image missing.
set -euo pipefail

IMAGE="${WP_AUDIT_IMAGE:-wp-audit-tools:local}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "error: image '$IMAGE' not found. Build it first: bash tools/bin/wp-audit-tools.sh build" >&2
  exit 2
fi

exec docker run --rm \
  -v "$REPO_ROOT/tools/src:/opt/wp-audit/tools/src:ro" \
  -v "$REPO_ROOT/tools/tests-php:/opt/wp-audit/tools/tests-php:ro" \
  --entrypoint php "$IMAGE" \
  /opt/wp-audit/tools/tests-php/extract_regression.php \
  /opt/wp-audit/tools/tests-php/fixtures
