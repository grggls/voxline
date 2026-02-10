#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "=== Installing Cluster Foundations ==="
echo ""

# --- Verify StorageClass ---
echo "Verifying StorageClass..."
SC=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$SC" ]; then
  echo "ERROR: No StorageClass found. Kind should have 'standard' by default."
  exit 1
fi
echo "  StorageClass: $SC"

# --- Helm repos ---
echo ""
echo "Adding Helm repos..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update

# --- metrics-server ---
echo ""
echo "Installing metrics-server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  -f "$PROJECT_ROOT/infra/helm/metrics-server-values.yaml"

# --- kube-prometheus-stack ---
echo ""
echo "Installing kube-prometheus-stack (Prometheus + Grafana)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Apply the dashboard ConfigMap before Helm install so Grafana picks it up
kubectl apply -f "$PROJECT_ROOT/infra/grafana/dashboard-configmap.yaml"

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f "$PROJECT_ROOT/infra/helm/prometheus-stack-values.yaml" \
  --timeout 5m

# --- OTel Collector ---
echo ""
echo "Installing OpenTelemetry Collector..."
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring \
  -f "$PROJECT_ROOT/infra/helm/otel-collector-values.yaml"

# --- Wait for all pods ---
echo ""
echo "Waiting for pods to be ready..."
kubectl wait --for=condition=ready pods --all -n kube-system --timeout=120s 2>/dev/null || true
kubectl wait --for=condition=ready pods --all -n monitoring --timeout=180s 2>/dev/null || true

echo ""
echo "=== Cluster Foundations Installed ==="
echo ""
echo "  metrics-server:  kubectl top nodes"
echo "  Prometheus:       http://localhost:9090"
echo "  Grafana:          http://localhost:30000  (admin / voxline)"
echo "  OTel Collector:   OTLP gRPC on otel-collector.monitoring:4317"
echo "                    OTLP HTTP on otel-collector.monitoring:4318"
echo ""
echo "Next: run 'make infra-up' to deploy NATS, MongoDB, Redis."
