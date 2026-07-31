#!/usr/bin/env bash
# Post-deploy configuration audit.
# Confirms the hardening actually took effect on the running stack. Each check
# maps to a specific risk (several come straight from the Lab 2-5 findings).
# Exits non-zero if any check fails, which fails the pipeline's validate job.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE=(docker compose -f "$DIR/deploy/docker-compose.hardened.yml")
HOST="${PENPOT_HOST:-localhost}"
fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

flags="$("${COMPOSE[@]}" exec -T penpot-backend printenv PENPOT_FLAGS 2>/dev/null || true)"

# Clojure PREPL server = remote-eval surface; must not be enabled.
echo "$flags" | grep -q "enable-prepl-server" \
  && bad "Clojure PREPL server must be disabled" \
  || pass "Clojure PREPL server disabled"

# Secure session cookies must be enforced (the disable flag must be absent).
echo "$flags" | grep -q "disable-secure-session-cookies" \
  && bad "Secure session cookies must be enforced" \
  || pass "Secure session cookies enforced"

# Telemetry off.
tel="$("${COMPOSE[@]}" exec -T penpot-backend printenv PENPOT_TELEMETRY_ENABLED 2>/dev/null || true)"
[ "$tel" = "false" ] && pass "Telemetry disabled" || bad "Telemetry must be disabled"

# Datastores must not be published to the host (closes exposed-service risk).
ports="$(docker ps --format '{{.Ports}}')"
echo "$ports" | grep -qE '0\.0\.0\.0:5432|:::5432' \
  && bad "PostgreSQL must not be published to the host" \
  || pass "PostgreSQL not exposed to host"
echo "$ports" | grep -qE '0\.0\.0\.0:6379|:::6379' \
  && bad "Redis must not be published to the host" \
  || pass "Redis not exposed to host"

# Redis must require authentication (closes the unauthenticated-Redis finding).
redis_ping="$("${COMPOSE[@]}" exec -T penpot-redis redis-cli ping 2>&1 || true)"
echo "$redis_ping" | grep -qi 'NOAUTH' \
  && pass "Redis requires authentication" \
  || bad "Redis must require authentication"

# Secret key must not be a placeholder/default (closes the hardcoded-key finding).
sk="$("${COMPOSE[@]}" exec -T penpot-backend printenv PENPOT_SECRET_KEY 2>/dev/null || true)"
if [ -z "$sk" ] || echo "$sk" | grep -qiE 'change_me|default|example|__'; then
  bad "PENPOT_SECRET_KEY looks like a placeholder"
else
  pass "PENPOT_SECRET_KEY set to a non-default value"
fi

# Transport: HTTPS answers, HTTP redirects, key headers present.
code="$(curl -sk -o /dev/null -w '%{http_code}' "https://$HOST/" || true)"
echo "$code" | grep -qE '200|30[0-9]' \
  && pass "HTTPS endpoint responds ($code)" \
  || bad "HTTPS endpoint not responding ($code)"

redir="$(curl -s -o /dev/null -w '%{redirect_url}' "http://$HOST/" || true)"
echo "$redir" | grep -q 'https://' \
  && pass "HTTP redirects to HTTPS" \
  || bad "HTTP must redirect to HTTPS"

hdrs="$(curl -skI "https://$HOST/" | tr -d '\r')"
echo "$hdrs" | grep -qi '^strict-transport-security:' \
  && pass "HSTS header present" || bad "HSTS header missing"
echo "$hdrs" | grep -qi '^x-content-type-options:' \
  && pass "X-Content-Type-Options header present" || bad "X-Content-Type-Options header missing"
echo "$hdrs" | grep -qi '^content-security-policy:' \
  && pass "Content-Security-Policy header present" || bad "Content-Security-Policy header missing"

echo
[ "$fail" -eq 0 ] && echo "Config audit: ALL CHECKS PASSED" || echo "Config audit: FAILURES DETECTED"
exit "$fail"
