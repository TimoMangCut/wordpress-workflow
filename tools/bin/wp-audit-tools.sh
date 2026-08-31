#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGE=${WP_AUDIT_TOOLS_IMAGE:-wp-audit-tools:local}

require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker CLI is required to build or run $IMAGE" >&2
    exit 127
  fi
}

usage() {
  cat <<'EOF'
Usage:
  bash tools/bin/wp-audit-tools.sh build
  bash tools/bin/wp-audit-tools.sh versions
  bash tools/bin/wp-audit-tools.sh inventory <plugin-path> [output-dir]
  bash tools/bin/wp-audit-tools.sh search <plugin-path> <pattern> [output-dir]
  bash tools/bin/wp-audit-tools.sh ast <plugin-path> [output-dir]
  bash tools/bin/wp-audit-tools.sh semgrep <plugin-path> [output-dir]
  bash tools/bin/wp-audit-tools.sh psalm <plugin-path> [output-dir]

The plugin is mounted read-only. Run inventory + ast after sealing the source-led
coverage ledger; search, semgrep, and psalm are optional diagnostics. There is no
scanner-first or all-tools mode. Default output is reports/tooling/<plugin-slug>/.
EOF
}

command=${1:-help}
if [[ "$command" == build ]]; then
  require_docker
  docker build -f "$ROOT_DIR/tools/docker/Dockerfile" -t "$IMAGE" "$ROOT_DIR"
  exit 0
fi

if [[ "$command" == versions ]]; then
  require_docker
  docker run --rm --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=256m,mode=1777 \
    "$IMAGE" versions
  exit 0
fi

if [[ "$command" == help || "$command" == -h || "$command" == --help ]]; then
  usage
  exit 0
fi

plugin_arg=${2:-}
if [[ -z "$plugin_arg" ]]; then
  usage >&2
  exit 2
fi

if [[ "$plugin_arg" = /* ]]; then
  plugin_path=$plugin_arg
else
  plugin_path="$ROOT_DIR/$plugin_arg"
fi
if [[ ! -d "$plugin_path" ]]; then
  echo "plugin directory not found: $plugin_path" >&2
  exit 2
fi
plugin_path="$(cd "$plugin_path" && pwd)"
slug="$(basename "$plugin_path")"

case "$command" in
  search)
    pattern=${3:-}
    output_arg=${4:-"reports/tooling/$slug"}
    if [[ -z "$pattern" ]]; then
      echo "search requires a pattern" >&2
      exit 2
    fi
    args=(search "$pattern")
    ;;
  inventory|ast|semgrep|psalm)
    output_arg=${3:-"reports/tooling/$slug"}
    args=("$command")
    ;;
  *)
    echo "unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac

if ! command -v python3 >/dev/null 2>&1; then
  echo "Python 3 is required to validate output mount paths" >&2
  exit 127
fi

if [[ "$output_arg" = /* ]]; then
  output_candidate=$output_arg
else
  output_candidate="$ROOT_DIR/$output_arg"
fi

# Resolve existing symlinks and lexical dot segments without creating the path.
output_path="$(python3 - "$output_candidate" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"

paths_overlap() {
  python3 - "$1" "$2" <<'PY'
import os
import sys

left, right = map(os.path.realpath, sys.argv[1:3])
common = os.path.commonpath((left, right))
sys.exit(0 if common == left or common == right else 1)
PY
}

if paths_overlap "$plugin_path" "$output_path"; then
  echo "output directory must not equal, contain, or be contained by the plugin directory" >&2
  exit 2
fi

require_docker
mkdir -p "$output_path"
output_path="$(cd "$output_path" && pwd -P)"

# Re-check after creation so an existing symlink cannot bypass the intended-path check.
if paths_overlap "$plugin_path" "$output_path"; then
  echo "output directory must not equal, contain, or be contained by the plugin directory" >&2
  exit 2
fi

docker run --rm \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=1g,mode=1777 \
  --tmpfs /opt/wp-audit/reports:rw,noexec,nosuid,size=1g,mode=1777 \
  --tmpfs /opt/wp-audit/data:rw,noexec,nosuid,size=256m,mode=1777 \
  --user "$(id -u):$(id -g)" \
  --mount "type=bind,src=$plugin_path,dst=/workspace/plugin,readonly" \
  --mount "type=bind,src=$output_path,dst=/workspace/output" \
  "$IMAGE" "${args[@]}"
