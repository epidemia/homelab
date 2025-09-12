#!/usr/bin/env bash
# Idempotent installer for restic-based backups on Ubuntu/Debian
set -euo pipefail

# 0) Ensure required packages
if ! command -v restic >/dev/null 2>&1; then
  echo "Installing restic…"
  sudo apt-get update -y
  sudo apt-get install -y restic
fi

sudo install -d -m 755 /etc/restic
sudo install -d -m 755 /usr/local/bin

# 1) Install files
sudo install -m 700 ./backup.sh /usr/local/bin/restic-backup.sh
sudo install -m 640 ./restic-excludes.txt /etc/restic/excludes.txt
sudo install -m 600 ./restic-backup.service /etc/systemd/system/restic-backup.service
sudo install -m 600 ./restic-backup.timer   /etc/systemd/system/restic-backup.timer

# 2) Prepare env file (do not overwrite if present)
if [ ! -f /etc/restic/restic.env ]; then
  sudo install -m 600 ./restic.env.template /etc/restic/restic.env
  echo "Created /etc/restic/restic.env from template — fill your secrets before enabling."
fi

# 3) Enable timer
sudo systemctl daemon-reload
sudo systemctl enable --now restic-backup.timer

echo
echo "=== Installed. Next steps ==="
echo "1) Edit /etc/restic/restic.env (set S3 endpoint/keys, RESTIC_PASSWORD)."
echo "2) Initialize repo once: 'sudo -E bash -c \". /etc/restic/restic.env; restic \$RESTIC_OPTIONS init\"'"
echo "3) Run a manual backup test: 'sudo /usr/local/bin/restic-backup.sh' and check 'restic snapshots'."
