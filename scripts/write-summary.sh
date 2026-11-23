#!/usr/bin/env bash
# Render evidence/ into a Markdown report (GitHub Actions job summary).
# Usage: scripts/write-summary.sh >> "$GITHUB_STEP_SUMMARY"
set -uo pipefail
EVIDENCE_DIR="${EVIDENCE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/evidence}"

strip() { sed 's/\x1b\[[0-9;]*m//g' "$1"; }

results() {
  local file="$EVIDENCE_DIR/$1"
  [ -f "$file" ] || { echo "_not run_"; return; }
  local passed failed
  passed="$(strip "$file" | grep -c 'PASS' || true)"
  failed="$(strip "$file" | grep -c 'FAIL' || true)"
  echo "**${passed} passed, ${failed} failed**"
  echo
  echo '| | Check |'
  echo '|---|---|'
  strip "$file" | grep -E '^[[:space:]]+(PASS|FAIL)' | sed -E 's/^[[:space:]]+PASS (.*)/| ✅ | \1 |/; s/^[[:space:]]+FAIL (.*)/| ❌ | \1 |/'
}

echo "# Orders platform: deployment report"
echo
echo "Image \`${TF_VAR_image:-unknown}\` deployed by Terraform to a kind cluster + Docker data tier on this runner."
echo
echo "## Smoke tests"
results smoke-test.txt
echo
echo "## Autoscaling under load"
results autoscale-test.txt
if [ -f "$EVIDENCE_DIR/autoscale-timeline.csv" ]; then
  echo
  echo '<details><summary>Replica timeline (sampled every 5s during the k6 burst)</summary>'
  echo
  echo '| t (s) | API pods (HPA) | API CPU % | Worker pods (KEDA) | Queue depth |'
  echo '|---:|---:|---:|---:|---:|'
  tail -n +2 "$EVIDENCE_DIR/autoscale-timeline.csv" | awk -F, '{printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5}'
  echo
  echo '</details>'
fi
if [ -f "$EVIDENCE_DIR/k6-summary.json" ]; then
  echo
  jq -r '"k6: \(.metrics.http_reqs.values.count) requests, " +
    "\(.metrics.http_reqs.values.rate | floor) req/s, " +
    "p95 \(.metrics.http_req_duration.values["p(95)"] | floor) ms, " +
    "errors \((.metrics.http_req_failed.values.rate * 100) | tostring | .[0:4])%"' \
    "$EVIDENCE_DIR/k6-summary.json" 2>/dev/null || true
fi
echo
echo "## Terraform drift check (second plan)"
if [ -f "$EVIDENCE_DIR/drift-check.txt" ]; then
  echo '```'
  strip "$EVIDENCE_DIR/drift-check.txt"
  echo '```'
else
  echo "_not run_"
fi
if [ -f "$EVIDENCE_DIR/kubernetes.txt" ]; then
  echo
  echo '<details><summary>Kubernetes resources</summary>'
  echo
  echo '```'
  sed -n '1,60p' "$EVIDENCE_DIR/kubernetes.txt"
  echo '```'
  echo '</details>'
fi
