#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_NAME:?PROJECT_NAME is required}"
: "${COMPOSE_FILE:?COMPOSE_FILE is required}"
: "${ENV_FILE:?ENV_FILE is required}"

LEGACY_CERTBOT_DIR="${LEGACY_CERTBOT_DIR:-/home/epsilon/infra/platform/certbot}"
LEGACY_CONF_DIR="${LEGACY_CERTBOT_DIR}/conf"
LEGACY_WWW_DIR="${LEGACY_CERTBOT_DIR}/www"

log() {
  echo "[migrate-certbot] $*"
}

compose_run() {
  docker compose \
    -p "${PROJECT_NAME}" \
    --env-file "${ENV_FILE}" \
    -f "${COMPOSE_FILE}" \
    run --rm -T --no-deps "$@"
}

migrate_dir_if_needed() {
  local legacy_dir="$1"
  local target_dir="$2"
  local label="$3"

  if [[ ! -d "${legacy_dir}" ]]; then
    log "skip ${label}: legacy directory not found (${legacy_dir})"
    return 0
  fi

  compose_run \
    --entrypoint sh \
    --volume "${legacy_dir}:/legacy:ro" \
    certbot \
    -eu -c '
      label="$1"
      target="$2"

      if [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
        echo "[migrate-certbot] skip ${label}: target already has data"
        exit 0
      fi

      if [ -z "$(ls -A /legacy 2>/dev/null)" ]; then
        echo "[migrate-certbot] skip ${label}: legacy source is empty"
        exit 0
      fi

      cp -a /legacy/. "${target}/"
      echo "[migrate-certbot] migrated ${label} from legacy bind path"
    ' sh "${label}" "${target_dir}"
}

if [[ ! -d "${LEGACY_CONF_DIR}" && ! -d "${LEGACY_WWW_DIR}" ]]; then
  log "skip: no legacy certbot directories found under ${LEGACY_CERTBOT_DIR}"
  exit 0
fi

migrate_dir_if_needed "${LEGACY_CONF_DIR}" "/etc/letsencrypt" "conf"
migrate_dir_if_needed "${LEGACY_WWW_DIR}" "/var/www/certbot" "www"
