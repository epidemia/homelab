#!/usr/bin/env bash
# Nightly restic backup to Cloudflare R2 (or any S3): /srv/docker + PG dumps
set -euo pipefail

ENV_FILE="/etc/restic/restic.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need restic; need docker

: "${RESTIC_PASSWORD:?RESTIC_PASSWORD is required}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
: "${BACKUP_ROOT:=/srv/backups}"
: "${RESTIC_OPTIONS:=-o s3.bucket-lookup=path}"

DATE="$(date +%F-%H%M)"
PG_DUMPS="$BACKUP_ROOT/pg"
LOG_DIR="$BACKUP_ROOT/logs"
mkdir -p "$PG_DUMPS" "$LOG_DIR"

echo "[$(date -Is)] Starting backup…"

# 1) Logical dumps of all Postgres containers
docker ps --format '{{.Names}} {{.Image}}' \
| awk 'tolower($2) ~ /postgres/ {print $1}' \
| while read -r c; do
  echo "[$(date -Is)] Dumping Postgres from container: $c"
  if ! docker exec -i "$c" sh -lc 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' \
      | gzip > "$PG_DUMPS/${c}-all-$DATE.sql.gz"; then
    echo "[$(date -Is)] WARNING: dump failed for $c" >&2
  fi
done

# 2) Backup only what we need: /srv/docker + database dumps
INCLUDE=(/srv/docker "$PG_DUMPS")

echo "[$(date -Is)] Restic backup…"
restic $RESTIC_OPTIONS backup \
  "${INCLUDE[@]}" \
  --exclude-file /etc/restic/excludes.txt \
  --tag nightly \
  --host "$(hostname -f 2>/dev/null || hostname)" \
  --json > "$LOG_DIR/restic-$DATE.json" 2>&1

# 3) Retention: forget daily; prune/check on Sundays
echo "[$(date -Is)] Restic forget…"
restic $RESTIC_OPTIONS forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6

if [ "$(date +%u)" = "7" ]; then
  echo "[$(date -Is)] Restic prune…"
  restic $RESTIC_OPTIONS prune
  echo "[$(date -Is)] Restic check…"
  restic $RESTIC_OPTIONS check || true
fi

echo "[$(date -Is)] Done."
