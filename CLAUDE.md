# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker Compose-based homelab infrastructure orchestrating self-hosted services behind Traefik reverse proxy with automated Restic backups to Cloudflare R2.

## Common Commands

```bash
# Start all services
docker compose up -d

# View logs for a specific service
docker compose logs --no-log-prefix -n 100 <service-name>

# Run manual backup
sudo /usr/local/bin/restic-backup.sh

# Check backup timer status
systemctl status restic-backup.timer

# Install backup systemd timer (from restic/ directory)
./install-restic-backup.sh
```

## Architecture

### Network Layout
- **homelab**: Shared external network for all services and Traefik routing
- **miniflux-backend**, **readeck-backend**: Internal networks isolating Postgres databases

### Service Stack
| Service | Port | Database | Purpose |
|---------|------|----------|---------|
| traefik | 80 | - | Reverse proxy, auto-discovers via Docker labels |
| pihole-unbound | 53 | - | DNS + adblocking + recursive resolver |
| miniflux | 8080 | Postgres 17 | RSS feed reader |
| readeck | 8000 | Postgres 17 | Article archiver |
| beszel + agent | 8090 | - | System monitoring |
| mazanoke | 80 | - | Image optimization |
| bentopdf | 8080 | - | PDF generation |

### Routing Pattern
All services are exposed via Traefik at `<service>.${BASE_URL}` using Docker labels in their compose files.

### Backup System
Nightly at 02:20 UTC via systemd timer:
1. Discovers running Postgres containers, dumps each database
2. Backs up `/srv/docker/*` and dumps to Cloudflare R2 via Restic
3. Keeps last 2 snapshots

Disaster recovery documented in `restic/RESTORE.md`.

## Configuration

Environment variables defined in `.env` (see `.env.example` for template). Each service directory contains its own `compose.yaml` included by the root compose file.
