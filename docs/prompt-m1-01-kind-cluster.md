# M1-01: Create Kind Cluster with Ingress

## Context

Voxline runs entirely inside a Kubernetes cluster on a laptop using `kind` (Kubernetes in Docker). This is the first step — create the cluster with the right configuration so all subsequent infrastructure and services can be deployed.

The cluster needs `extraPortMappings` to expose every service on the host — no `kubectl port-forward` needed. Every tool (NATS, MongoDB, Redis, Ollama, Prometheus, Grafana) is a first-class citizen accessible from `localhost`. An nginx Ingress controller routes browser traffic to the Gateway and UI.

## What to Build

### 1. Kind cluster configuration

Create `infra/kind/cluster-config.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "ingress-ready=true"
    extraPortMappings:
      # --- Ingress (nginx binds to 80/443 via hostPort) ---
      - containerPort: 80
        hostPort: 8080
        protocol: TCP
      - containerPort: 443
        hostPort: 8443
        protocol: TCP
      # --- Observability ---
      - containerPort: 30000       # Grafana
        hostPort: 30000
        protocol: TCP
      - containerPort: 30090       # Prometheus
        hostPort: 9090
        protocol: TCP
      # --- Infrastructure ---
      - containerPort: 30422       # NATS client
        hostPort: 4222
        protocol: TCP
      - containerPort: 30822       # NATS monitoring
        hostPort: 8222
        protocol: TCP
      - containerPort: 30017       # MongoDB
        hostPort: 27017
        protocol: TCP
      - containerPort: 30379       # Redis
        hostPort: 6379
        protocol: TCP
      # --- AI ---
      - containerPort: 30434       # Ollama API
        hostPort: 11434
        protocol: TCP
```

### 2. Cluster creation script

Create `infra/kind/create-cluster.sh`:

```bash
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
```

### 3. Cluster lifecycle scripts

Create `infra/kind/stop-cluster.sh`:

```bash
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
```

Create `infra/kind/start-cluster.sh`:

```bash
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
```

### 4. Makefile targets

Create or update the root `Makefile`:

```makefile
CLUSTER_NAME := voxline

.PHONY: cluster-up cluster-down cluster-stop cluster-start cluster-status

cluster-up:
	@bash infra/kind/create-cluster.sh

cluster-down:
	@echo ""
	@echo "⚠️  This will PERMANENTLY DELETE the '$(CLUSTER_NAME)' cluster."
	@echo "   All pods, volumes, data, and configuration will be destroyed."
	@echo ""
	@read -p "Type 'yes' to confirm deletion: " confirm && \
		[ "$$confirm" = "yes" ] || { echo "Aborted."; exit 1; }
	@kind delete cluster --name $(CLUSTER_NAME)
	@echo "Cluster '$(CLUSTER_NAME)' deleted."

cluster-stop:
	@bash infra/kind/stop-cluster.sh

cluster-start:
	@bash infra/kind/start-cluster.sh

cluster-status:
	@echo "=== Cluster Status ==="
	@kubectl cluster-info --context kind-$(CLUSTER_NAME) 2>/dev/null || { echo "Cluster is not running."; exit 1; }
	@echo ""
	@echo "=== Nodes ==="
	@kubectl get nodes
	@echo ""
	@echo "=== All Pods ==="
	@kubectl get pods -A --sort-by=.metadata.namespace
	@echo ""
	@echo "=== Resource Usage ==="
	@kubectl top nodes 2>/dev/null || echo "(metrics-server not yet installed — run 'make foundations-up')"
```

## Directory Structure

```
infra/
└── kind/
    ├── cluster-config.yaml
    ├── create-cluster.sh
    ├── stop-cluster.sh
    └── start-cluster.sh
Makefile
```

## Cluster Lifecycle

| Command | What it does | Destructive? |
|---|---|---|
| `make cluster-up` | Create fresh cluster + Ingress | No (fails if exists) |
| `make cluster-stop` | `docker stop` on kind container — preserves all state | No |
| `make cluster-start` | `docker start` — pods resume where they left off | No |
| `make cluster-down` | Delete cluster entirely — confirmation required | **Yes** |
| `make cluster-status` | Show nodes, pods, resource usage | No |

