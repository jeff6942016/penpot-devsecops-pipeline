#!/usr/bin/env bash
# Targeted DAST regression checks for the two Lab findings on this instance:
#   CWE-307  Improper Restriction of Excessive Authentication Attempts (no login rate limiting)
#   CWE-613  Insufficient Session Expiration (session not invalidated on logout)
#
# Requires a DISPOSABLE test account (never a real user). Set:
#   TEST_EMAIL, TEST_PASSWORD
#
# NOTE: Penpot RPC command names below (login-with-password, get-profile, logout)
# match current Penpot, but confirm them against your version in the browser
# network tab if a check misbehaves. Wire this into the validate job once you
# have seeded a throwaway account.
set -uo pipefail

HOST="${PENPOT_HOST:-localhost}"
BASE="https://$HOST"
EMAIL="${TEST_EMAIL:?set TEST_EMAIL to a disposable test account}"
PASS="${TEST_PASSWORD:?set TEST_PASSWORD}"
CURL="curl -sk"
fail=0

echo "== CWE-307: login rate limiting =="
blocked=0
for i in $(seq 1 20); do
  code="$($CURL -o /dev/null -w '%{http_code}' \
    -X POST "$BASE/api/rpc/command/login-with-password" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$EMAIL\",\"password\":\"wrong-$i\"}")"
  if [ "$code" = "429" ]; then
    blocked=1; echo "  throttled after $i attempts (HTTP 429)"; break
  fi
done
if [ "$blocked" -eq 1 ]; then
  echo "PASS: brute-force throttling present"
else
  echo "FAIL: 20 rapid failed logins with no throttling (CWE-307)"; fail=1
fi

echo "== CWE-613: session invalidation on logout =="
jar="$(mktemp)"
$CURL -c "$jar" -o /dev/null \
  -X POST "$BASE/api/rpc/command/login-with-password" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASS\"}"
before="$($CURL -b "$jar" -o /dev/null -w '%{http_code}' "$BASE/api/rpc/command/get-profile")"
$CURL -b "$jar" -c "$jar" -X POST "$BASE/api/rpc/command/logout" >/dev/null
after="$($CURL -b "$jar" -o /dev/null -w '%{http_code}' "$BASE/api/rpc/command/get-profile")"
rm -f "$jar"
echo "  authenticated before logout: $before, after logout: $after"
if [ "$after" = "401" ]; then
  echo "PASS: session invalidated on logout"
else
  echo "FAIL: session still valid after logout (CWE-613)"; fail=1
fi

echo
[ "$fail" -eq 0 ] && echo "Auth probes: PASSED" || echo "Auth probes: FAILURES DETECTED"
exit "$fail"
