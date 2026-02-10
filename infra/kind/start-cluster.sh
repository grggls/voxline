#!/bin/bash
set -euo pipefail

CLUSTER_NAME="voxline"
NODE_CONTAINER="voxline-control-plane"

if ! docker ps -a --format '{{.Names}}' | grep -q "^${NODE_CONTAINER}$"; then
  echo "Cluster '${CLUSTER_NAME}' does not exist. Create it with 'make cluster-up'."
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -q "^${NODE_CONTAINER}$"; then
  echo "Cluster '${CLUSTER_NAME}' is already running."
  exit 0
fi

echo "Starting kind cluster '${CLUSTER_NAME}'..."
docker start "$NODE_CONTAINER"

echo "Waiting for cluster to become ready..."
kubectl config use-context "kind-${CLUSTER_NAME}"

# Wait for the API server to respond
for i in $(seq 1 30); do
  if kubectl cluster-info --context "kind-${CLUSTER_NAME}" &>/dev/null; then
    break
  fi
  echo "  Waiting for API server... ($i/30)"
  sleep 2
done

# Wait for system pods to stabilize
echo "Waiting for system pods to restart..."
kubectl wait --for=condition=ready pods --all -n kube-system --timeout=120s 2>/dev/null || true

echo ""
echo "=== Cluster '${CLUSTER_NAME}' is running ==="
kubectl get nodes
echo ""
echo "Pods resuming — give 30-60s for all workloads to stabilize."
echo "Check status: make cluster-status"
