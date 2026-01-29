#!/usr/bin/env bash
set -euo pipefail

OBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OBSERVABILITY_DIR="$OBS_DIR"

ENV_FILE_DEFAULT="/home/epsilon/env/.env.${APP_ENV:-dev}"
ENV_FILE="${ENV_FILE:-$ENV_FILE_DEFAULT}"

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  . "${ENV_FILE}"
  set +a
else
  echo "[deploy] ENV file not found: ${ENV_FILE} (skipping load)"
fi

STACK_NAME="${STACK_NAME:-observability}"
CONFIG_VERSION="${CONFIG_VERSION:-$(date +%s)}"
CONFIG_VERSION="${CONFIG_VERSION:0:12}"
export CONFIG_VERSION

docker stack deploy -c "$OBS_DIR/stack-observability.yml" "$STACK_NAME"
