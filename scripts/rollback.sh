#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# rollback.sh — rollback for i-love-shopping
#
# Restores the previous version when a deployment is bad:
#   1. version artifact: the docker image tag from before the bad deploy
#   2. database: the pg_dump backup taken before that deploy ran
#   3. restart + revalidate
#
# Usage (on the deployment target):
#   ./rollback.sh --compose docker/docker-compose.yml [--backup backups/<file>]
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.yml"
BACKUP=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose) COMPOSE_FILE="$2"; shift ;;
    --backup) BACKUP="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# 1. Database rollback: restore the pre-deployment backup.
[ -z "$BACKUP" ] && [ -f backups/latest.txt ] && BACKUP="$(cat backups/latest.txt)"
if [ -z "$BACKUP" ] || [ ! -f "$BACKUP" ]; then
  echo "rollback: no database backup found (backups/latest.txt) — nothing to restore" >&2
  echo "rollback: continuing with app-tier rollback only" >&2
else
  DB_USER="$(docker compose -f "$COMPOSE_FILE" config 2>/dev/null | grep -m1 'POSTGRES_USER' | cut -d: -f2 | tr -d ' "')"
  DB_USER="${DB_USER:-iloveshopping}"
  PG_CONTAINER="$(docker compose -f "$COMPOSE_FILE" ps -q postgres)"
  echo "rollback: dropping the migrated database and restoring $BACKUP"
  docker exec -i "$PG_CONTAINER" sh -c "
    psql -U $DB_USER -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB_USER'\" >/dev/null
    dropdb -U $DB_USER --if-exists $DB_USER
    createdb -U $DB_USER $DB_USER
  "
  gunzip -c "$BACKUP" | docker exec -i "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_USER" -v ON_ERROR_STOP=0 -q
  echo "rollback: database restored from $BACKUP"
fi

# 2. App-tier rollback: restart from the previous image tag.
PREV_TAG="$(docker images iloveshopping/api --format '{{.Tag}}' | grep -v '<none>' | grep -v "$(cat backups/deployed-tag.txt 2>/dev/null || echo none)" | head -1 || true)"
if [ -n "$PREV_TAG" ] && [ "$PREV_TAG" != "$(cat backups/deployed-tag.txt 2>/dev/null)" ]; then
  echo "rollback: restarting app tier at previous image tag $PREV_TAG"
  docker tag "iloveshopping/api:$PREV_TAG" "docker-api" 2>/dev/null || true
  docker tag "iloveshopping/frontend:$PREV_TAG" "docker-frontend" 2>/dev/null || true
fi
docker compose -f "$COMPOSE_FILE" up -d --no-deps api frontend

# 3. Verify the rollback worked.
echo "rollback: validating the restored stack"
sleep 20
"$SCRIPT_DIR/validate-deployment.sh" && echo "rollback: OK — previous version is live" \
  || { echo "rollback: validation still failing — investigate manually" >&2; exit 1; }
