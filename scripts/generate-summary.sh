#!/usr/bin/env bash
# Generate a consolidated Markdown summary of all pipeline scan results.
# Usage: scripts/generate-summary.sh <collected-reports-dir>
#
# Expects job results as environment variables (set by the workflow):
#   SECRET_SCAN_RESULT, SAST_RESULT, SCA_RESULT, IAC_RESULT,
#   DEPLOY_RESULT, VALIDATE_RESULT
# and the downloaded artifacts tree under the given directory.
set -uo pipefail

REPORTS="${1:-.}"
OUT="$REPORTS/pipeline-summary.md"
DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/"
RUN_URL="${RUN_URL}actions/runs/${GITHUB_RUN_ID:-}"

# Helper: translate GitHub Actions job result to a status icon + label
status_icon() {
  case "${1:-skipped}" in
    success)   echo "PASS";;
    failure)   echo "FAIL";;
    cancelled) echo "SKIP";;
    skipped)   echo "SKIP";;
    *)         echo "UNKNOWN";;
  esac
}

# Helper: count SARIF findings (results array length)
sarif_count() {
  local f="$1"
  if [ -f "$f" ]; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
runs = d.get('runs', [])
total = sum(len(r.get('results', [])) for r in runs)
print(total)
" "$f" 2>/dev/null || echo "?"
  else
    echo "n/a"
  fi
}

# Helper: count Trivy JSON vulnerabilities
trivy_json_count() {
  local f="$1"
  if [ -f "$f" ]; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
results = d.get('Results', [])
total = sum(len(r.get('Vulnerabilities', [])) for r in results)
print(total)
" "$f" 2>/dev/null || echo "?"
  else
    echo "n/a"
  fi
}

# Helper: extract top Trivy findings (deduped CVE IDs)
trivy_json_top() {
  local f="$1"
  local n="${2:-5}"
  if [ -f "$f" ]; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as fh:
    d = json.load(fh)
seen = []
for r in d.get('Results', []):
    for v in r.get('Vulnerabilities', []):
        vid = v.get('VulnerabilityID','')
        sev = v.get('Severity','')
        pkg = v.get('PkgName','')
        if vid not in [s[0] for s in seen]:
            seen.append((vid, sev, pkg))
for vid, sev, pkg in seen[:int(sys.argv[2])]:
    print(f'  - {vid} ({sev}) in {pkg}')
" "$f" "$n" 2>/dev/null
  fi
}

# Start writing the report
cat > "$OUT" <<EOF
# DevSecOps Pipeline Summary

**Run date:** $DATE
**Run:** $RUN_URL
**Commit:** ${GITHUB_SHA:-unknown}

## Job Results

| Stage | Status | Details |
|-------|--------|---------|
| Secret Scan (gitleaks) | $(status_icon "$SECRET_SCAN_RESULT") | Gate: blocks deploy on leaked secrets |
| SAST (Semgrep + clj-kondo) | $(status_icon "$SAST_RESULT") | Report: upstream code findings |
| SCA (Trivy fs + images) | $(status_icon "$SCA_RESULT") | Report: dependency and image CVEs |
| IaC Hardening (Trivy config) | $(status_icon "$IAC_RESULT") | Gate: blocks deploy on misconfig in deploy/ |
| Secure Deployment | $(status_icon "$DEPLOY_RESULT") | Hardened Penpot stack |
| Post-deploy Validation | $(status_icon "$VALIDATE_RESULT") | Config audit + health + DAST |

EOF

# --- Secret scan details ---
echo "## Secret Scan" >> "$OUT"
gl_sarif="$(find "$REPORTS" -name 'gitleaks.sarif' 2>/dev/null | head -1)"
gl_count="$(sarif_count "$gl_sarif")"
if [ "$gl_count" = "0" ] || [ "$gl_count" = "n/a" ]; then
  echo "No hardcoded secrets detected." >> "$OUT"
else
  echo "**$gl_count finding(s).** Review the gitleaks-report artifact for file paths and matched rules." >> "$OUT"
fi
echo >> "$OUT"

