#!/usr/bin/env bash
# Re-plan every Terraform stage after deployment and testing. Exit code 2 from
# `terraform plan -detailed-exitcode` means drift; this script fails in that case.
# Requires TF_VAR_image for stage 3.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
: "${TF_VAR_image:?TF_VAR_image must be set to the deployed image}"

failures=0
for stage in 01-platform 02-addons 03-app; do
  echo "== terraform plan ($stage)"
  out="$(terraform -chdir="$ROOT/infra/$stage" plan -detailed-exitcode -input=false -lock=false -no-color 2>&1)"
  code=$?
  if [ "$code" -eq 1 ]; then
    echo "$out" | tail -n 20
  else
    echo "$out" | grep -E '^(No changes|Plan:|  # )' || true
  fi
  case "$code" in
    0) echo "   PASS: no changes" ;;
    2) echo "   FAIL: drift detected"; failures=$((failures + 1)) ;;
    *) echo "   FAIL: plan errored ($code)"; failures=$((failures + 1)) ;;
  esac
done
exit "$failures"
