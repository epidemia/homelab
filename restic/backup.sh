#!/usr/bin/env bash
# Nightly restic backup to S3 (Cloudflare R2 or any S3):
# - Makes per-DB logical dumps for all Postgres containers (globals + each DB)
# - Backs up /srv/docker + /srv/backups/pg
# - Keeps only today's dumps locally (configurable)
# - Keeps only the last N restic snapshots (default 2)
# - Verifies the snapshot: light repo check + end-to-end test by reading new dumps from the latest snapshot

set -euo pipefail

# Always print final status (success/fail)
trap 'rc=$?; ts=$(date -Is); if [ $rc -eq 0 ]; then echo "[$ts] Done."; else echo "[$ts] FAILED (rc=$rc)"; fi' EXIT

# --- Configuration & environment ---------------------------------------------

ENV_FILE="/etc/restic/restic.env"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

# Required tools
need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1"; exit 1; }; }
need restic
need docker

# Required env vars (RESTIC_REPOSITORY, password or password file)
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is required}"
# Either RESTIC_PASSWORD or RESTIC_PASSWORD_FILE must be set (restic handles this internally).
: "${BACKUP_ROOT:=/srv/backups}"
: "${RESTIC_OPTIONS:=-o s3.bucket-lookup=path}"

DATE="$(date +%F-%H%M)"
PG_DUMPS="$BACKUP_ROOT/pg"
LOG_DIR="$BACKUP_ROOT/logs"
mkdir -p "$PG_DUMPS" "$LOG_DIR"

echo "[$(date -Is)] Starting backup…"

# Optional: explicit list of Postgres containers via env (space-separated),
# e.g. in /etc/restic/restic.env:  export PG_CONTAINERS="miniflux-db readeck-db"
: "${PG_CONTAINERS:=}"

# How many days of local dumps to keep (1 = only "today")
: "${KEEP_PG_DUMPS_DAYS:=1}"

# How many last restic snapshots to keep in the repo
: "${RESTIC_KEEP_LAST:=2}"

# Verification knobs:
# Read-data subset for restic check after backup (empty to disable). Example: "1/20" (~5%), "1/50" (~2%), "1/5" (20%)
: "${VERIFY_READ_DATA_SUBSET:=1/20}"
# How many new dumps to test end-to-end by reading them from the latest snapshot and CRC-checking with zcat -t
: "${VERIFY_SNAPSHOT_SAMPLES:=2}"

# Path to per-container credential overrides (one line: <container> <user> <password>)
OVERRIDES="/etc/restic/pg-credentials.map"   # chmod 600, root:root

# --- Postgres dumps: globals + per-DB ----------------------------------------

# Discover target containers:
if [ -n "$PG_CONTAINERS" ]; then
  CONTAINERS=$PG_CONTAINERS
else
  # autodiscover by image name
  CONTAINERS=$(docker ps --format '{{.Names}} {{.Image}}' \
    | awk 'tolower($2) ~ /(postgres|postgresql|timescale)/ {print $1}')
fi

PG_LOG_BASE="$LOG_DIR"

for c in $CONTAINERS; do
  echo "[$(date -Is)] Dumping Postgres (per-db) from container: $c"
  LOG="$PG_LOG_BASE/pgdump-${c}-$DATE.log"

  # 1) Read overrides if present
  OV_USER=""; OV_PASS=""
  if [ -f "$OVERRIDES" ]; then
    # shellcheck disable=SC2086
    read -r OV_USER OV_PASS < <(awk -v n="$c" '$1==n {print $2, $3; exit}' "$OVERRIDES" 2>/dev/null || true)
  fi

  # 2) If no overrides, read credentials from container env (supports POSTGRES_* and POSTGRESQL_*)
  ENVV=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$c" 2>/dev/null || true)
  if [ -z "$OV_USER" ]; then
    OV_USER=$(printf "%s\n" "$ENVV" \
      | awk -F= '$1=="POSTGRES_USER"{print$2} $1=="POSTGRESQL_USERNAME"{print$2}' \
      | tail -n1)
  fi
  if [ -z "$OV_PASS" ]; then
    OV_PASS=$(printf "%s\n" "$ENVV" \
      | awk -F= '$1=="POSTGRES_PASSWORD"{print$2} $1=="POSTGRESQL_PASSWORD"{print$2}' \
      | tail -n1)
  fi
  [ -n "$OV_USER" ] || OV_USER="postgres"

  # 3) Wait for readiness (up to 30s)
  READY=0
  for _i in 1 2 3 4 5 6; do
    if [ -n "$OV_PASS" ]; then
      docker exec -e PGPASSWORD="$OV_PASS" "$c" sh -lc "pg_isready -U '$OV_USER'" >/dev/null 2>&1 && { READY=1; break; }
    else
      docker exec "$c" sh -lc "pg_isready -U '$OV_USER'" >/dev/null 2>&1 && { READY=1; break; }
    fi
    sleep 5
  done
  if [ "$READY" -ne 1 ]; then
    echo "[$(date -Is)] WARNING: $c not ready (skipped)" | tee -a "$LOG" >&2
    continue
  fi

  # 4) Dump globals (roles, memberships, tablespaces)
  if [ -n "$OV_PASS" ]; then
    docker exec -i -e PGPASSWORD="$OV_PASS" "$c" sh -lc "pg_dumpall --globals-only -U '$OV_USER'" \
      | gzip > "$PG_DUMPS/${c}-globals-$DATE.sql.gz" 2>>"$LOG" \
      || echo "[$(date -Is)] WARNING: globals dump failed for $c" | tee -a "$LOG" >&2
  else
    docker exec -i "$c" sh -lc "pg_dumpall --globals-only -U '$OV_USER'" \
      | gzip > "$PG_DUMPS/${c}-globals-$DATE.sql.gz" 2>>"$LOG" \
      || echo "[$(date -Is)] WARNING: globals dump failed for $c" | tee -a "$LOG" >&2
  fi

  # 5) List non-template DBs
  if [ -n "$OV_PASS" ]; then
    DBS=$(docker exec -e PGPASSWORD="$OV_PASS" "$c" sh -lc \
      "psql -U '$OV_USER' -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1\"")
  else
    DBS=$(docker exec "$c" sh -lc \
      "psql -U '$OV_USER' -At -c \"SELECT datname FROM pg_database WHERE datistemplate = false ORDER BY 1\"")
  fi

  # 6) Dump each DB (plain SQL)
  for db in $DBS; do
    OUT="$PG_DUMPS/${c}-${db}-$DATE.sql.gz"
    echo "[$(date -Is)]  -> $db"
    if [ -n "$OV_PASS" ]; then
      docker exec -i -e PGPASSWORD="$OV_PASS" "$c" sh -lc "pg_dump -U '$OV_USER' -d '$db'" \
        | gzip > "$OUT" 2>>"$LOG" \
        || echo "[$(date -Is)] WARNING: dump failed for $c/$db" | tee -a "$LOG" >&2
    else
      docker exec -i "$c" sh -lc "pg_dump -U '$OV_USER' -d '$db'" \
        | gzip > "$OUT" 2>>"$LOG" \
        || echo "[$(date -Is)] WARNING: dump failed for $c/$db (no password)" | tee -a "$LOG" >&2
    fi
  done
