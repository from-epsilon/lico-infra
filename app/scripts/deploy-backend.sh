#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# 필수 환경변수 검증
# -----------------------------------------------------------------------------
: "${DEPLOY_ENV:?DEPLOY_ENV is required (dev|prod)}"
: "${IMAGE:?IMAGE is required}"
: "${GHCR_USER:?GHCR_USER is required}"
: "${GHCR_PAT:?GHCR_PAT is required}"
: "${FCM_SA_PATH:?FCM_SA_PATH is required}"

REMOTE_DIR="/home/epsilon/infra"
ENV_FILE="/home/epsilon/env/.env.${DEPLOY_ENV}"

DEBUG_DEPLOY="${DEBUG_DEPLOY:-false}"

# -----------------------------------------------------------------------------
# 공통 유틸
# -----------------------------------------------------------------------------
log() {
  echo "[deploy] $*"
}

ensure_swarm_active() {
  local swarm_state
  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
  if [[ "${swarm_state}" != "active" ]]; then
    log "Swarm is not active on this node (state=${swarm_state})."
    log "This deploy requires swarm mode for app/observability stacks."
    exit 1
  fi
}

ensure_platform_network() {
  local network_name="${PLATFORM_NET_NAME}"

  if docker network inspect "${network_name}" >/dev/null 2>&1; then
    local driver attachable
    driver="$(docker network inspect -f '{{.Driver}}' "${network_name}")"
    attachable="$(docker network inspect -f '{{.Attachable}}' "${network_name}")"

    if [[ "${driver}" != "overlay" || "${attachable}" != "true" ]]; then
      log "Network ${network_name} must be overlay + attachable."
      log "Current: driver=${driver}, attachable=${attachable}"
      log "Fix: docker network rm ${network_name} && docker network create --driver overlay --attachable ${network_name}"
      exit 1
    fi
    return 0
  fi

  log "Creating overlay attachable network: ${network_name}"
  docker network create --driver overlay --attachable "${network_name}"
}

enable_trace_if_debug() {
  if [[ "${DEBUG_DEPLOY}" == "true" ]]; then
    export PS4='+ [${BASH_SOURCE}:${LINENO}] '
    set -x
  fi
}

disable_trace() {
  set +x || true
}

# -----------------------------------------------------------------------------
# 시작 로그
# -----------------------------------------------------------------------------
log "begin env=${DEPLOY_ENV}"
log "image=${IMAGE}"
log "env_file=${ENV_FILE}"
log "debug=${DEBUG_DEPLOY}"

# env 파일 존재 검증
if [[ ! -f "${ENV_FILE}" ]]; then
  log "Env file not found: ${ENV_FILE}"
  exit 1
fi

# -----------------------------------------------------------------------------
# env 파일 로드 (시크릿 포함 가능: trace OFF)
# -----------------------------------------------------------------------------
disable_trace
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}"
set +a
enable_trace_if_debug

# ---------------------------------------------------------------------------
# 플랫폼 네트워크 준비
# ---------------------------------------------------------------------------
: "${PLATFORM_NET_NAME:?PLATFORM_NET_NAME is required}"
ensure_swarm_active
ensure_platform_network

# -----------------------------------------------------------------------------
# Swarm secret 준비
# -----------------------------------------------------------------------------
SECRET_NAME="firebase_sa"
SECRET_FILE="${FCM_SA_PATH}"

if [[ ! -f "${SECRET_FILE}" ]]; then
  log "FCM service account json not found: ${SECRET_FILE}"
  exit 1
fi

# secret은 생성 후 수정 불가: 없을 때만 생성
enable_trace_if_debug
docker secret inspect "${SECRET_NAME}" >/dev/null 2>&1 || \
  docker secret create "${SECRET_NAME}" "${SECRET_FILE}"
disable_trace

# -----------------------------------------------------------------------------
# GHCR 로그인 (PAT 노출 방지: trace OFF)
# -----------------------------------------------------------------------------
disable_trace
echo "${GHCR_PAT}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin
enable_trace_if_debug

# -----------------------------------------------------------------------------
# backend stack deploy
# -----------------------------------------------------------------------------
STACK_FILE="${REMOTE_DIR}/app/stack-backend.yml"
if [[ ! -f "${STACK_FILE}" ]]; then
  log "Stack file not found: ${STACK_FILE}"
  exit 1
