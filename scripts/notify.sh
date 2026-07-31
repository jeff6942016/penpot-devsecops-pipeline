#!/usr/bin/env bash
# Developer notification.
# Opens or updates a single tracking GitHub issue (label: devsecops) and, if a
# Discord webhook is configured, posts there too. Idempotent: reuses the open
# tracking issue and adds a comment rather than spamming new issues.
#
# Usage: scripts/notify.sh "<title>" [body-file]
# Reads GITHUB_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID (provided by Actions) and
# optional DISCORD_WEBHOOK_URL.
set -uo pipefail

TITLE="${1:-DevSecOps pipeline finding}"
BODY_FILE="${2:-}"
REPO="${GITHUB_REPOSITORY:-}"
API="${GITHUB_API_URL:-https://api.github.com}"
SERVER="${GITHUB_SERVER_URL:-https://github.com}"
RUN_URL="$SERVER/$REPO/actions/runs/${GITHUB_RUN_ID:-}"

body="$(cat "$BODY_FILE" 2>/dev/null || echo "See the pipeline run for details.")"
body="$body

---
Run: $RUN_URL
Commit: ${GITHUB_SHA:-unknown}"

json() { python3 -c "import json,sys; print(json.dumps(dict(zip(sys.argv[1::2], sys.argv[2::2]))))" "$@"; }

# --- GitHub issue (idempotent) ---
if [ -n "${GITHUB_TOKEN:-}" ] && [ -n "$REPO" ]; then
  num="$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    "$API/repos/$REPO/issues?state=open&labels=devsecops&per_page=1" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['number'] if isinstance(d,list) and d else '')" 2>/dev/null || true)"

  if [ -n "$num" ]; then
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
      "$API/repos/$REPO/issues/$num/comments" \
      -d "$(json body "**$TITLE**

$body")"
    echo "Commented on tracking issue #$num"
  else
    curl -s -o /dev/null -X POST -H "Authorization: Bearer $GITHUB_TOKEN" \
      "$API/repos/$REPO/issues" \
      -d "$(python3 -c "import json,sys; print(json.dumps({'title': sys.argv[1], 'body': sys.argv[2], 'labels': ['devsecops','security']}))" "$TITLE" "$body")"
    echo "Opened tracking issue"
  fi
else
  echo "GITHUB_TOKEN/REPOSITORY not set; skipping GitHub issue."
fi

# --- Discord webhook (optional) ---
if [ -n "${DISCORD_WEBHOOK_URL:-}" ]; then
  short="$(printf '%s' "$body" | head -c 1600)"
  curl -s -o /dev/null -H "Content-Type: application/json" \
    -d "$(json content "**$TITLE**
$short")" \
    "$DISCORD_WEBHOOK_URL"
  echo "Posted to Discord."
fi
