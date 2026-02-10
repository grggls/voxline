#!/bin/bash
set -euo pipefail

CLUSTER_NAME="voxline"
NODE_CONTAINER="voxline-control-plane"

if ! docker ps -a --format '{{.Names}}' | grep -q "^${NODE_CONTAINER}$"; then
  echo "Cluster '${CLUSTER_NAME}' does not exist."
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -q "^${NODE_CONTAINER}$"; then
  echo "Stopping kind cluster '${CLUSTER_NAME}'..."
  docker stop "$NODE_CONTAINER"
  echo "Cluster stopped. All state (PVCs, pods, configs) is preserved."
  echo "Resume with: make cluster-start"
else
  echo "Cluster '${CLUSTER_NAME}' is already stopped."
fi
