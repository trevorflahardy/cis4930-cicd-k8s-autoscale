#!/usr/bin/env bash
# Post-deploy verification: infrastructure exists, the app works end to end.
# Exits nonzero if any check fails. EXPECTED_VERSION (optional) pins the deployed tag.
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

# json <field>: print one top-level field of the JSON document on stdin (empty if absent).
json() { jq -r --arg k "$1" '.[$k] // empty'; }

APP_DIR="$ROOT/infra/03-app"
DOCKER_API_URL="$(terraform -chdir="$APP_DIR" output -raw api_docker_url)"
DOCKER_API="$(terraform -chdir="$APP_DIR" output -raw api_docker_container)"

section "Docker runtime (kreuzwerker/docker resources)"
docker ps --filter "name=$CLUSTER" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
check "Postgres container is healthy" \
  bash -c "docker inspect -f '{{.State.Health.Status}}' '$POSTGRES_CONTAINER' | grep -qx healthy"
check "Redis container is healthy" \
  bash -c "docker inspect -f '{{.State.Health.Status}}' '$REDIS_CONTAINER' | grep -qx healthy"
check "kind nodes and databases share the '$DOCKER_NETWORK' network" \
  bash -c "docker network inspect '$DOCKER_NETWORK' -f '{{range .Containers}}{{.Name}} {{end}}' \
    | grep -q '$POSTGRES_CONTAINER' && docker network inspect '$DOCKER_NETWORK' \
    -f '{{range .Containers}}{{.Name}} {{end}}' | grep -q '$CLUSTER-control-plane'"
check "Postgres data lives on a named volume" \
  bash -c "docker inspect -f '{{range .Mounts}}{{.Type}}:{{.Name}} {{end}}' '$POSTGRES_CONTAINER' | grep -q 'volume:$CLUSTER-postgres-data'"

section "Kubernetes (kind) cluster"
kubectl get nodes -o wide
check "all nodes Ready" \
  bash -c "! kubectl get nodes --no-headers | awk '{print \$2}' | grep -vqx Ready"
check "migration Job completed" \
  kubectl -n "$NAMESPACE" wait --for=condition=complete job -l app.kubernetes.io/name=orders-migrate --timeout=60s
check "orders-api Deployment available" \
  kubectl -n "$NAMESPACE" rollout status deploy/orders-api --timeout=120s
check "orders-worker Deployment available" \
  kubectl -n "$NAMESPACE" rollout status deploy/orders-worker --timeout=120s
check "HPA orders-api exists with CPU metrics" \
  bash -c "kubectl -n '$NAMESPACE' get hpa orders-api -o jsonpath='{.spec.metrics[0].resource.name}' | grep -qx cpu"
check "KEDA ScaledObject orders-worker is Ready" \
  kubectl -n "$NAMESPACE" wait --for=condition=Ready scaledobject/orders-worker --timeout=120s
check "metrics-server is serving pod metrics" \
  bash -c "for i in \$(seq 30); do kubectl top pods -n '$NAMESPACE' >/dev/null 2>&1 && exit 0; sleep 4; done; exit 1"
kubectl -n "$NAMESPACE" get deploy,svc,hpa,scaledobject,pods -o wide

section "Application through the NodePort ($BASE_URL)"
index="$(curl -fsS "$BASE_URL/")" || index="{}"
echo "GET /        -> $index"
check "GET / responds" test "$index" != "{}"
if [ -n "${EXPECTED_VERSION:-}" ]; then
  check "running version is $EXPECTED_VERSION" \
    test "$(echo "$index" | json version)" = "$EXPECTED_VERSION"
fi
check "GET /health returns 200" curl -fsS "$BASE_URL/health"
ready="$(curl -sS "$BASE_URL/ready")"
echo "GET /ready   -> $ready"
check "GET /ready reports postgres+redis ok (pod -> Docker data tier)" \
  bash -c "echo '$ready' | grep -q '\"postgres\":\"ok\"' && echo '$ready' | grep -q '\"redis\":\"ok\"'"

created="$(curl -fsS -X POST "$BASE_URL/orders" -H 'content-type: application/json' \
  -d '{"customer":"smoke-test","item":"widget","quantity":3,"unit_price_cents":1250}')" || created="{}"
echo "POST /orders -> $created"
order_id="$(echo "$created" | json id)"
check "POST /orders created an order" test -n "$order_id"
check "order total computed (3 x 1250 = 3750)" \
  test "$(echo "$created" | json total_cents)" = "3750"

cache_header="$(curl -fsS -D - -o /dev/null "$BASE_URL/orders/$order_id" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{print $2}')"
check "first read is a Redis cache HIT (write-through)" test "$cache_header" = "HIT"

status=""
for _ in $(seq 30); do
  status="$(curl -fsS "$BASE_URL/orders/$order_id" | json status)"
  [ "$status" = "processed" ] && break
  sleep 1
done
check "worker processed the order via the Redis queue" test "$status" = "processed"

check "unknown order returns 404" \
  test "$(curl -s -o /dev/null -w '%{http_code}' "$BASE_URL/orders/987654321")" = "404"
check "invalid order is rejected with 422" \
  test "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/orders" \
    -H 'content-type: application/json' -d '{"customer":"x","item":"y","quantity":0,"unit_price_cents":1}')" = "422"

section "Application container on Docker (kreuzwerker/docker, $DOCKER_API_URL)"
docker ps --filter "name=$DOCKER_API" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
check "app container $DOCKER_API is running and healthy" \
  bash -c "docker inspect -f '{{.State.Health.Status}}' '$DOCKER_API' | grep -qx healthy"
check "app container joined the '$DOCKER_NETWORK' network" \
  bash -c "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' '$DOCKER_API' | grep -qw '$DOCKER_NETWORK'"
docker_ready="$(curl -sS "$DOCKER_API_URL/ready")"
echo "GET /ready   -> $docker_ready"
check "app container reaches postgres + redis by container name" \
  bash -c "echo '$docker_ready' | grep -q '\"postgres\":\"ok\"' && echo '$docker_ready' | grep -q '\"redis\":\"ok\"'"
if [ -n "${EXPECTED_VERSION:-}" ]; then
  check "app container runs version $EXPECTED_VERSION" \
    test "$(curl -fsS "$DOCKER_API_URL/" | json version)" = "$EXPECTED_VERSION"
fi
check "app container serves the order created through Kubernetes (shared data tier)" \
  test "$(curl -fsS "$DOCKER_API_URL/orders/$order_id" | json id)" = "$order_id"

section "Data persisted in Postgres (queried directly in the container)"
row="$(docker exec "$POSTGRES_CONTAINER" psql -U orders -d orders -tAc \
  "SELECT status || '|' || processed_by FROM orders WHERE id = $order_id")"
echo "orders[$order_id] = $row"
check "row exists in Postgres with status processed" bash -c "[[ '$row' == processed\|orders-worker-* ]]"
check "Alembic recorded schema revision" \
  bash -c "docker exec '$POSTGRES_CONTAINER' psql -U orders -d orders -tAc 'SELECT version_num FROM alembic_version' | grep -q ."

curl -fsS "$BASE_URL/stats" && echo
finish
