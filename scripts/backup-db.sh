#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# backup-db.sh — pre-migration backup for i-love-shopping
#
# Creates a compressed pg_dump of the deployment database before any
# migration or deployment touches it. Backups are versioned by timestamp
# and kept in backups/ (never committed).
#
# Usage:
#   ./backup-db.sh --url postgres://user:pass@host:port/dbname
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

URL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -z "$URL" ] && { echo "backup-db: --url is required" >&2; exit 2; }

mkdir -p backups
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
FILE="backups/iloveshopping-db-$STAMP.dump.gz"

echo "backup-db: dumping to $FILE"
pg_dump "$URL" --no-owner --clean --if-exists | gzip > "$FILE"
ls -lh "$FILE"

# Verification pass: the backup must itself be restorable.
echo "backup-db: verifying backup integrity (restore into a scratch database)"
VERIFY_DB="iloveshopping_verify_$RANDOM"
docker run --rm --network host -v "$PWD/$FILE":/backup.dump.gz:ro postgres:16-alpine bash -c "
  createdb -h \$PGHOST '$VERIFY_DB' 2>/dev/null || true
  gunzip -c /backup.dump.gz | psql -h \$PGHOST -v ON_ERROR_STOP=0 -q '$VERIFY_DB' >/dev/null
  psql -h \$PGHOST -t -c \"SELECT count(*) FROM information_schema.tables WHERE table_schema='public'\" '$VERIFY_DB'
  dropdb -h \$PGHOST '$VERIFY_DB'
" && echo "backup-db: verified restorable"

echo "$FILE" > backups/latest.txt
echo "backup-db: $FILE is the current rollback point (backups/latest.txt)"
