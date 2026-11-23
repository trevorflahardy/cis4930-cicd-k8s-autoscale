#!/usr/bin/env bash
# Render evidence/ as Markdown: scripts/write-summary.sh >> "$GITHUB_STEP_SUMMARY"
set -uo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/evidence}"

strip_ansi() {
  sed 's/\x1b\[[0-9;]*m//g' "$1"
}

results() {
  local file="$EVIDENCE_DIR/$1"
  if [[ ! -f "$file" ]]; then
    echo "_not run_"
    return
  fi

  local passed failed
  passed="$(strip_ansi "$file" | grep -c PASS)"
  failed="$(strip_ansi "$file" | grep -c FAIL)"

  printf '**%s passed, %s failed**\n\n' "$passed" "$failed"
  echo '| Check | Result |'
  echo '|---|---|'
  strip_ansi "$file" | sed -nE \
    -e 's/^[[:space:]]+PASS (.*)/| \1 | Pass |/p' \
    -e 's/^[[:space:]]+FAIL (.*)/| \1 | **Fail** |/p'
}

cat <<EOF
# Orders platform: deployment report

Image \`${TF_VAR_image:-unknown}\` deployed by Terraform to a kind cluster + Docker data tier on this runner.

## Smoke tests
EOF
results smoke-test.txt

printf '\n## Autoscaling under load\n'
results autoscale-test.txt

if [[ -f "$EVIDENCE_DIR/autoscale-timeline.csv" ]]; then
  cat <<'EOF'

<details><summary>Replica timeline (sampled every 5s during the k6 burst)</summary>

| t (s) | API pods (HPA) | API CPU % | Worker pods (KEDA) | Queue depth |
|---:|---:|---:|---:|---:|
EOF
  tail -n +2 "$EVIDENCE_DIR/autoscale-timeline.csv" \
    | awk -F, '{ printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }'
  printf '\n</details>\n'
fi

if [[ -f "$EVIDENCE_DIR/k6-summary.json" ]]; then
  echo
  jq -r '.metrics |
    "k6: \(.http_reqs.values.count) requests, " +
    "\(.http_reqs.values.rate | floor) req/s, " +
    "p95 \(.http_req_duration.values["p(95)"] | floor) ms, " +
    "errors \((.http_req_failed.values.rate * 100) | tostring | .[0:4])%"' \
    "$EVIDENCE_DIR/k6-summary.json" 2>/dev/null
fi

printf '\n## Terraform drift check (second plan)\n'
if [[ -f "$EVIDENCE_DIR/drift-check.txt" ]]; then
  echo '```'
  strip_ansi "$EVIDENCE_DIR/drift-check.txt"
  echo '```'
else
  echo "_not run_"
fi

if [[ -f "$EVIDENCE_DIR/kubernetes.txt" ]]; then
  printf '\n<details><summary>Kubernetes resources</summary>\n\n'
  echo '```'
  head -n 60 "$EVIDENCE_DIR/kubernetes.txt"
  echo '```'
  echo '</details>'
fi
