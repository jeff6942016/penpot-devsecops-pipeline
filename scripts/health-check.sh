#!/usr/bin/env bash
# Service availability and integrity checks against the deployed instance.
# Exits non-zero if the service is not healthy.
set -uo pipefail

HOST="${PENPOT_HOST:-localhost}"
fail=0
p() { echo "PASS: $1"; }
f() { echo "FAIL: $1"; fail=1; }

# Frontend served over HTTPS.
code="$(curl -sk -o /dev/null -w '%{http_code}' "https://$HOST/" || true)"
[ "$code" = "200" ] && p "Frontend served over HTTPS (200)" || f "Frontend returned HTTP $code"

# Integrity marker in the served HTML.
body="$(curl -sk "https://$HOST/" | tr '[:upper:]' '[:lower:]' || true)"
echo "$body" | grep -q "penpot" \
  && p "Frontend integrity marker present" \
  || f "Frontend content did not contain the expected marker"

# Backend reachable through the proxy: any non-gateway response proves routing.
# (Endpoint requires auth; a 401/404 is fine, a 502/503/504 is not.)
api="$(curl -sk -o /dev/null -w '%{http_code}' "https://$HOST/api/rpc/command/get-profile" || true)"
echo "$api" | grep -qE '50[234]' \
  && f "Backend unreachable through proxy (HTTP $api)" \
  || p "Backend reachable through proxy (HTTP $api)"

# TLS handshake completes.
tls="$(echo | openssl s_client -connect "$HOST:443" -servername "$HOST" 2>/dev/null \
  | grep -c 'Verify return code' || true)"
[ "$tls" -ge 1 ] && p "TLS handshake completed" || f "TLS handshake failed"

echo
[ "$fail" -eq 0 ] && echo "Health check: SERVICE HEALTHY" || echo "Health check: DEGRADED"
exit "$fail"
