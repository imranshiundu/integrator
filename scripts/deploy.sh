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

# Deterministic injection: write the deployment environment into an
# --env-file so docker compose always interpolates it, regardless of how
# the caller invoked this script.
COMPOSE_DIR="$(dirname "$COMPOSE_FILE")"
DEPLOY_ENV="$COMPOSE_DIR/.env.deployment"
{
  echo "DATA_ENCRYPTION_KEY=$DATA_ENCRYPTION_KEY"
  [ -n "${JWT_ACCESS_SECRET:-}" ] && echo "JWT_ACCESS_SECRET=$JWT_ACCESS_SECRET"
  [ -n "${JWT_REFRESH_SECRET:-}" ] && echo "JWT_REFRESH_SECRET=$JWT_REFRESH_SECRET"
  [ -n "${STRIPE_SECRET_KEY:-}" ] && echo "STRIPE_SECRET_KEY=$STRIPE_SECRET_KEY"
  [ -n "${STRIPE_PUBLISHABLE_KEY:-}" ] && echo "STRIPE_PUBLISHABLE_KEY=$STRIPE_PUBLISHABLE_KEY"
  [ -n "${MPESA_CONSUMER_KEY:-}" ] && echo "MPESA_CONSUMER_KEY=$MPESA_CONSUMER_KEY"
  [ -n "${MPESA_CONSUMER_SECRET:-}" ] && echo "MPESA_CONSUMER_SECRET=$MPESA_CONSUMER_SECRET"
  [ -n "${MPESA_SHORTCODE:-}" ] && echo "MPESA_SHORTCODE=$MPESA_SHORTCODE"
  [ -n "${MPESA_PASSKEY:-}" ] && echo "MPESA_PASSKEY=$MPESA_PASSKEY"
} > "$DEPLOY_ENV"
chmod 600 "$DEPLOY_ENV"

COMPOSE=(docker compose --env-file "$DEPLOY_ENV" -f "$COMPOSE_FILE")

# Stop the app tier first, keep dependencies running (postgres keeps its data).
echo "deploy: stopping app tier"
"${COMPOSE[@]}" stop api frontend 2>/dev/null || true
"${COMPOSE[@]}" rm -f api frontend 2>/dev/null || true

# Bring dependencies up and wait for their health.
echo "deploy: ensuring dependencies are healthy"
"${COMPOSE[@]}" up -d postgres redis rabbitmq mailhog

for i in $(seq 1 30); do
  healthy=$("${COMPOSE[@]}" ps --format json 2>/dev/null \
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
"${COMPOSE[@]}" up -d --no-deps api frontend

echo "deploy: done — validate next (scripts/validate-deployment.sh)"
