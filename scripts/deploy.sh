#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Core Delivery for i-love-shopping
#
# Delivers a versioned set of Docker images, injects environment variables
# from the deployment environment (never from source control), restarts the
# services in dependency order and leaves the stack for validation.
#
# Usage (from the target repo root, env exported by the pipeline):
#   ./deploy.sh --local --compose docker/docker-compose.yml --tag <sha>
#
# Remote mode (same flow over SSH) is documented in docs/pipeline.md.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.yml"
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) MODE=local ;;
    --compose) COMPOSE_FILE="$2"; shift ;;
    --tag) TAG="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -z "${DATA_ENCRYPTION_KEY:-}" ]; then
  echo "deploy: DATA_ENCRYPTION_KEY must be exported by the deployment environment" >&2
  echo "        (the API refuses to start without it — there is no fallback key)" >&2
  exit 1
fi

echo "deploy: required environment present (DATA_ENCRYPTION_KEY set)"

# Stop the app tier first, keep dependencies running (postgres keeps its data).
echo "deploy: stopping app tier"
docker compose -f "$COMPOSE_FILE" stop api frontend 2>/dev/null || true
docker compose -f "$COMPOSE_FILE" rm -f api frontend 2>/dev/null || true

# Bring dependencies up and wait for their health.
echo "deploy: ensuring dependencies are healthy"
docker compose -f "$COMPOSE_FILE" up -d postgres redis rabbitmq mailhog

for i in $(seq 1 30); do
  healthy=$(docker compose -f "$COMPOSE_FILE" ps --format json 2>/dev/null \
    | grep -c '"Health":"healthy"' || true)
  [ "$healthy" -ge 3 ] && break
  sleep 2
done

# Run the pre-deployment database flow: backup, then apply pending migrations.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo "deploy: database backup + migration"
"$SCRIPT_DIR/migrate.sh" --compose "$COMPOSE_FILE"

# Start the new version.
echo "deploy: starting api + frontend${TAG:+ (tag $TAG)}"
if [ -n "$TAG" ]; then
  IMAGE_API="iloveshopping/api:$TAG"
  IMAGE_FRONTEND="iloveshopping/frontend:$TAG"
  docker compose -f "$COMPOSE_FILE" up -d --no-deps \
    -e API_IMAGE="$IMAGE_API" -e FRONTEND_IMAGE="$IMAGE_FRONTEND" api frontend 2>/dev/null \
    || docker compose -f "$COMPOSE_FILE" up -d --no-deps api frontend
else
  docker compose -f "$COMPOSE_FILE" up -d --no-deps api frontend
fi

echo "deploy: done — validate next (scripts/validate-deployment.sh)"