**Typical workflow:**
- End of day: `make cluster-stop`
- Next morning: `make cluster-start` → wait 30-60s → `make cluster-status`
- Starting over: `make cluster-down` → `make cluster-up`

## Validation

1. **Cluster is running:**
   ```bash
   kubectl cluster-info --context kind-voxline
   # Should show control plane URLs
   ```

2. **Voxline namespace exists:**
   ```bash
   kubectl get namespace voxline
   ```

3. **Ingress controller is ready:**
   ```bash
   kubectl get pods -n ingress-nginx
   # Controller pod should be Running
   ```

4. **Ports are mapped:**
   ```bash
   curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/
   # Should return 404 (Ingress up, no routes yet)
   ```

5. **Stop/start cycle preserves state:**
   ```bash
   make cluster-stop
   make cluster-start
   kubectl get namespace voxline
   # Namespace still exists
   ```

6. **Cluster-down requires confirmation:**
   ```bash
   make cluster-down
   # Should prompt "Type 'yes' to confirm deletion:"
   # Typing anything other than 'yes' aborts
   ```

7. **Default StorageClass exists:**
   ```bash
   kubectl get storageclass
   # Should show 'standard (default)' from kind's local-path-provisioner
   ```

## Endpoint Reference

All services are accessible from `localhost` once deployed — no `kubectl port-forward` needed.

| Service | Host URL / Connection String | NodePort | Installed In |
|---|---|---|---|
| Gateway / UI | `http://localhost:8080` | — (Ingress hostPort) | m1-06, m1-09 |
| Grafana | `http://localhost:30000` (admin / voxline) | 30000 | m1-02 |
| Prometheus | `http://localhost:9090` | 30090 | m1-02 |
| NATS client | `nats://localhost:4222` | 30422 | m1-03 |
| NATS monitoring | `http://localhost:8222` | 30822 | m1-03 |
| MongoDB | `mongodb://localhost:27017/voxline` | 30017 | m1-03 |
| Redis | `redis://localhost:6379` | 30379 | m1-03 |
| Ollama API | `http://localhost:11434` | 30434 | m1-04 |

**Quick verification commands** (run after all services are deployed):

```bash
# Observability
curl -s http://localhost:30000/login | head -1        # Grafana
curl -s http://localhost:9090/api/v1/status/config | head -1  # Prometheus

# Infrastructure
curl -s http://localhost:8222/varz | head -1            # NATS monitoring
mongosh mongodb://localhost:27017/voxline --eval "db.tenants.countDocuments()"
redis-cli -h localhost -p 6379 PING

# AI
curl -s http://localhost:11434/api/tags | head -1       # Ollama

# Application
curl -s http://localhost:8080/health                    # Gateway
```

## Known Risks

| Risk | Mitigation |
|---|---|
| Host ports (8080, 8443, 4222, 8222, 9090, 27017, 6379, 11434, 30000) already in use | Create script checks with `lsof` and fails with clear message |
| `kind`, `kubectl`, `helm` not installed | Create script checks for all three and fails with clear message |
| Docker not running | Create script verifies Docker daemon before proceeding |
| After `cluster-start`, pods take time to stabilize | Start script waits for system pods. User message says "give 30-60s". `cluster-status` shows current state |

## Dependencies

- `kind` CLI installed (`brew install kind`)
- `kubectl` CLI installed (`brew install kubectl`)
- `helm` CLI installed (`brew install helm`)
- `nats` CLI installed (`brew tap nats-io/nats-tools && brew install nats-io/nats-tools/nats`) — used from M1-03 onward for NATS/JetStream validation
- `mongosh` CLI installed (`brew install mongosh`) — used from M1-03 onward for MongoDB validation
- `redis-cli` installed (`brew install redis`) — used from M1-03 onward for Redis validation
- Docker daemon running

## Next Step

Once the cluster is running with Ingress, proceed to **prompt-m1-02** to install the observability and cluster foundations layer (metrics-server, Prometheus, Grafana, OTel Collector).
