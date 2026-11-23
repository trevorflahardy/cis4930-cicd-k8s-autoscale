#!/usr/bin/env bash
# Post-deploy smoke test. Set EXPECTED_VERSION to also check the deployed tag.
# The predicates below only run through check(), which shellcheck can't see.
# shellcheck disable=SC2317,SC2329
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

APP_DIR="$ROOT/infra/03-app"
DOCKER_API_URL="$(terraform -chdir="$APP_DIR" output -raw api_docker_url)"
DOCKER_API="$(terraform -chdir="$APP_DIR" output -raw api_docker_container)"

json() { jq -r --arg k "$1" '.[$k] // empty'; }
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
pg_query() { docker exec "$POSTGRES_CONTAINER" psql -U orders -d orders -tAc "$1"; }

healthy() { [[ "$(docker inspect -f '{{.State.Health.Status}}' "$1")" == healthy ]]; }
deps_ok() { [[ $1 == *'"postgres":"ok"'* && $1 == *'"redis":"ok"'* ]]; }
nodes_ready() {
  local statuses
  statuses="$(kubectl get nodes --no-headers | awk '{print $2}')" || return 1
  [[ -n $statuses ]] && ! grep -vqx Ready <<<"$statuses"
}
schema_versioned() { pg_query 'SELECT version_num FROM alembic_version' | grep -q .; }

shares_network() {
  local members
  members="$(docker network inspect "$DOCKER_NETWORK" -f '{{range .Containers}}{{.Name}} {{end}}')"
  [[ $members == *"$POSTGRES_CONTAINER"* && $members == *"$CLUSTER-control-plane"* ]]
}

has_volume() {
  local mounts
  mounts="$(docker inspect -f '{{range .Mounts}}{{.Type}}:{{.Name}} {{end}}' "$1")"
  [[ $mounts == *"volume:$2"* ]]
}

on_network() {
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$1" \
    | grep -qw "$DOCKER_NETWORK"
}

hpa_uses_cpu() {
  local metric
  metric="$(kubectl -n "$NAMESPACE" get hpa orders-api -o jsonpath='{.spec.metrics[0].resource.name}')"
  [[ $metric == cpu ]]
}

pod_metrics_available() {
  local _
  for _ in {1..30}; do
    kubectl top pods -n "$NAMESPACE" && return 0
    sleep 4
  done
  return 1
}

section "Docker runtime (kreuzwerker/docker resources)"
docker ps --filter "name=$CLUSTER" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
check "Postgres container is healthy" healthy "$POSTGRES_CONTAINER"
check "Redis container is healthy" healthy "$REDIS_CONTAINER"
check "kind nodes and databases share the '$DOCKER_NETWORK' network" shares_network
check "Postgres data lives on a named volume" has_volume "$POSTGRES_CONTAINER" "$CLUSTER-postgres-data"

section "Kubernetes (kind) cluster"
kubectl get nodes -o wide
check "all nodes Ready" nodes_ready
check "migration Job completed" \
  kubectl -n "$NAMESPACE" wait --for=condition=complete job -l app.kubernetes.io/name=orders-migrate --timeout=60s
check "orders-api Deployment available" \
  kubectl -n "$NAMESPACE" rollout status deploy/orders-api --timeout=120s
check "orders-worker Deployment available" \
  kubectl -n "$NAMESPACE" rollout status deploy/orders-worker --timeout=120s
check "HPA orders-api exists with CPU metrics" hpa_uses_cpu
check "KEDA ScaledObject orders-worker is Ready" \
  kubectl -n "$NAMESPACE" wait --for=condition=Ready scaledobject/orders-worker --timeout=120s
check "metrics-server is serving pod metrics" pod_metrics_available
kubectl -n "$NAMESPACE" get deploy,svc,hpa,scaledobject,pods -o wide

section "Application through the NodePort ($BASE_URL)"
index="$(curl -fsS "$BASE_URL/")" || index="{}"
echo "GET /        -> $index"
check "GET / responds" test "$index" != "{}"
if [[ -n "${EXPECTED_VERSION:-}" ]]; then
  check "running version is $EXPECTED_VERSION" test "$(json version <<<"$index")" = "$EXPECTED_VERSION"
fi
check "GET /health returns 200" curl -fsS "$BASE_URL/health"
ready="$(curl -sS "$BASE_URL/ready")"
echo "GET /ready   -> $ready"
check "GET /ready reports postgres+redis ok (pod -> Docker data tier)" deps_ok "$ready"

created="$(curl -fsS -X POST "$BASE_URL/orders" -H 'content-type: application/json' \
  -d '{"customer":"smoke-test","item":"widget","quantity":3,"unit_price_cents":1250}')" || created="{}"
echo "POST /orders -> $created"
order_id="$(json id <<<"$created")"
check "POST /orders created an order" test -n "$order_id"
check "order total computed (3 x 1250 = 3750)" test "$(json total_cents <<<"$created")" = 3750

cache="$(curl -fsS -D - -o /dev/null "$BASE_URL/orders/$order_id" \
  | tr -d '\r' | awk -F': ' 'tolower($1) == "x-cache" {print $2}')"
check "first read is a Redis cache HIT (write-through)" test "$cache" = HIT

status=""
for _ in {1..30}; do
  status="$(curl -fsS "$BASE_URL/orders/$order_id" | json status)"
  [[ $status == processed ]] && break
  sleep 1
done
check "worker processed the order via the Redis queue" test "$status" = processed

check "unknown order returns 404" test "$(http_code "$BASE_URL/orders/987654321")" = 404
check "invalid order is rejected with 422" \
  test "$(http_code -X POST "$BASE_URL/orders" -H 'content-type: application/json' \
    -d '{"customer":"x","item":"y","quantity":0,"unit_price_cents":1}')" = 422

section "Application container on Docker (kreuzwerker/docker, $DOCKER_API_URL)"
docker ps --filter "name=$DOCKER_API" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
check "app container $DOCKER_API is running and healthy" healthy "$DOCKER_API"
check "app container joined the '$DOCKER_NETWORK' network" on_network "$DOCKER_API"
docker_ready="$(curl -sS "$DOCKER_API_URL/ready")"
echo "GET /ready   -> $docker_ready"
check "app container reaches postgres + redis by container name" deps_ok "$docker_ready"
if [[ -n "${EXPECTED_VERSION:-}" ]]; then
  check "app container runs version $EXPECTED_VERSION" \
    test "$(curl -fsS "$DOCKER_API_URL/" | json version)" = "$EXPECTED_VERSION"
fi
check "app container serves the order created through Kubernetes (shared data tier)" \
  test "$(curl -fsS "$DOCKER_API_URL/orders/$order_id" | json id)" = "$order_id"

section "Data persisted in Postgres (queried directly in the container)"
row="$(pg_query "SELECT status || '|' || processed_by FROM orders WHERE id = $order_id")"
echo "orders[$order_id] = $row"
check "row exists in Postgres with status processed" grep -q '^processed|orders-worker-' <<<"$row"
check "Alembic recorded schema revision" schema_versioned

curl -fsS "$BASE_URL/stats" && echo
finish
