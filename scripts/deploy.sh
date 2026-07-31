#!/usr/bin/env bash
# Render the deployment .env from injected secrets and bring up the hardened stack.
# Secrets are read from the environment (CI secret store or your local shell) and
# are NEVER read from a committed file.
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "$0")/../deploy" && pwd)"
cd "$DEPLOY_DIR"

# Required secrets.
: "${PENPOT_SECRET_KEY:?PENPOT_SECRET_KEY is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
: "${REDIS_PASSWORD:?REDIS_PASSWORD is required}"

# Optional / defaulted.
PENPOT_VERSION="${PENPOT_VERSION:-2.10.1}"
PENPOT_HOST="${PENPOT_HOST:-localhost}"
PENPOT_PUBLIC_URI="${PENPOT_PUBLIC_URI:-https://$PENPOT_HOST}"
POSTGRES_DB="${POSTGRES_DB:-penpot}"
POSTGRES_USER="${POSTGRES_USER:-penpot}"

echo "Rendering .env (not committed)..."
umask 077
cat > .env <<EOF
PENPOT_VERSION=${PENPOT_VERSION}
PENPOT_PUBLIC_URI=${PENPOT_PUBLIC_URI}
PENPOT_BACKEND_FLAGS=disable-registration enable-login-with-password disable-email-verification disable-smtp disable-telemetry
PENPOT_FRONTEND_FLAGS=disable-registration enable-login-with-password
PENPOT_SECRET_KEY=${PENPOT_SECRET_KEY}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
REDIS_PASSWORD=${REDIS_PASSWORD}
EOF

# TLS material (self-signed for the local test environment).
if [ ! -f certs/penpot.crt ]; then
  echo "Generating TLS certificate..."
  mkdir -p certs
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout certs/penpot.key \
    -out    certs/penpot.crt \
    -subj   "/CN=$PENPOT_HOST" \
    -addext "subjectAltName=DNS:$PENPOT_HOST,DNS:localhost,IP:127.0.0.1"
  chmod 600 certs/penpot.key
  echo "Self-signed certificate written to certs/ (CN=$PENPOT_HOST)."
fi

echo "Pulling pinned images and starting the stack..."
docker compose -f docker-compose.hardened.yml pull
docker compose -f docker-compose.hardened.yml up -d --remove-orphans

echo "Waiting for services to report healthy..."
for _ in $(seq 1 36); do
  not_ready="$(docker compose -f docker-compose.hardened.yml ps --format '{{.Health}}' \
    | grep -c -E 'starting|unhealthy' || true)"
  [ "$not_ready" = "0" ] && break
  sleep 5
done

docker compose -f docker-compose.hardened.yml ps
echo "Deployment complete: https://${PENPOT_HOST}"
