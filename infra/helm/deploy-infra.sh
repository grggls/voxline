#!/bin/bash
set -euo pipefail

# Ensure Homebrew binaries (helm, kubectl) are on PATH
export PATH="/opt/homebrew/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Deploying Infrastructure (NATS, MongoDB, Redis) ==="
echo ""

# --- Helm repos ---
echo "Adding Helm repos..."
helm repo add nats https://nats-io.github.io/k8s/helm/charts/ 2>/dev/null || true
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# --- NATS (Core + JetStream) ---
echo ""
echo "Installing NATS..."
helm upgrade --install nats nats/nats \
  -n voxline \
  -f "$PROJECT_ROOT/infra/helm/nats-values.yaml" \
  --timeout 3m

# --- MongoDB ---
echo ""
echo "Installing MongoDB..."
helm upgrade --install mongodb bitnami/mongodb \
  -n voxline \
  -f "$PROJECT_ROOT/infra/helm/mongodb-values.yaml" \
  --timeout 3m

# --- Redis ---
echo ""
echo "Installing Redis..."
helm upgrade --install redis bitnami/redis \
  -n voxline \
  -f "$PROJECT_ROOT/infra/helm/redis-values.yaml" \
  --timeout 3m

# --- Wait for all pods ---
echo ""
echo "Waiting for pods to be ready..."
kubectl wait -n voxline --for=condition=ready pod -l app.kubernetes.io/name=nats --timeout=120s
kubectl wait -n voxline --for=condition=ready pod -l app.kubernetes.io/name=mongodb --timeout=120s
kubectl wait -n voxline --for=condition=ready pod -l app.kubernetes.io/name=redis --timeout=120s

# --- Create JetStream stream ---
echo ""
echo "Creating VOXLINE_EVENTS JetStream stream..."
kubectl exec -n voxline deploy/nats-box -- \
  nats stream add VOXLINE_EVENTS \
    --subjects "voxline.events.>" \
    --retention limits \
    --max-msgs 10000 \
    --max-age 24h \
    --storage file \
    --replicas 1 \
    --discard old \
    --defaults \
  2>/dev/null || echo "  Stream already exists (idempotent)"

echo ""
echo "=== Infrastructure Deployed ==="
echo ""
echo "  NATS:     nats://localhost:4222  (monitoring: http://localhost:8222)"
echo "  MongoDB:  mongodb://localhost:27017/voxline"
echo "  Redis:    redis://localhost:6379"
echo ""
echo "Next: run 'make ollama-up && make ollama-pull' to deploy Ollama and pull models."
