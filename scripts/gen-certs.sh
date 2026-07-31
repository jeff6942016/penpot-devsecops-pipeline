#!/usr/bin/env bash
# Generate a self-signed certificate for local HTTPS.
# Usage: scripts/gen-certs.sh [hostname]   (default: localhost)
set -euo pipefail

CN="${1:-localhost}"
CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/deploy/certs"
mkdir -p "$CERT_DIR"

openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
  -keyout "$CERT_DIR/penpot.key" \
  -out    "$CERT_DIR/penpot.crt" \
  -subj   "/CN=$CN" \
  -addext "subjectAltName=DNS:$CN,DNS:localhost,IP:127.0.0.1"

chmod 600 "$CERT_DIR/penpot.key"
echo "Self-signed certificate written to $CERT_DIR (CN=$CN)."
