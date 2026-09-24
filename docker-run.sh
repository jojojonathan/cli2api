#!/usr/bin/env bash
# Build the fork image and (re)start the proxy container with the same name,
# volume, port and environment as the original compose deployment
# (deploy/docker-compose.yml), so the existing deploy_qoder-data volume and
# account data keep working without migration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${CLI2API_IMAGE:-cli2api-fork:latest}"
CONTAINER="${CLI2API_CONTAINER:-qoder-api-proxy}"

echo "==> Building image ${IMAGE}"
docker build \
  -f "${ROOT}/deploy/Dockerfile" \
  --build-arg APP_VERSION="fork-$(git -C "${ROOT}" describe --tags --always 2>/dev/null || echo dev)" \
  --build-arg APP_COMMIT="$(git -C "${ROOT}" rev-parse --short HEAD)" \
  -t "${IMAGE}" \
  "${ROOT}"

echo "==> Removing existing container ${CONTAINER} (if any)"
docker rm -f "${CONTAINER}" >/dev/null 2>&1 || true

echo "==> Starting ${CONTAINER}"
docker run -d \
  --name "${CONTAINER}" \
  --restart unless-stopped \
  --network deploy_default \
  -p 127.0.0.1:3010:3010 \
  -v deploy_qoder-data:/data \
  -v /tmp/cli2api-updater:/run/cli2api-updater:ro \
  --tmpfs /run/cli2api:mode=0700 \
  -e TZ=Asia/Shanghai \
  -e HOST=0.0.0.0 \
  -e PORT=3010 \
  -e QODER_DATA_DIR=/data \
  -e QODER_RUNTIME_DIR=/run/cli2api \
  -e QODER_SSE_DIAGNOSTIC_MODELS= \
  -e QODER_WORKER_BASE_PORT=32100 \
  -e UPDATE_SOCKET_PATH=/run/cli2api-updater/updater.sock \
  -e UPDATE_AGENT_URL= \
  -e UPDATE_AGENT_TOKEN= \
  -e UPDATE_GITHUB_TOKEN= \
  --health-cmd 'curl -fsS http://127.0.0.1:3010/health' \
  --health-interval 10s \
  --health-timeout 3s \
  --health-retries 12 \
  --health-start-period 30s \
  "${IMAGE}"

echo "==> Waiting for health check"
for _ in $(seq 1 45); do
  status="$(docker inspect --format '{{.State.Health.Status}}' "${CONTAINER}" 2>/dev/null || echo unknown)"
  if [ "${status}" = "healthy" ]; then
    echo "==> ${CONTAINER} is healthy on 127.0.0.1:3010 (image: ${IMAGE})"
    exit 0
  fi
  sleep 2
done

echo "!! Health check did not pass within 90s, last logs:" >&2
docker logs --tail 50 "${CONTAINER}" >&2
exit 1