fi

log "validate rendered stack config"
RENDERED="$(mktemp)"
docker stack config -c "${STACK_FILE}" > "${RENDERED}"

grep -qE '(^|\s)firebase_sa(\s|:)' "${RENDERED}" || {
  log "Rendered stack config does not contain firebase_sa. Check stack-backend.yml and rsync path."
  log "rendered preview (head)"
  sed -n '1,260p' "${RENDERED}"
  rm -f "${RENDERED}"
  exit 1
}

rm -f "${RENDERED}"

log "deploy stack"
enable_trace_if_debug
export IMAGE
docker stack deploy --with-registry-auth -c "${STACK_FILE}" "${DEPLOY_ENV}"
disable_trace

# -----------------------------------------------------------------------------
# 롤아웃 완료 대기 함수
# -----------------------------------------------------------------------------
wait_rollout() {
  local service_name="$1"
  local timeout_sec="${2:-600}"
  local sleep_sec="${3:-5}"

  local start_ts
  start_ts="$(date +%s)"

  # 생성 반영 지연 대비 재시도
  for _ in {1..20}; do
    docker service inspect "${service_name}" >/dev/null 2>&1 && break
    sleep 1
  done

  docker service inspect "${service_name}" >/dev/null 2>&1 || {
    log "Service not found: ${service_name}"
    return 1
  }

  local desired
  desired="$(docker service inspect -f '{{.Spec.Mode.Replicated.Replicas}}' "${service_name}")"

  log "waiting rollout service=${service_name} desired=${desired} timeout=${timeout_sec}s"

  while true; do
    local now_ts elapsed
    now_ts="$(date +%s)"
    elapsed="$((now_ts - start_ts))"

    if [[ "${elapsed}" -ge "${timeout_sec}" ]]; then
      log "Timeout waiting for rollout: ${service_name}"
      docker service ps --no-trunc "${service_name}" || true
      docker service inspect -f '{{json .UpdateStatus}}' "${service_name}" || true
      docker service logs --raw --tail 200 "${service_name}" || true
      return 1
    fi

    local update_state update_msg
    update_state="$(docker service inspect -f '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}' "${service_name}")"
    update_msg="$(docker service inspect -f '{{if .UpdateStatus}}{{.UpdateStatus.Message}}{{else}}no_update_status{{end}}' "${service_name}")"

    case "${update_state}" in
      paused|rollback_started|rollback_paused|rollback_completed)
        log "Rollout failed service=${service_name} update_state=${update_state}"
        log "update_message=${update_msg}"
        docker service ps --no-trunc "${service_name}" || true
        docker service logs --raw --tail 200 "${service_name}" || true
        return 1
        ;;
    esac

    local running_count non_running_count
    running_count="$(docker service ps --filter desired-state=running --format '{{.CurrentState}}' "${service_name}" | grep -c '^Running' || true)"
    non_running_count="$(docker service ps --filter desired-state=running --format '{{.CurrentState}}' "${service_name}" | grep -vc '^Running' || true)"

    if [[ "${non_running_count}" -eq 0 && "${running_count}" -eq "${desired}" ]]; then
      if [[ "${update_state}" == "completed" || "${update_state}" == "none" ]]; then
        log "Rollout succeeded service=${service_name} running=${running_count}/${desired}"
        break
      fi
    fi

    log "Rollout in progress service=${service_name} state=${update_state} running=${running_count}/${desired}"
    sleep "${sleep_sec}"
  done

  docker service ps "${service_name}" || true
  return 0
}

# -----------------------------------------------------------------------------
# backend 롤아웃 대기
# -----------------------------------------------------------------------------
BACKEND_SERVICE="${DEPLOY_ENV}_backend"
wait_rollout "${BACKEND_SERVICE}" 600 5

# -----------------------------------------------------------------------------
# batch 서비스가 있으면 batch도 롤아웃 대기
# -----------------------------------------------------------------------------
BATCH_SERVICE="${DEPLOY_ENV}_batch"
if docker service inspect "${BATCH_SERVICE}" >/dev/null 2>&1; then
  wait_rollout "${BATCH_SERVICE}" 600 5
else
  log "batch service not found (skip): ${BATCH_SERVICE}"
fi

log "done env=${DEPLOY_ENV}"
