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
# --- BEGIN: robust per-DB dumps (replaces old pg_dumpall) ---
OVERRIDES="/etc/restic/pg-credentials.map"   # lines: <container> <user> <password>
PG_LOG_BASE="$LOG_DIR"

# 1) Контейнеры: из PG_CONTAINERS или autodiscover по образу
if [ -n "${PG_CONTAINERS:-}" ]; then
  CONTAINERS=$PG_CONTAINERS
else
  CONTAINERS=$(docker ps --format '{{.Names}} {{.Image}}' \
    | awk 'tolower($2) ~ /(postgres|postgresql|timescale)/ {print $1}')
fi

for c in $CONTAINERS; do
  echo "[$(date -Is)] Dumping Postgres (per-db) from container: $c"
  LOG="$PG_LOG_BASE/pgdump-${c}-$DATE.log"

  # 2) Берём креды: overrides -> env -> defaults
  OV_USER=""; OV_PASS=""
  if [ -f "$OVERRIDES" ]; then
    read -r OV_USER OV_PASS < <(awk -v n="$c" '$1==n {print $2, $3; exit}' "$OVERRIDES" 2>/dev/null || true)
  fi
  ENVV=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null || true)
  [ -z "$OV_USER" ] && OV_USER=$(printf "%s\n" "$ENVV" \
    | awk -F= '$1=="POSTGRES_USER"{print$2} $1=="POSTGRESQL_USERNAME"{print$2}' \
    | tail -n1)
  [ -z "$OV_PASS" ] && OV_PASS=$(printf "%s\n" "$ENVV" \
    | awk -F= '$1=="POSTGRES_PASSWORD"{print$2} $1=="POSTGRESQL_PASSWORD"{print$2}' \
    | tail -n1)
  [ -n "$OV_USER" ] || OV_USER="postgres"

  # 3) Ждём готовность (до 30 сек)
  READY=0
  for i in 1 2 3 4 5 6; do
    if [ -n "$OV_PASS" ]; then
      docker exec -e PGPASSWORD="$OV_PASS" "$c" sh -lc "pg_isready -U '$OV_USER'" >/dev/null 2>&1 && { READY=1; break; }
    else
      docker exec "$c" sh -lc "pg_isready -U '$OV_USER'" >/dev/null 2>&1 && { READY=1; break; }
    fi
    sleep 5
  done
  if [ "$READY" -ne 1 ] ; then
    echo "[$(date -Is)] WARNING: $c not ready (skipped)" | tee -a "$LOG" >&2
    continue
  fi

  # 4) Дамп глобалей (роли/таблспейсы) — один файл на контейнер
  if [ -n "$OV_PASS" ]; then
    docker exec -i -e PGPASSWORD="$OV_PASS" "$c" sh -lc "pg_dumpall --globals-only -U '$OV_USER'" \
      | gzip > "$PG_DUMPS/${c}-globals-$DATE.sql.gz" 2>>"$LOG" || echo "[$(date -Is)] WARNING: globals dump failed for $c" | tee -a "$LOG" >&2
  else
    docker exec -i "$c" sh -lc "pg_dumpall --globals-only -U '$OV_USER'" \
      | gzip > "$PG_DUMPS/${c}-globals-$DATE.sql.gz" 2>>"$LOG" || echo "[$(date -Is)] WARNING: globals dump failed for $c" | tee -a "$LOG" >&2
  fi

  # 5) Список «не-template» баз
  if [ -n "$OV_PASS" ]; then
    DBS=$(docker exec -e PGPASSWORD="$OV_PASS" "$c" sh -lc \
      "psql -U '$OV_USER' -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1\"")
  else
    DBS=$(docker exec "$c" sh -lc \
      "psql -U '$OV_USER' -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1\"")
  fi

  # 6) Дамп каждой базы отдельно (plain SQL)
  for db in $DBS; do
    # Можно пропустить служебную 'postgres' при желании: if [ "$db" = "postgres" ]; then continue; fi
    OUT="$PG_DUMPS/${c}-${db}-$DATE.sql.gz"
    echo "[$(date -Is)]  -> $db"
    if [ -n "$OV_PASS" ]; then
      docker exec -i -e PGPASSWORD="$OV_PASS" "$c" sh -lc "pg_dump -U '$OV_USER' -d '$db'" \
        | gzip > "$OUT" 2>>"$LOG" || echo "[$(date -Is)] WARNING: dump failed for $c/$db" | tee -a "$LOG" >&2
    else
      docker exec -i "$c" sh -lc "pg_dump -U '$OV_USER' -d '$db'" \
        | gzip > "$OUT" 2>>"$LOG" || echo "[$(date -Is)] WARNING: dump failed for $c/$db (no password)" | tee -a "$LOG" >&2
    fi
  done
done
# --- END ---

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
