#!/usr/bin/env bash
# DAST baseline scan with OWASP ZAP against the running instance.
# Passive + safe active baseline rules only (non-destructive). Report only:
# findings are written to reports/ and surfaced, but this does not fail the build.
# Per-rule severity is controlled by security/zap/rules.tsv.
set -uo pipefail

HOST="${PENPOT_HOST:-localhost}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPORTS_DIR="$DIR/reports"
TARGET="https://$HOST"

mkdir -p "$REPORTS_DIR"
chmod -R 777 "$REPORTS_DIR" || true

echo "Running ZAP baseline against $TARGET ..."
# --network host so the container can reach the host-published 443.
docker run --rm --network host \
  -v "$REPORTS_DIR:/zap/wrk:rw" \
  -v "$DIR/security/zap/rules.tsv:/zap/rules.tsv:ro" \
  ghcr.io/zaproxy/zaproxy:stable \
  zap-baseline.py -t "$TARGET" -c rules.tsv \
  -r zap-baseline.html -w zap-baseline.md -x zap-baseline.xml -I
rc=$?

echo "ZAP baseline report: $REPORTS_DIR/zap-baseline.html (exit $rc)"
# -I keeps this non-blocking; the pipeline notifies rather than fails on DAST warnings.
exit 0
