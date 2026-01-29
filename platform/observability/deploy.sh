#!/usr/bin/env bash
set -euo pipefail

OBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OBSERVABILITY_DIR="$OBS_DIR"

STACK_NAME="${STACK_NAME:-observability}"
CONFIG_VERSION="${CONFIG_VERSION:-$(date +%s)}"

docker stack deploy -c "$OBS_DIR/stack-observability.yml" "$STACK_NAME"
