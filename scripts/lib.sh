#!/usr/bin/env bash
# Shared helpers for the verification scripts. Source, don't execute.
# Variables defined here are consumed by the scripts that source this file.
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

FAILURES=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# check "<description>" <command...>
check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

finish() {
  echo
  if [ "$FAILURES" -eq 0 ]; then
    echo "RESULT: all checks passed"
  else
    echo "RESULT: $FAILURES check(s) failed"
  fi
  exit "$FAILURES"
}
