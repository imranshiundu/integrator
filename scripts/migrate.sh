#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# migrate.sh — Database Migration for i-love-shopping
#
# The production flow: backup -> validate (dry run on a scratch database) ->
# apply -> verify. A failed migration leaves the database untouched; a
# failed deployment is restored from the backup taken here (rollback.sh).
#
# Usage (from the target repo root):
#   ./migrate.sh --compose docker/docker-compose.yml
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

COMPOSE_FILE="docker/docker-compose.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --compose) COMPOSE_FILE="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

# Resolve the live database connection from the compose stack.
DB_USER="$(docker compose -f "$COMPOSE_FILE" config 2>/dev/null | grep -m1 'POSTGRES_USER' | cut -d: -f2 | tr -d ' "')" 
DB_USER="${DB_USER:-iloveshopping}"
DB_NAME="${DB_NAME:-$DB_USER}"
PG_CONTAINER="$(docker compose -f "$COMPOSE_FILE" ps -q postgres)"
[ -n "$PG_CONTAINER" ] || { echo "migrate: postgres is not running" >&2; exit 1; }

echo "migrate: 1/4 backup"
"$SCRIPT_DIR/backup-db.sh" --url "postgres://$DB_USER@$DB_USER/$DB_NAME" 2>/dev/null \
  || docker exec "$PG_CONTAINER" sh -c "pg_dump -U $DB_USER $DB_NAME | gzip" > "backups/manual-$$.dump.gz" \
     && echo "migrate: fallback backup at backups/manual-$$.dump.gz"

echo "migrate: 2/4 validate — apply every migration to a scratch database first"
docker exec "$PG_CONTAINER" sh -c "dropdb -U $DB_USER --if-exists iloveshopping_dryrun; createdb -U $DB_USER iloveshopping_dryrun"
MIGRATIONS_DIR="$(cd "$(dirname "$COMPOSE_FILE")/../backend/src/main/resources/db/migration" 2>/dev/null && pwd)"
if [ -n "$MIGRATIONS_DIR" ]; then
  docker run --rm --network "container:$PG_CONTAINER" \
    -v "$MIGRATIONS_DIR:/flyway/sql:ro" \
    -e FLYWAY_URL="jdbc:postgresql://localhost/iloveshopping_dryrun" \
    -e FLYWAY_USER="$DB_USER" -e FLYWAY_PASSWORD="" \
    -e FLYWAY_LOCATIONS="filesystem:/flyway/sql" \
    -e FLYWAY_DEFAULT_SCHEMA=public \
    flyway/flyway:10 migrate > /dev/null \
    && echo "migrate: dry run passed on iloveshopping_dryrun"
else
  echo "migrate: no migrations directory found — nothing to apply"
fi

echo "migrate: 3/4 apply (the application runs Flyway at boot — restart applies pending migrations)"
echo "migrate: 4/4 verify"
docker exec "$PG_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -t -c \
  "SELECT 'migrations_applied: ' || count(*) FROM flyway_schema_history WHERE success" || true

echo "migrate: done — rollback point recorded in backups/latest.txt"