done

# --- Local rotation of dumps (keep only today / configurable) -----------------
# KEEP_PG_DUMPS_DAYS=1 means "only today's dumps remain on disk"
find "$PG_DUMPS" -type f -name '*.sql.gz' -mtime +$((KEEP_PG_DUMPS_DAYS-1)) -print -delete || true

# Optional validation (only if PG_CONTAINERS is set): ensure each container has both globals and per-DB dumps today
if [ -n "$PG_CONTAINERS" ]; then
  FAIL=0
  for c in $PG_CONTAINERS; do
    ls "$PG_DUMPS/${c}-globals-"*.sql.gz >/dev/null 2>&1 || { echo "[$(date -Is)] ERROR: no globals dump for $c" >&2; FAIL=1; }
    if ! ls "$PG_DUMPS/${c}-"*"-"*.sql.gz 2>/dev/null | grep -vq -- '-globals-'; then
      echo "[$(date -Is)] ERROR: no per-db dumps for $c" >&2; FAIL=1
    fi
  done
  [ $FAIL -eq 0 ] || exit 1
fi

# --- Files backup with restic -------------------------------------------------

# What to include in restic: only your state directory and the dumps
INCLUDE=(/srv/docker "$PG_DUMPS")

# Optional excludes file (to ignore raw PGDATA etc.). If not present, skip it.
RESTIC_EXCLUDES_OPT=()
if [ -f /etc/restic/excludes.txt ]; then
  RESTIC_EXCLUDES_OPT=(--exclude-file /etc/restic/excludes.txt)
fi

echo "[$(date -Is)] Restic backup…"
restic $RESTIC_OPTIONS backup \
  "${INCLUDE[@]}" \
  "${RESTIC_EXCLUDES_OPT[@]}" \
  --tag nightly \
  --host "$(hostname -f 2>/dev/null || hostname)" \
  --json > "$LOG_DIR/restic-$DATE.json" 2>&1

echo "[$(date -Is)] Restic forget…"
restic $RESTIC_OPTIONS forget --keep-last "$RESTIC_KEEP_LAST"

echo "[$(date -Is)] Restic prune…"
restic $RESTIC_OPTIONS prune

# --- Snapshot verification ----------------------------------------------------

# 1) Light integrity check by reading a subset of data from the repo (optional)
if [ -n "${VERIFY_READ_DATA_SUBSET:-}" ]; then
  echo "[$(date -Is)] Restic check (read-data-subset=${VERIFY_READ_DATA_SUBSET})…"
  restic $RESTIC_OPTIONS check --read-data-subset="${VERIFY_READ_DATA_SUBSET}" || true
fi

# 2) End-to-end test: read a couple of today's dumps from the latest snapshot and CRC-check them with zcat -t
#    This proves we can read and decrypt data from the repo, not just local files.
SAMPLES=()
# pick up to VERIFY_SNAPSHOT_SAMPLES files created this run
while IFS= read -r f; do SAMPLES+=("$f"); done < <(ls -1t "$PG_DUMPS"/*-"$DATE".sql.gz 2>/dev/null | head -n "${VERIFY_SNAPSHOT_SAMPLES}")
if [ "${#SAMPLES[@]}" -gt 0 ]; then
  echo "[$(date -Is)] Snapshot E2E verification on ${#SAMPLES[@]} dump(s)…"
  for f in "${SAMPLES[@]}"; do
    snap_path="${f}"  # path inside the snapshot is the same absolute path
    echo "[$(date -Is)]  -> verifying $(basename "$f")"
    # Read the file from the latest snapshot and test gzip CRC on the stream.
    # If anything is corrupt, zcat -t will return non-zero and the script will fail due to set -e.
    restic $RESTIC_OPTIONS dump latest "$snap_path" | zcat -t - >/dev/null 2>&1
  done
else
  echo "[$(date -Is)] NOTE: no new dumps found for E2E verification (skipping)"
fi

# Weekly light integrity check (structure only) as a bonus
if [ "$(date +%u)" = "7" ]; then
  echo "[$(date -Is)] Restic check (structure)…"
  restic $RESTIC_OPTIONS check || true
fi
