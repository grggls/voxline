# M1-02: Cluster Foundations (Observability, Metrics, Storage)

## Context

The `kind` cluster is running with the `voxline` namespace and nginx Ingress controller (from prompt-m1-01). Before deploying any application infrastructure (NATS, MongoDB, Redis, Ollama), install the "Day 1" cluster foundations that every production-modeled k8s environment needs:

1. **metrics-server** — makes `kubectl top` work (kind doesn't ship it)
2. **kube-prometheus-stack** — Prometheus (metrics collection) + Grafana (dashboards) + node-exporter + kube-state-metrics
3. **OpenTelemetry Collector** — ready to receive traces/metrics from services, forwards to Prometheus
4. **StorageClass verification** — confirm kind's local-path-provisioner is working

These components provide cluster health visibility from day one. When NATS, MongoDB, and Ollama are deployed later, their metrics are automatically scraped by Prometheus and visible in Grafana without additional configuration.

### Why Not a Service Mesh?

Voxline's inter-service communication goes through NATS, not HTTP. A service mesh (Linkerd, Istio) intercepts HTTP/gRPC traffic — it wouldn't see the NATS messages at all. The only HTTP paths are UI→Gateway and LLM Service→Ollama. The complexity and resource cost (~200-500MB RAM) isn't justified for this project's communication patterns.

## Resource Budget (Foundations Layer)

| Component | CPU Request | CPU Limit | RAM Request | RAM Limit |
| --- | --- | --- | --- | --- |
| metrics-server | 50m | 100m | 50 Mi | 100 Mi |
| Prometheus | 200m | 500m | 256 Mi | 512 Mi |
| Grafana | 100m | 200m | 128 Mi | 256 Mi |
| node-exporter | 50m | 100m | 32 Mi | 64 Mi |
| kube-state-metrics | 50m | 100m | 64 Mi | 128 Mi |
| OTel Collector | 100m | 200m | 64 Mi | 128 Mi |
| **Total** | **550m** | **1200m** | **594 Mi** | **1188 Mi** |

This adds ~600 Mi RAM request to the cluster. On a 16GB machine, this is comfortable — the full stack (foundations + infra + services) will use ~3-4 Gi total with ~2 Gi Docker overhead = ~6 Gi. Plenty of room.

## What to Build

### 1. metrics-server

Kind doesn't include metrics-server. Without it, `kubectl top pods` and `kubectl top nodes` return errors, and the Horizontal Pod Autoscaler can't function.

Create `infra/helm/metrics-server-values.yaml`:

```yaml
# kubernetes-sigs/metrics-server chart
args:
  - --kubelet-insecure-tls      # Required for kind — kubelet uses self-signed certs
resources:
  requests:
    cpu: 50m
    memory: 50Mi
  limits:
    cpu: 100m
    memory: 100Mi
```

### 2. kube-prometheus-stack (Prometheus + Grafana)

This is the standard community chart that bundles Prometheus, Grafana, node-exporter, kube-state-metrics, and pre-built Kubernetes dashboards.

Create `infra/helm/prometheus-stack-values.yaml`:

```yaml
# prometheus-community/kube-prometheus-stack chart

# --- Prometheus ---
prometheus:
  service:
    type: NodePort
    nodePort: 30090                   # Accessible at http://localhost:9090
  prometheusSpec:
    resources:
      requests:
        cpu: 200m
        memory: 256Mi
      limits:
        cpu: 500m
        memory: 512Mi
    retention: 24h                    # Keep 24h of metrics — sufficient for local dev
    storageSpec:
      volumeClaimTemplate:
        spec:
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 2Gi
    # Scrape all ServiceMonitors in all namespaces
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false

# --- Grafana ---
grafana:
  adminUser: admin
  adminPassword: voxline            # Local dev only — not a secret
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 200m
      memory: 256Mi
  service:
    type: NodePort
    nodePort: 30000                  # Accessible at http://localhost:30000
  # Pre-provision Voxline dashboard
  dashboardProviders:
    dashboardproviders.yaml:
      apiVersion: 1
      providers:
        - name: voxline
          orgId: 1
          folder: Voxline
          type: file
          disableDeletion: false
          editable: true
          options:
            path: /var/lib/grafana/dashboards/voxline
  dashboardsConfigMaps:
    voxline: grafana-voxline-dashboard
  sidecar:
    dashboards:
      enabled: true
      searchNamespace: ALL

# --- node-exporter ---
nodeExporter:
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

# --- kube-state-metrics ---
kube-state-metrics:
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 100m
      memory: 128Mi

# --- Alertmanager (disabled — not needed for learning project) ---
alertmanager:
  enabled: false
```

### 3. Voxline Grafana dashboard ConfigMap

Create `infra/grafana/voxline-dashboard.json` — a Grafana dashboard that shows Voxline namespace health at a glance:

```json
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 0,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Pod Status (voxline namespace)",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "targets": [{
        "expr": "count(kube_pod_status_phase{namespace=\"voxline\", phase=\"Running\"})",
        "legendFormat": "Running"
      }],
      "fieldConfig": {
        "defaults": { "thresholds": { "steps": [{"color": "green", "value": null}] } }
      }
    },
    {
      "title": "Pod Restarts (last 1h)",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "targets": [{
        "expr": "sum(increase(kube_pod_container_status_restarts_total{namespace=\"voxline\"}[1h]))",
        "legendFormat": "Restarts"
      }],
      "fieldConfig": {
        "defaults": { "thresholds": { "steps": [
          {"color": "green", "value": null},
          {"color": "yellow", "value": 1},
          {"color": "red", "value": 5}
        ]}}
      }
    },
    {
      "title": "CPU Usage by Pod",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "targets": [{
        "expr": "sum(rate(container_cpu_usage_seconds_total{namespace=\"voxline\", container!=\"\"}[5m])) by (pod)",
        "legendFormat": "{{pod}}"
      }],
      "fieldConfig": { "defaults": { "unit": "short" } }
    },
    {
      "title": "Memory Usage by Pod",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "targets": [{
        "expr": "sum(container_memory_working_set_bytes{namespace=\"voxline\", container!=\"\"}) by (pod)",
        "legendFormat": "{{pod}}"
      }],
      "fieldConfig": { "defaults": { "unit": "bytes" } }
    },
    {
      "title": "Network I/O by Pod",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "targets": [
        {
          "expr": "sum(rate(container_network_receive_bytes_total{namespace=\"voxline\"}[5m])) by (pod)",
          "legendFormat": "{{pod}} rx"
        },
        {
          "expr": "sum(rate(container_network_transmit_bytes_total{namespace=\"voxline\"}[5m])) by (pod)",
          "legendFormat": "{{pod}} tx"
        }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps" } }
    },
    {
      "title": "PVC Usage",
      "type": "bargauge",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "targets": [{
        "expr": "kubelet_volume_stats_used_bytes{namespace=\"voxline\"} / kubelet_volume_stats_capacity_bytes{namespace=\"voxline\"}",
        "legendFormat": "{{persistentvolumeclaim}}"
      }],
      "fieldConfig": {
        "defaults": {
          "unit": "percentunit",
          "max": 1,
          "thresholds": { "steps": [
            {"color": "green", "value": null},
            {"color": "yellow", "value": 0.7},
            {"color": "red", "value": 0.9}
          ]}
        }
      }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 39,
  "tags": ["voxline"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "title": "Voxline System Health",
  "uid": "voxline-system-health"
}
```

Create `infra/grafana/dashboard-configmap.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-voxline-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"          # Grafana sidecar picks this up automatically
data:
  voxline-system-health.json: |
    # (contents of voxline-dashboard.json — inline the JSON here)
```

### 4. OpenTelemetry Collector

The OTel Collector runs as a deployment, ready to receive OTLP traces and metrics from services. In M1-M3, services use lightweight request tracing (requestId + timestamps). In M4, services can switch to emitting OTLP traces — the collector is already running.

Create `infra/helm/otel-collector-values.yaml`:

```yaml
# open-telemetry/opentelemetry-collector chart
mode: deployment
replicaCount: 1

resources:
  requests:
    cpu: 100m
    memory: 64Mi
  limits:
    cpu: 200m
    memory: 128Mi

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  processors:
    batch:
      timeout: 5s
      send_batch_size: 256
    memory_limiter:
      check_interval: 1s
      limit_mib: 100

  exporters:
    # Forward metrics to Prometheus via remote write
    prometheusremotewrite:
      endpoint: "http://kube-prometheus-stack-prometheus.monitoring.svc.cluster.local:9090/api/v1/write"
    # Log traces to stdout for debugging (until a proper trace backend is added)
    debug:
      verbosity: basic

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [debug]
      metrics:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [prometheusremotewrite]
```

### 5. Deployment script

Create `infra/helm/deploy-foundations.sh`:

```bash
#!/bin/bash
set -euo pipefail

echo "=== Installing Cluster Foundations ==="
echo ""

# --- Verify StorageClass ---
echo "Verifying StorageClass..."
SC=$(kubectl get storageclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -z "$SC" ]; then
  echo "ERROR: No StorageClass found. Kind should have 'standard' by default."
  exit 1
fi
echo "  StorageClass: $SC ✓"

# --- Helm repos ---
echo ""
echo "Adding Helm repos..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

# --- metrics-server ---
echo ""
echo "Installing metrics-server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  -f infra/helm/metrics-server-values.yaml

# --- kube-prometheus-stack ---
echo ""
echo "Installing kube-prometheus-stack (Prometheus + Grafana)..."
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -

# Apply the dashboard ConfigMap before Helm install so Grafana picks it up
kubectl apply -f infra/grafana/dashboard-configmap.yaml

helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f infra/helm/prometheus-stack-values.yaml \
  --timeout 5m

# --- OTel Collector ---
echo ""
echo "Installing OpenTelemetry Collector..."
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  -n monitoring \
  -f infra/helm/otel-collector-values.yaml

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
```

### 6. Makefile targets

Add to root `Makefile`:

```makefile
.PHONY: foundations-up foundations-down foundations-status

foundations-up:
	@bash infra/helm/deploy-foundations.sh

foundations-down:
	helm uninstall otel-collector -n monitoring || true
	helm uninstall kube-prometheus-stack -n monitoring || true
	helm uninstall metrics-server -n kube-system || true

foundations-status:
	@echo "=== Foundations Status ==="
	@echo ""
	@echo "--- metrics-server ---"
	@kubectl top nodes 2>/dev/null || echo "  Not ready"
	@echo ""
	@echo "--- Monitoring Pods ---"
	@kubectl get pods -n monitoring
	@echo ""
	@echo "--- Grafana ---"
	@echo "  URL: http://localhost:30000"
	@echo "  Credentials: admin / voxline"
```

## Directory Structure

```
infra/
├── kind/
│   └── ...
├── helm/
│   ├── metrics-server-values.yaml
│   ├── prometheus-stack-values.yaml
│   ├── otel-collector-values.yaml
│   └── deploy-foundations.sh
└── grafana/
    ├── voxline-dashboard.json
    └── dashboard-configmap.yaml
```

## Validation

1. **metrics-server works:**
   ```bash
   kubectl top nodes
   # Should show CPU and memory usage for the kind node
   kubectl top pods -n kube-system
   # Should show resource usage for system pods
   ```

2. **Prometheus is scraping:**
   ```bash
   curl -s http://localhost:9090/api/v1/targets | python3 -c "
   import sys, json
   data = json.load(sys.stdin)
   active = [t['labels'].get('job','') for t in data['data']['activeTargets']]
   print(f'Active scrape targets: {len(active)}')
   for j in sorted(set(active)): print(f'  - {j}')
   "
   # Should show multiple targets: kubelet, node-exporter, kube-state-metrics, etc.
   ```

3. **Grafana is accessible:**
   ```bash
   curl -s -o /dev/null -w "%{http_code}" http://localhost:30000/login
   # Should return 200
   ```

4. **Grafana login works:**
   ```
   Open http://localhost:30000 in browser
   Login: admin / voxline
   Should see Grafana home page
   ```

5. **Pre-built Kubernetes dashboards exist:**
   ```
   In Grafana: Dashboards → Browse
   Should see folders: "General", "Kubernetes / ..." with multiple dashboards
   Open "Kubernetes / Compute Resources / Namespace (Pods)"
   Select namespace: voxline (may be empty until services deploy)
   ```

6. **Voxline System Health dashboard exists:**
   ```
   In Grafana: Dashboards → Browse → Voxline folder
   Should see "Voxline System Health" dashboard
   Panels will populate once pods are running in the voxline namespace
   ```

7. **OTel Collector is running:**
   ```bash
   kubectl get pods -n monitoring -l app.kubernetes.io/name=opentelemetry-collector
   # Should be Running
   ```

8. **OTel Collector accepts OTLP (smoke test):**
   ```bash
   # The contrib image has no wget/curl, so port-forward from host
   kubectl port-forward -n monitoring deploy/otel-collector-opentelemetry-collector 4318:4318 &
   PF_PID=$!
   sleep 2
   curl -s -o /dev/null -w "%{http_code}" -X POST \
     -H 'Content-Type: application/json' \
     -d '{"resourceSpans":[]}' \
     http://localhost:4318/v1/traces
   # Should return 200
   kill $PF_PID 2>/dev/null
   ```

9. **StorageClass works (PVC provisions):**
   ```bash
   # The Prometheus PVC should be bound
   kubectl get pvc -n monitoring
   # Should show Bound PVCs for prometheus-server
   ```

10. **Resource usage is within budget:**
    ```bash
    kubectl top pods -n monitoring
    kubectl top pods -n kube-system
    # All pods within resource limits
    ```

## What the Grafana Dashboard Shows

Once application services start deploying (prompt-m1-03 onward), the **Voxline System Health** dashboard shows:

| Panel | What It Shows | Why It Matters |
| --- | --- | --- |
| Pod Status | Count of Running pods in voxline namespace | Quick health check — should match expected service count |
| Pod Restarts (1h) | Container restart count | Yellow >1, Red >5 — catches CrashLoopBackOff early |
| CPU Usage by Pod | Per-pod CPU over time | Spot Ollama hogging CPU during inference, services idle vs. active |
| Memory Usage by Pod | Per-pod working set memory | Catch OOM risks before they kill pods. Ollama should be ~1Gi |
| Network I/O by Pod | Receive/transmit bytes per second | Visualize NATS message flow between services |
| PVC Usage | Percent full for each PersistentVolumeClaim | Yellow >70%, Red >90% — catch storage filling up |

The pre-built kube-prometheus-stack dashboards provide deeper drill-downs: per-node resources, kubelet metrics, API server latency, and more.

## Known Risks

| Risk | Mitigation |
| --- | --- |
| kube-prometheus-stack is a large Helm chart (~5 min install) | `--timeout 5m` in Helm install. Be patient on first install |
| Prometheus uses significant storage over time | `retention: 24h` limits storage. PVC is 2Gi. For a learning project, 24h is sufficient |
| Grafana NodePort 30000 conflicts | Kind cluster-config.yaml maps hostPort 30000. If conflict, change both the kind config and Grafana values |
| OTel Collector prometheusremotewrite may not work with all Prometheus versions | Fallback: switch exporter to `prometheus` (pull-based) and add a ServiceMonitor. The debug exporter always works for traces |
| metrics-server needs `--kubelet-insecure-tls` in kind | Already set in values file. Without this flag, metrics-server can't communicate with kubelet |

## Dependencies

- Completed: prompt-m1-01 (kind cluster with Ingress)

## Next Step

Once the foundations layer is running and Grafana is accessible, proceed to **prompt-m1-03** to deploy application infrastructure (NATS, MongoDB, Redis) via Helm charts. Their metrics will automatically appear in Prometheus and Grafana.
