# Repository Guidelines

## Project Structure & Module Organization
This repository defines a Docker Compose homelab. The root [`compose.yaml`](/Users/andreimochalov/Projects/homelab/compose.yaml) aggregates service stacks from `traefik/`, `pihole-unbound/`, `miniflux/`, `readeck/`, `beszel/`, `mazanoke/`, and `bentopdf/`. Each service directory owns its own `compose.yaml`; keep service-specific networks, labels, and volumes there. The [`restic/`](/Users/andreimochalov/Projects/homelab/restic) directory contains backup automation, systemd units, and restore documentation. Use [`.env.example`](/Users/andreimochalov/Projects/homelab/.env.example) as the template for local `.env`.

## Build, Test, and Development Commands
`cp .env.example .env` creates the required environment file.

`docker compose config -q` validates the merged Compose configuration before committing.

`docker compose config --services` lists resolved service names from the full stack.

`docker compose up -d` starts the homelab from the repository root.

`docker compose logs --no-log-prefix -n 100 <service>` shows recent logs for one service, for example `docker compose logs --no-log-prefix -n 100 miniflux`.

`cd restic && ./install-restic-backup.sh` installs the backup timer on a host.

`sudo /usr/local/bin/restic-backup.sh` runs a manual backup.

## Coding Style & Naming Conventions
Use two-space indentation in YAML and preserve the existing Compose style. Service directories use lowercase, hyphenated names, and containers use explicit names such as `miniflux-db`. Keep Traefik labels grouped with the exposed service and follow the hostname pattern `<service>.${BASE_URL}`. Shell scripts should remain Bash with `set -euo pipefail`, uppercase environment variables, and small, defensive helper functions.

## Testing Guidelines
There is no formal unit test suite in this repository. Validation is operational: run `docker compose config -q`, then smoke-test changed services with `docker compose up -d <service>` and inspect logs or health checks. For backup changes, run `sudo /usr/local/bin/restic-backup.sh` on a test machine and confirm the restore flow still matches [`restic/RESTORE.md`](/Users/andreimochalov/Projects/homelab/restic/RESTORE.md).

## Commit & Pull Request Guidelines
Recent commits use short imperative subjects in sentence case, for example `Add traefik.docker.network label to Miniflux and Readeck services`. Keep each commit focused on one service or one infrastructure concern. Pull requests should name affected services, list new environment variables, ports, or volumes, and include the exact validation commands you ran. Screenshots are rarely needed; use them only for UI-facing service changes.

## Security & Configuration Tips
Never commit real secrets. Add new variables to [`.env.example`](/Users/andreimochalov/Projects/homelab/.env.example) when configuration changes. Prefer persistent data under `/srv/docker/...`, and document any new DNS, certificate, or backup requirements in the same PR.
