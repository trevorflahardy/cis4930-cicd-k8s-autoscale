#!/usr/bin/env bash
# Import a locally built Docker image into every kind node's containerd store.
# Called by Terraform (infra/03-app) with IMAGE and NODES in the environment.
set -euo pipefail

: "${IMAGE:?IMAGE is required}"
: "${NODES:?NODES is required}"

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "image $IMAGE not found in the local Docker daemon; build it first" >&2
  exit 1
fi

for node in $NODES; do
  echo "loading $IMAGE into $node"
  docker save "$IMAGE" | docker exec -i "$node" \
    ctr --namespace=k8s.io images import --digests --snapshotter=overlayfs -
done

for node in $NODES; do
  docker exec "$node" crictl inspecti "$IMAGE" >/dev/null 2>&1 \
    || docker exec "$node" crictl inspecti "docker.io/library/$IMAGE" >/dev/null
  echo "verified $IMAGE on $node"
done
