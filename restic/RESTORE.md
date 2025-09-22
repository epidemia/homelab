# Disaster Recovery: Restore Your Homelab on a New Machine (restic + Cloudflare R2)

This guide explains how to recover your homelab on a **new machine** from a `restic` repository stored in **Cloudflare R2**.

You will restore:

- Service files under **`/srv/docker`** (state/configs for your containers, except raw Postgres PGDATA which we deliberately exclude).
- Postgres logical dumps under **`/srv/backups/pg`**:
  `*-globals-<timestamp>.sql.gz` (roles/tablespaces) and `*-<dbname>-<timestamp>.sql.gz` (each database).

> **Important:** This setup keeps **current state** only (the last 1–2 snapshots). You will recover to the exact state at the time of the **most recent nightly backup**.

---

## Prerequisites

- Cloudflare R2 credentials:
  - **Account ID**, **Access Key ID**, **Secret Access Key**.
- restic repo URL (S3 endpoint), e.g.:
  `s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<bucket>/<prefix>`
  (If your bucket uses a region subdomain, use `https://<ACCOUNT_ID>.<region>.r2.cloudflarestorage.com/<bucket>/<prefix>`; region is typically `eu` for EU buckets.)
- Either `RESTIC_PASSWORD` **or** `RESTIC_PASSWORD_FILE` (restic will pick up one of them).
- Your Git repository with your Docker Compose files.
- Prefer using the **same major PostgreSQL version** as in your backups (you use **Postgres 17**; `postgres:17-alpine` is a good image).

---

## 1) Base OS and tools

```bash
# Ubuntu/Debian
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates gnupg lsb-release

# Docker (official convenience script)
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"    # re-login to apply the docker group

# restic
sudo apt-get install -y restic

# directories we will restore into
sudo mkdir -p /srv/docker /srv/backups/pg /etc/restic
```

Clone your homelab repo with your Docker Compose files into your preferred location.

---

## 2) Configure access to the restic repository (R2)

Create `/etc/restic/restic.env`:

```bash
sudo tee /etc/restic/restic.env >/dev/null <<'EOF'
export RESTIC_PASSWORD='YOUR_STRONG_PASSWORD'
export RESTIC_REPOSITORY='s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<bucket>/<prefix>'
export AWS_ACCESS_KEY_ID='R2_ACCESS_KEY_ID'
export AWS_SECRET_ACCESS_KEY='R2_SECRET_ACCESS_KEY'
export AWS_DEFAULT_REGION='auto'
export RESTIC_OPTIONS='-o s3.bucket-lookup=path'
export BACKUP_ROOT='/srv/backups'
EOF
sudo chmod 600 /etc/restic/restic.env
```

Verify repository access:

```bash
sudo -E bash -c '. /etc/restic/restic.env; restic $RESTIC_OPTIONS snapshots'
# You should see a list of snapshots. If you see "wrong password or no key found", re-check the password and repo URL.
```

---

## 3) Restore files from the latest snapshot

> **Safer option:** restore into a sandbox first (`/restore`), review, then copy into place.
> On a **clean** system you _may_ restore directly to `/`.

### Option A — restore to `/restore` then copy

```bash
sudo mkdir -p /restore
sudo -E bash -c '. /etc/restic/restic.env; restic $RESTIC_OPTIONS restore latest --target /restore'

# Inspect restored content:
sudo ls -lah /restore/srv/docker
sudo ls -lah /restore/srv/backups/pg

# Copy into live locations:
sudo rsync -aHAX --info=progress2 /restore/srv/docker/      /srv/docker/
sudo rsync -aHAX --info=progress2 /restore/srv/backups/pg/  /srv/backups/pg/
```

### Option B — restore directly to `/` (only if the OS is clean)

```bash
sudo -E bash -c '. /etc/restic/restic.env; restic $RESTIC_OPTIONS restore latest --target /'
```

> Run as `root`; restic restores ownership and permissions.

---

## 4) Start **only** the Postgres containers and wait for readiness

From the directory where your Compose files live:

