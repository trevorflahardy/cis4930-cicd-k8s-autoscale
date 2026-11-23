#!/usr/bin/env bash
# Sourced by the test scripts; most of these variables are only used by the callers.
# shellcheck disable=SC2034

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM_DIR="$ROOT/infra/01-platform"
EVIDENCE_DIR="${EVIDENCE_DIR:-$ROOT/evidence}"
mkdir -p "$EVIDENCE_DIR"

tf_out() {
  terraform -chdir="$PLATFORM_DIR" output -raw "$1"
}

KUBECONFIG="$(tf_out kubeconfig_path)"
export KUBECONFIG
NAMESPACE="${NAMESPACE:-orders}"
BASE_URL="${BASE_URL:-$(tf_out api_url)}"
CLUSTER="$(tf_out cluster_name)"
DOCKER_NETWORK="$(tf_out docker_network)"
POSTGRES_CONTAINER="$(tf_out postgres_container)"
REDIS_CONTAINER="$(tf_out redis_container)"

failures=0

section() {
  printf '\n== %s\n' "$1"
}

# check <description> <command> [args...]
check() {
  local desc="$1"
  shift
  if "$@" &>/dev/null; then
    printf '  PASS %s\n' "$desc"
  else
    printf '  FAIL %s\n' "$desc"
    failures=$((failures + 1))
  fi
}

finish() {
  echo
  if ((failures == 0)); then
    echo "RESULT: all checks passed"
  else
    echo "RESULT: $failures check(s) failed"
  fi
  exit "$failures"
}
