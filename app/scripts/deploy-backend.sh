#!/usr/bin/env bash
set -euo pipefail

: "${DEPLOY_ENV:?DEPLOY_ENV is required (dev|prod)}"
: "${IMAGE:?IMAGE is required}"
: "${GHCR_USER:?GHCR_USER is required}"
: "${GHCR_PAT:?GHCR_PAT is required}"
: "${FCM_SA_PATH:?FCM_SA_PATH is required}"

REMOTE_DIR="/home/epsilon/infra"
ENV_FILE="/home/epsilon/env/.env.${DEPLOY_ENV}"

# env 파일 존재 검증
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Env file not found: ${ENV_FILE}"
  exit 1
fi

# env 파일 로드 (파일 안 변수들을 현재 쉘 환경변수로 export)
set -a
source "${ENV_FILE}"
set +a

# -----------------------------------------------------------------------------
# Swarm secret 준비
# -----------------------------------------------------------------------------
SECRET_NAME="firebase_sa"
SECRET_FILE="${FCM_SA_PATH}"

if [[ ! -f "${SECRET_FILE}" ]]; then
  echo "FCM service account json not found: ${SECRET_FILE}"
  exit 1
fi

# secret은 생성 후 수정이 불가
# 이미 존재하면 그대로 사용
docker secret inspect "${SECRET_NAME}" >/dev/null 2>&1 || \
  docker secret create "${SECRET_NAME}" "${SECRET_FILE}"

# -----------------------------------------------------------------------------
# GHCR 로그인
# -----------------------------------------------------------------------------
echo "${GHCR_PAT}" | docker login ghcr.io -u "${GHCR_USER}" --password-stdin

# -----------------------------------------------------------------------------
# Nginx conf 교체 및 플랫폼 compose 반영
# -----------------------------------------------------------------------------
CONF_SRC="${REMOTE_DIR}/platform/nginx/conf.d/${DEPLOY_ENV}.conf"
CONF_DST="${REMOTE_DIR}/platform/nginx/conf.d/app.conf"

if [[ ! -f "${CONF_SRC}" ]]; then
  echo "Nginx conf not found: ${CONF_SRC}"
  exit 1
fi

cp "${CONF_SRC}" "${CONF_DST}"

COMPOSE_FILE="${REMOTE_DIR}/platform/docker-compose-platform.${DEPLOY_ENV}.yml"
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "Compose file not found: ${COMPOSE_FILE}"
  exit 1
fi

docker compose -p "platform-${DEPLOY_ENV}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" up -d
docker compose -p "platform-${DEPLOY_ENV}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T nginx nginx -t
docker compose -p "platform-${DEPLOY_ENV}" --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" exec -T nginx nginx -s reload

# -----------------------------------------------------------------------------
# backend stack deploy
# -----------------------------------------------------------------------------
STACK_FILE="${REMOTE_DIR}/app/stack-backend.yml"
if [[ ! -f "${STACK_FILE}" ]]; then
  echo "Stack file not found: ${STACK_FILE}"
  exit 1
fi

export IMAGE
docker stack deploy --with-registry-auth -c "${STACK_FILE}" "${DEPLOY_ENV}"

# -----------------------------------------------------------------------------
# 롤아웃 완료 대기
# -----------------------------------------------------------------------------
SERVICE_NAME="${DEPLOY_ENV}_backend"
TIMEOUT_SEC=600
SLEEP_SEC=5
start_ts="$(date +%s)"

# 스택 deploy 직후에는 service 생성/갱신 반영 타이밍이 있을 수 있어 재시도
for i in {1..20}; do
  docker service inspect "${SERVICE_NAME}" >/dev/null 2>&1 && break
  sleep 1
done

docker service inspect "${SERVICE_NAME}" >/dev/null 2>&1 || {
  echo "Service not found: ${SERVICE_NAME}"
  exit 1
}

desired_replicas="$(docker service inspect -f '{{.Spec.Mode.Replicated.Replicas}}' "${SERVICE_NAME}")"

echo "Waiting for rollout to complete"
echo "service=${SERVICE_NAME}"
echo "desired_replicas=${desired_replicas}"
echo "timeout_sec=${TIMEOUT_SEC}"

while true; do
  now_ts="$(date +%s)"
  elapsed="$((now_ts - start_ts))"

  if [[ "${elapsed}" -ge "${TIMEOUT_SEC}" ]]; then
    echo "Timeout waiting for rollout: ${SERVICE_NAME}"
    docker service ps --no-trunc "${SERVICE_NAME}" || true
    docker service inspect -f '{{json .UpdateStatus}}' "${SERVICE_NAME}" || true
    docker service logs --raw --tail 200 "${SERVICE_NAME}" || true
    exit 1
  fi

  update_state="$(docker service inspect -f '{{if .UpdateStatus}}{{.UpdateStatus.State}}{{else}}none{{end}}' "${SERVICE_NAME}")"
  update_msg="$(docker service inspect -f '{{if .UpdateStatus}}{{.UpdateStatus.Message}}{{else}}no_update_status{{end}}' "${SERVICE_NAME}")"

  case "${update_state}" in
    paused|rollback_started|rollback_paused|rollback_completed)
      echo "Rollout failed"
      echo "update_state=${update_state}"
      echo "update_message=${update_msg}"
      docker service ps --no-trunc "${SERVICE_NAME}" || true
      docker service logs --raw --tail 200 "${SERVICE_NAME}" || true
      exit 1
      ;;
  esac

  running_count="$(docker service ps --filter desired-state=running --format '{{.CurrentState}}' "${SERVICE_NAME}" | grep -c '^Running' || true)"
  non_running_count="$(docker service ps --filter desired-state=running --format '{{.CurrentState}}' "${SERVICE_NAME}" | grep -vc '^Running' || true)"

  if [[ "${non_running_count}" -eq 0 && "${running_count}" -eq "${desired_replicas}" ]]; then
    if [[ "${update_state}" == "completed" || "${update_state}" == "none" ]]; then
      echo "Rollout succeeded"
      echo "update_state=${update_state}"
      echo "running=${running_count}/${desired_replicas}"
      break
    fi
  fi

  echo "Rollout in progress"
  echo "update_state=${update_state}"
  echo "running=${running_count}/${desired_replicas}"
  sleep "${SLEEP_SEC}"
done

docker service ps "${SERVICE_NAME}"
