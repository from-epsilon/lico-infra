#!/usr/bin/env bash
set -euo pipefail

OBS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OBSERVABILITY_DIR="$OBS_DIR"

STACK_NAME="${STACK_NAME:-observability}"
CONFIG_VERSION="${CONFIG_VERSION:-$(date +%s)}"
CONFIG_VERSION="${CONFIG_VERSION:0:12}"
export CONFIG_VERSION

TEMPO_UID="${TEMPO_UID:-10001}"
export TEMPO_UID

TEMPO_CHOWN="${TEMPO_CHOWN:-true}"
if [[ "${TEMPO_UID}" != "0" && "${TEMPO_CHOWN}" == "true" ]]; then
  VOLUME_NAME="${STACK_NAME}_tempo_data"
  if ! docker volume inspect "${VOLUME_NAME}" >/dev/null 2>&1; then
    docker volume create "${VOLUME_NAME}" >/dev/null
  fi
  docker run --rm -v "${VOLUME_NAME}:/var/lib/tempo" alpine sh -c "chown -R ${TEMPO_UID}:${TEMPO_UID} /var/lib/tempo"
fi

docker stack deploy -c "$OBS_DIR/stack-observability.yml" "$STACK_NAME"
