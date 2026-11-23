#!/usr/bin/env bash
# Drive mock client load with k6 and prove both autoscalers react:
#   * HPA scales orders-api above its minimum on CPU
#   * KEDA scales orders-worker above its minimum on Redis queue depth
# k6 runs as a container on the kind Docker network, so it works the same on a laptop
# and on a GitHub-hosted runner. Writes a replica timeline to evidence/autoscale-timeline.csv.
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

K6_IMAGE="${K6_IMAGE:-grafana/k6:2.4.0}"
RATE="${RATE:-40}"
HOLD="${HOLD:-90s}"
TIMELINE="$EVIDENCE_DIR/autoscale-timeline.csv"
TARGET_URL="http://$CLUSTER-control-plane:$(tf_out api_node_port)"

replicas() { kubectl -n "$NAMESPACE" get deploy "$1" -o jsonpath='{.status.replicas}' 2>/dev/null || echo 0; }

api_min="$(kubectl -n "$NAMESPACE" get hpa orders-api -o jsonpath='{.spec.minReplicas}')"
worker_min="$(kubectl -n "$NAMESPACE" get scaledobject orders-worker -o jsonpath='{.spec.minReplicaCount}')"

section "Baseline"
echo "orders-api replicas:    $(replicas orders-api) (HPA min $api_min)"
echo "orders-worker replicas: $(replicas orders-worker) (KEDA min $worker_min)"

docker pull -q "$K6_IMAGE" >/dev/null

section "Load: k6 ramping to $RATE req/s, hold $HOLD -> $TARGET_URL"
docker run --rm --network "$DOCKER_NETWORK" \
  -v "$ROOT/tests/load:/scripts:ro" -v "$EVIDENCE_DIR:/out" \
  -e BASE_URL="$TARGET_URL" -e RATE="$RATE" -e HOLD="$HOLD" \
  "$K6_IMAGE" run --quiet /scripts/orders.js >"$EVIDENCE_DIR/k6-output.txt" 2>&1 &
k6_pid=$!

echo "elapsed_s,api_replicas,api_cpu_percent,worker_replicas,queue_depth" >"$TIMELINE"
printf '%-8s %-13s %-9s %-16s %s\n' elapsed api_replicas api_cpu worker_replicas queue_depth
api_peak=0
worker_peak=0
start=$SECONDS
while kill -0 "$k6_pid" 2>/dev/null; do
  api="$(replicas orders-api)"
  worker="$(replicas orders-worker)"
  cpu="$(kubectl -n "$NAMESPACE" get hpa orders-api \
    -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)"
  depth="$(curl -fsS -m 3 "$BASE_URL/stats" 2>/dev/null | jq -r .queue_depth 2>/dev/null || echo "?")"
  elapsed=$((SECONDS - start))
  printf '%-8s %-13s %-9s %-16s %s\n' "${elapsed}s" "$api" "${cpu:-?}%" "$worker" "$depth"
  echo "$elapsed,$api,${cpu:-},$worker,$depth" >>"$TIMELINE"
  [ "${api:-0}" -gt "$api_peak" ] && api_peak=$api
  [ "${worker:-0}" -gt "$worker_peak" ] && worker_peak=$worker
  sleep 5
done
wait "$k6_pid"
k6_status=$?

section "k6 results"
if [ -f "$EVIDENCE_DIR/k6-summary.json" ]; then
  jq -r '.metrics as $m | [
    "requests:       \($m.http_reqs.values.count) (\($m.http_reqs.values.rate | floor) req/s)",
    "failed:         \(($m.http_req_failed.values.rate * 100) | tostring | .[0:5])%",
    "latency p50:    \($m.http_req_duration.values["p(50)"] | floor) ms",
    "latency p95:    \($m.http_req_duration.values["p(95)"] | floor) ms",
    "checks passed:  \(($m.checks.values.rate * 100) | tostring | .[0:5])%"
  ] | .[]' "$EVIDENCE_DIR/k6-summary.json"
else
  tail -n 20 "$EVIDENCE_DIR/k6-output.txt"
fi

section "Scaling events"
kubectl -n "$NAMESPACE" describe hpa orders-api | sed -n '/Events:/,$p' | tail -n 10
kubectl -n "$NAMESPACE" get events --field-selector involvedObject.name=orders-worker \
  --sort-by=.lastTimestamp 2>/dev/null | tail -n 10

section "Assertions"
echo "peak orders-api replicas:    $api_peak (min $api_min)"
echo "peak orders-worker replicas: $worker_peak (min $worker_min)"
check "k6 thresholds met (error rate < 2%)" test "$k6_status" -eq 0
check "HPA scaled orders-api above min ($api_peak > $api_min)" test "$api_peak" -gt "$api_min"
check "KEDA scaled orders-worker above min ($worker_peak > $worker_min)" test "$worker_peak" -gt "$worker_min"

section "Queue drains after the burst"
drained=1
for _ in $(seq 36); do
  depth="$(curl -fsS "$BASE_URL/stats" | jq -r .queue_depth)"
  [ "$depth" = "0" ] && drained=0 && break
  sleep 5
done
curl -fsS "$BASE_URL/stats" && echo
check "workers drained the queue to 0" test "$drained" -eq 0
finish
