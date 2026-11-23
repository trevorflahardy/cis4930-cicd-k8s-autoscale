#!/usr/bin/env bash
# Re-plan every stage after the tests; any pending change counts as drift.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${TF_VAR_image:?TF_VAR_image must be set to the deployed image}"

failures=0
for stage in 01-platform 02-addons 03-app; do
  echo "== terraform plan ($stage)"
  # Keep the plan's exit code; piping straight into grep would swallow it.
  out="$(terraform -chdir="$ROOT/infra/$stage" plan -detailed-exitcode -input=false -lock=false -no-color 2>&1)"
  code=$?

  if ((code == 1)); then
    tail -n 20 <<<"$out"
  else
    grep -E '^(No changes|Plan:|  # )' <<<"$out"
  fi

  case $code in
    0) echo "   PASS: no changes" ;;
    2) echo "   FAIL: drift detected"; failures=$((failures + 1)) ;;
    *) echo "   FAIL: plan errored ($code)"; failures=$((failures + 1)) ;;
  esac
done
exit "$failures"
