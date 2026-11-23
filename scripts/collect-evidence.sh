#!/usr/bin/env bash
# Snapshot the running deployment into evidence/ (git-ignored; uploaded as a CI artifact).
set -uo pipefail
# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"

capture() {
  local file="$EVIDENCE_DIR/$1"
  shift
  { echo "\$ $*"; "$@" 2>&1; echo; } >>"$file"
}

rm -f "$EVIDENCE_DIR"/{docker,kubernetes,terraform-outputs,app}.txt

capture docker.txt docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
capture docker.txt docker network inspect "$DOCKER_NETWORK" \
  -f '{{range .Containers}}{{.Name}}  {{.IPv4Address}}{{println}}{{end}}'
capture docker.txt docker volume ls --filter "name=$CLUSTER"

capture kubernetes.txt kubectl get nodes -o wide
capture kubernetes.txt kubectl -n "$NAMESPACE" get all,hpa,scaledobject,pdb,endpointslices -o wide
capture kubernetes.txt kubectl -n "$NAMESPACE" describe hpa orders-api
capture kubernetes.txt kubectl -n "$NAMESPACE" get scaledobject orders-worker -o yaml
capture kubernetes.txt kubectl top pods -n "$NAMESPACE"
capture kubernetes.txt kubectl -n "$NAMESPACE" logs job -l app.kubernetes.io/name=orders-migrate --tail=20

for stage in 01-platform 02-addons 03-app; do
  capture terraform-outputs.txt terraform -chdir="$ROOT/infra/$stage" output
  capture terraform-outputs.txt terraform -chdir="$ROOT/infra/$stage" state list
done

capture app.txt curl -sS "$BASE_URL/"
capture app.txt curl -sS "$BASE_URL/ready"
capture app.txt curl -sS "$BASE_URL/stats"

echo "evidence written to $EVIDENCE_DIR"
ls -1 "$EVIDENCE_DIR"