```bash
docker compose up -d miniflux-db readeck-db

# Wait until Postgres is ready to accept connections:
docker exec miniflux-db sh -lc 'until pg_isready -U "${POSTGRES_USER:-postgres}"; do sleep 1; done'
docker exec readeck-db  sh -lc 'until pg_isready -U "${POSTGRES_USER:-postgres}"; do sleep 1; done'
```

> If your DB container names differ, substitute them accordingly.

---

## 5) Import `globals` and per-DB dumps

**What are `globals`?** They are Postgres-wide objects: **roles (including passwords/attributes/memberships)** and **tablespaces**. Restore them **before** importing databases so owners and GRANTs apply correctly.

### Automated import of the most recent files

```bash
# Restore globals for each DB container (pick the latest file)
for c in miniflux-db readeck-db; do
  f=$(ls -1t /srv/backups/pg/${c}-globals-*.sql.gz | head -n1)
  [ -n "$f" ] || { echo "No globals dump for $c"; exit 1; }
  echo "Importing globals: $f"
  gzip -dc "$f" | docker exec -i "$c" psql -U postgres -d postgres
done

# Restore each database (pick the latest per-DB dump for each DB name)
for c in miniflux-db readeck-db; do
  for f in $(ls -1t /srv/backups/pg/${c}-*-*.sql.gz | grep -v -- '-globals-'); do
    db=$(basename "$f" | sed -E "s/^${c}-([^-]+)-.*\.sql\.gz/\1/")
    echo "Importing DB $db for $c : $f"
    docker exec "$c" createdb -U postgres "$db" 2>/dev/null || true
    gzip -dc "$f" | docker exec -i "$c" psql -U postgres -d "$db"
  done
done
```

### Manual import (one DB example)

```bash
# miniflux
gzip -dc /srv/backups/pg/miniflux-db-globals-<timestamp>.sql.gz | docker exec -i miniflux-db psql -U postgres -d postgres
docker exec miniflux-db createdb -U postgres miniflux || true
gzip -dc /srv/backups/pg/miniflux-db-miniflux-<timestamp>.sql.gz | docker exec -i miniflux-db psql -U postgres -d miniflux

# readeck
gzip -dc /srv/backups/pg/readeck-db-globals-<timestamp>.sql.gz | docker exec -i readeck-db psql -U postgres -d postgres
docker exec readeck-db createdb -U postgres readeck || true
gzip -dc /srv/backups/pg/readeck-db-readeck-<timestamp>.sql.gz | docker exec -i readeck-db psql -U postgres -d readeck
```

> If your container or database names differ, adjust accordingly.

---

## 6) Start the whole stack and verify

```bash
docker compose up -d
docker ps

# Quick checks:
docker exec miniflux-db psql -U postgres -d miniflux -c 'SELECT COUNT(*) FROM entries;'
docker exec readeck-db  psql -U postgres -d readeck  -c '\dt'

# App logs (migrations/initialization):
docker compose logs --no-log-prefix -n 100 miniflux
docker compose logs --no-log-prefix -n 100 readeck
```

---

## 7) Re-enable nightly backups (if not already enabled)

```bash
# In your homelab/restic folder
chmod +x install-restic-backup.sh
./install-restic-backup.sh

# Check the timer
systemctl status restic-backup.timer

# One-off run
sudo /usr/local/bin/restic-backup.sh
```

---

## Optional: Validate the repository and the latest snapshot

```bash
# Light integrity check reading a small subset (e.g., 5%)
sudo -E bash -c '. /etc/restic/restic.env; restic $RESTIC_OPTIONS check --read-data-subset=1/20'

# List which dumps are present in the latest snapshot
sudo -E bash -c '. /etc/restic/restic.env; restic $RESTIC_OPTIONS ls latest /srv/backups/pg | tail -n +1'
```

To validate a single dump end-to-end (read from the snapshot and CRC-check gzip):

```bash
DUMP="/srv/backups/pg/miniflux-db-miniflux-<timestamp>.sql.gz"
sudo -E bash -c '. /etc/restic/restic.env; restic $RESTIC_OPTIONS dump latest '"$DUMP"' | zcat -t - >/dev/null && echo "OK"'
```