# --- SAST details ---
echo "## Static Analysis (SAST)" >> "$OUT"
sg_sarif="$(find "$REPORTS" -name 'semgrep.sarif' 2>/dev/null | head -1)"
sg_count="$(sarif_count "$sg_sarif")"
echo "Semgrep findings: **$sg_count**" >> "$OUT"
clj_txt="$(find "$REPORTS" -name 'clj-kondo.txt' 2>/dev/null | head -1)"
if [ -f "$clj_txt" ]; then
  clj_warns="$(grep -c 'warning' "$clj_txt" 2>/dev/null || echo 0)"
  clj_errs="$(grep -c 'error' "$clj_txt" 2>/dev/null || echo 0)"
  echo "clj-kondo: $clj_errs error(s), $clj_warns warning(s)" >> "$OUT"
fi
echo >> "$OUT"

# --- SCA details ---
echo "## Software Composition Analysis (SCA)" >> "$OUT"
trivy_fs="$(find "$REPORTS" -name 'trivy-fs.sarif' 2>/dev/null | head -1)"
echo "Trivy filesystem scan findings: **$(sarif_count "$trivy_fs")**" >> "$OUT"
echo >> "$OUT"
for img in frontend backend exporter; do
  trivy_img="$(find "$REPORTS" -name "trivy-${img}.json" 2>/dev/null | head -1)"
  if [ -f "$trivy_img" ]; then
    count="$(trivy_json_count "$trivy_img")"
    echo "**penpotapp/${img}** image: $count vulnerability(ies)" >> "$OUT"
    top="$(trivy_json_top "$trivy_img" 5)"
    if [ -n "$top" ]; then
      echo "$top" >> "$OUT"
    fi
    echo >> "$OUT"
  fi
done

# --- IaC hardening ---
echo "## IaC / Deploy Config Hardening" >> "$OUT"
iac_sarif="$(find "$REPORTS" -name 'trivy-config.sarif' 2>/dev/null | head -1)"
iac_count="$(sarif_count "$iac_sarif")"
if [ "$iac_count" = "0" ] || [ "$iac_count" = "n/a" ]; then
  echo "No HIGH/CRITICAL misconfigurations in deploy/ files." >> "$OUT"
else
  echo "**$iac_count misconfiguration(s) detected.** This is a gating failure. Review the iac-report artifact." >> "$OUT"
fi
echo >> "$OUT"

# --- Config audit ---
echo "## Post-deploy Configuration Audit" >> "$OUT"
audit_txt="$(find "$REPORTS" -name 'config-audit.txt' 2>/dev/null | head -1)"
if [ -f "$audit_txt" ]; then
  pass_c="$(grep -c '^PASS:' "$audit_txt" 2>/dev/null || echo 0)"
  fail_c="$(grep -c '^FAIL:' "$audit_txt" 2>/dev/null || echo 0)"
  echo "$pass_c passed, $fail_c failed" >> "$OUT"
  if [ "$fail_c" -gt 0 ]; then
    echo "" >> "$OUT"
    echo "Failed checks:" >> "$OUT"
    grep '^FAIL:' "$audit_txt" | sed 's/^/  - /' >> "$OUT"
  fi
else
  echo "Config audit did not run (deploy may have been skipped)." >> "$OUT"
fi
echo >> "$OUT"

# --- Health check ---
echo "## Service Health" >> "$OUT"
health_txt="$(find "$REPORTS" -name 'health-check.txt' 2>/dev/null | head -1)"
if [ -f "$health_txt" ]; then
  tail -1 "$health_txt" >> "$OUT"
else
  echo "Health check did not run." >> "$OUT"
fi
echo >> "$OUT"

# --- DAST ---
echo "## DAST (OWASP ZAP Baseline)" >> "$OUT"
zap_md="$(find "$REPORTS" -name 'zap-baseline.md' 2>/dev/null | head -1)"
if [ -f "$zap_md" ]; then
  alerts="$(grep -cE '^\|' "$zap_md" 2>/dev/null || echo "?")"
  echo "ZAP baseline completed. See the validation-reports artifact for the full HTML report." >> "$OUT"
  echo "Alert rows in summary: $alerts" >> "$OUT"
else
  echo "ZAP baseline did not run or produced no output." >> "$OUT"
fi
echo >> "$OUT"

# --- Footer ---
cat >> "$OUT" <<'EOF'
---

*This summary was generated automatically by the DevSecOps pipeline. For full
details, download the individual job artifacts from the Actions run.*
EOF

echo "Summary report written to $OUT"
cat "$OUT"
