#!/usr/bin/env bash
# One-time host preparation for the secure Penpot deployment (Ubuntu VM).
# Verifies the runtime and applies host-level network controls.
set -euo pipefail

echo "== Runtime check =="
command -v docker >/dev/null || {
  echo "Docker is not installed. See https://docs.docker.com/engine/install/ubuntu/"
  exit 1
}
docker compose version >/dev/null || {
  echo "Docker Compose v2 is required (the 'docker compose' subcommand)."
  exit 1
}
echo "Docker and Compose v2 present."

echo "== Host firewall (network controls) =="
if command -v ufw >/dev/null; then
  sudo ufw --force enable
  sudo ufw default deny incoming
  sudo ufw default allow outgoing
  sudo ufw allow 22/tcp   # SSH
  sudo ufw allow 80/tcp   # HTTP (redirects to HTTPS)
  sudo ufw allow 443/tcp  # HTTPS
  # PostgreSQL (5432) and Redis (6379) are intentionally NOT opened; they live
  # only on the internal Docker network and must never be reachable off-host.
  sudo ufw reload
  echo "ufw configured: 22/80/443 allowed, service ports remain internal-only."
else
  echo "ufw not found; skipping firewall step. Ensure only 22/80/443 are exposed."
fi

echo "Host preparation complete."
