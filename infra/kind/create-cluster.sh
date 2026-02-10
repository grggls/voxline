#!/bin/bash
set -euo pipefail

CLUSTER_NAME="voxline"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Preflight checks ---
for cmd in kind kubectl helm docker; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is not installed. Install it before proceeding."
    exit 1
  fi
done

if ! docker info &>/dev/null; then
  echo "ERROR: Docker daemon is not running."
  exit 1
fi

# Check for port conflicts
for port in 8080 8443 30000 9090 4222 8222 27017 6379 11434; do
  if lsof -i :"$port" -sTCP:LISTEN &>/dev/null; then
    echo "WARNING: Port $port is already in use."
    echo "  Check with: lsof -i :$port"
    echo "  Stop the conflicting process or change the hostPort in cluster-config.yaml"
    exit 1
  fi
done

# --- Create cluster ---
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "Cluster '${CLUSTER_NAME}' already exists. Delete it first with 'make cluster-down'."
  exit 1
fi

echo "Creating kind cluster '${CLUSTER_NAME}'..."
kind create cluster --name "$CLUSTER_NAME" --config "$SCRIPT_DIR/cluster-config.yaml"

echo "Creating voxline namespace..."
kubectl create namespace voxline

# --- Install nginx Ingress controller ---
echo "Installing nginx Ingress controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=NodePort \
  --set controller.watchIngressWithoutClass=true

echo "Waiting for Ingress controller to be ready..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

echo ""
echo "=== Cluster '${CLUSTER_NAME}' is ready ==="
echo "  Namespace:  voxline"
echo "  Ingress:    nginx (ports 8080, 8443)"
echo "  Context:    kind-${CLUSTER_NAME}"
echo ""
echo "  Host port mappings (available after services are deployed):"
echo "    http://localhost:8080      Gateway / UI (via Ingress)"
echo "    http://localhost:30000     Grafana       (admin / voxline)"
echo "    http://localhost:9090      Prometheus"
echo "    nats://localhost:4222      NATS client"
echo "    http://localhost:8222      NATS monitoring"
echo "    mongodb://localhost:27017  MongoDB"
echo "    redis://localhost:6379     Redis"
echo "    http://localhost:11434     Ollama API"
echo ""
echo "Next: run 'make foundations-up' to install observability stack."
