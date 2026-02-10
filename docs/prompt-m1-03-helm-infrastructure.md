# M1-03: Deploy Infrastructure via Helm (NATS, MongoDB, Redis)

## Context

The `kind` cluster is running with the `voxline` namespace and nginx Ingress controller (from prompt-m1-01). Now deploy the three core infrastructure services via Helm charts with resource limits tuned for a laptop.

**Important:** Bitnami charts have aggressive defaults (high resource requests, authentication enabled, large persistent volumes). Every chart needs explicit value overrides for local development. Budget time for tuning — this is a known risk area.

No Kafka in M1-M2. The cold path uses NATS JetStream. Kafka is introduced in M3.

## Resource Budget (Infrastructure Only, M1-M2)

| Component | CPU Request | CPU Limit | RAM Request | RAM Limit |
|---|---|---|---|---|
| NATS | 100m | 250m | 64 Mi | 128 Mi |
| MongoDB | 250m | 500m | 256 Mi | 512 Mi |
| Redis | 100m | 250m | 64 Mi | 128 Mi |
| **Total** | **450m** | **1000m** | **384 Mi** | **768 Mi** |

## What to Build

### 1. NATS (Core + JetStream)

Create `infra/helm/nats-values.yaml`:

```yaml
# nats-io/nats chart
config:
  jetstream:
    enabled: true
    fileStore:
      enabled: true
      dir: /data
      pvc:
        enabled: true
        size: 1Gi
    memoryStore:
      enabled: true
      maxSize: 64Mi
  monitor:
    enabled: true
    port: 8222
container:
  resources:
    requests:
      cpu: 100m
      memory: 64Mi
    limits:
      cpu: 250m
      memory: 128Mi
service:
  ports:
    nats:
      enabled: true
    monitor:
      enabled: true
  merge:
    spec:
      type: NodePort
      ports:
        - name: nats
          port: 4222
          nodePort: 30422          # Accessible at nats://localhost:4222
        - name: monitor
          port: 8222
          nodePort: 30822          # Accessible at http://localhost:8222
extraResources: []
```

Key decisions:
- JetStream enabled from day 1 — handles the cold path `VOXLINE_EVENTS` stream in M1-M2
- File storage enabled so JetStream survives NATS pod restarts
- Core NATS (no persistence overhead) used for the hot path subjects

Install command:
```bash
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm install nats nats/nats -n voxline -f infra/helm/nats-values.yaml
```

### 2. MongoDB

Create `infra/helm/mongodb-values.yaml`:

```yaml
# bitnami/mongodb chart
architecture: standalone
auth:
  enabled: false          # No auth for local dev
resources:
  requests:
    cpu: 250m
    memory: 256Mi
  limits:
    cpu: 500m
    memory: 512Mi
persistence:
  size: 2Gi
# Cap WiredTiger cache to 256MB
extraEnvVars:
  - name: MONGODB_EXTRA_FLAGS
    value: "--wiredTigerCacheSizeGB=0.25"
service:
  type: NodePort
  nodePorts:
    mongodb: 30017                 # Accessible at mongodb://localhost:27017
```

Install command:
```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm install mongodb bitnami/mongodb -n voxline -f infra/helm/mongodb-values.yaml
```

### 3. Redis

Create `infra/helm/redis-values.yaml`:

```yaml
# bitnami/redis chart
architecture: standalone
auth:
  enabled: false          # No auth for local dev
master:
  resources:
    requests:
      cpu: 100m
      memory: 64Mi
    limits:
      cpu: 250m
      memory: 128Mi
  persistence:
    size: 1Gi
  service:
    type: NodePort
    nodePorts:
      redis: "30379"               # Accessible at redis://localhost:6379 (must be string, not int)
replica:
  replicaCount: 0         # No replicas for local dev
```

Install command:
```bash
helm install redis bitnami/redis -n voxline -f infra/helm/redis-values.yaml
```

### 4. Deployment script

Create `infra/helm/deploy-infra.sh`:

```bash
#!/bin/bash
set -euo pipefail

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
  -f infra/helm/nats-values.yaml \
  --timeout 3m

# --- MongoDB ---
echo ""
echo "Installing MongoDB..."
helm upgrade --install mongodb bitnami/mongodb \
  -n voxline \
  -f infra/helm/mongodb-values.yaml \
  --timeout 3m

# --- Redis ---
echo ""
echo "Installing Redis..."
helm upgrade --install redis bitnami/redis \
  -n voxline \
  -f infra/helm/redis-values.yaml \
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
```

### 5. Makefile targets

Add to the root `Makefile`:

```makefile
.PHONY: infra-up infra-down infra-status

infra-up:
	bash infra/helm/deploy-infra.sh

infra-down:
	helm uninstall nats mongodb redis -n voxline || true

infra-status:
	kubectl get pods -n voxline
	kubectl get pvc -n voxline
```

## Directory Structure

```
infra/
├── kind/
│   ├── cluster-config.yaml
│   └── create-cluster.sh
└── helm/
    ├── deploy-infra.sh
    ├── nats-values.yaml
    ├── mongodb-values.yaml
    └── redis-values.yaml
```

## Validation

Run these checks after all charts are deployed:

1. **All pods Running:**
   ```bash
   kubectl get pods -n voxline
   # nats-0, mongodb-0, redis-master-0 all Running
   ```

2. **NATS connectivity (from host):**
   ```bash
   # Requires nats CLI installed locally (brew tap nats-io/nats-tools && brew install nats-io/nats-tools/nats)
   # Note: `nats server info` requires system account privileges and won't work here.
   # Use `nats account info` instead — shows connectivity, JetStream status, and stream count.
   nats account info --server nats://localhost:4222
   # Should show Account: $G, JetStream enabled, Streams: 1
   ```

3. **NATS monitoring (from host):**
   ```bash
   curl -s http://localhost:8222/varz | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'NATS {d[\"server_id\"]}: {d[\"connections\"]} connections')"
   # Should show server ID and connection count
   ```

4. **NATS JetStream stream exists:**
   ```bash
   kubectl exec -n voxline deploy/nats-box -- nats stream info VOXLINE_EVENTS
   # Should show stream configuration
   ```

5. **MongoDB connectivity (from host):**
   ```bash
   mongosh mongodb://localhost:27017/voxline --eval "db.runCommand({ping: 1})"
   # Should return { ok: 1 }
   ```

6. **Redis connectivity (from host):**
   ```bash
   redis-cli -h localhost -p 6379 PING
   # Should return PONG
   ```

7. **Resource usage is within budget:**
   ```bash
   kubectl top pods -n voxline
   # All pods within their resource limits
   ```

8. **Persistence survives restart:**
   ```bash
   # Write test data to MongoDB
   kubectl exec -n voxline deploy/mongodb -- mongosh --quiet --eval "db.test.insertOne({x:1})"
   # Restart the pod
   kubectl delete pod -n voxline -l app.kubernetes.io/name=mongodb
   # Wait for pod to come back
   kubectl wait -n voxline --for=condition=ready pod -l app.kubernetes.io/name=mongodb --timeout=60s
   # Verify data survived
   kubectl exec -n voxline deploy/mongodb -- mongosh --quiet --eval "db.test.find()"
   # Should show {x:1}
   ```

## Known Risks

| Risk | Mitigation |
|---|---|
| Bitnami chart defaults too heavy for `kind` | All values files explicitly set `resources`, `auth.enabled: false`, `persistence.size`. Test each chart individually before combining |
| PVC stuck in Pending | Verify `kind` has a default StorageClass: `kubectl get sc`. Should show `standard (default)` |
| NATS JetStream not enabled | Verify with `nats account info --server nats://localhost:4222` — look for JetStream section with stream count. Or `curl -s localhost:8222/jsz` — `"disabled": true` means JetStream is off |
| MongoDB auth blocks connections | `auth.enabled: false` in values. If accidentally left on, password is in a Secret: `kubectl get secret -n voxline` |
| **NATS chart schema differs from examples online** | The `nats-io/nats` chart uses `config.jetstream.enabled`, `config.jetstream.fileStore`, `container.resources` — not the `nats.jetstream` / `nats.resources` pattern found in older docs. JetStream can deploy silently disabled if the wrong keys are used. Always run `helm show values nats/nats` to verify the schema, and check `curl -s localhost:8222/jsz` after deploy — if `"disabled": true`, the values are wrong. Requires uninstall + reinstall (not upgrade) because StatefulSet PVC spec changes are forbidden on upgrade |
| **Bitnami chart schema type strictness** | Bitnami charts validate value types strictly. NodePort values like `nodePorts.redis` must be strings (`"30379"`), not integers (`30379`). Helm install fails with a clear schema error — fix is to quote the value |
| **`nats` CLI not in NATS server container** | The `nats` CLI binary is in the `nats-box` sidecar pod, not the main NATS container. Use `kubectl exec deploy/nats-box --` for stream operations, not `kubectl exec deploy/nats -c nats --` |
| **`nats server info` requires system privileges** | The `nats server info` and `nats server ping` commands require system account access. Use `nats account info --server nats://localhost:4222` instead for connectivity and JetStream validation from the host |

## Implementation Notes (post-deploy)

The prompt's values files needed ~10 minutes of tuning to match the actual chart schemas. Three fixes were required:

1. **NATS chart schema mismatch.** The `nats-io/nats` chart uses `config.jetstream.enabled`, `config.jetstream.fileStore`, `config.jetstream.memoryStore`, and `container.resources` — not the `nats.jetstream` / `nats.resources` structure originally specified. The monitoring port is exposed via `service.ports.monitor.enabled: true` + `service.merge` for NodePort assignment, not via a separate `extraResources` Service. The original values deployed NATS but with JetStream silently disabled (`"disabled": true` in `/jsz`). Required uninstall + reinstall since the StatefulSet spec (JetStream PVC) can't be changed via upgrade.

2. **Redis nodePort type.** The Bitnami Redis chart schema validates `nodePorts.redis` as a string, not a number. `redis: 30379` fails; `redis: "30379"` works.

3. **NATS CLI location.** The `nats` CLI binary is in the `nats-box` pod (`deploy/nats-box`), not in the main NATS container. The deploy script's stream creation command needs `kubectl exec -n voxline deploy/nats-box --` not `kubectl exec -n voxline deploy/nats -c nats --`.

## Dependencies

- Completed: prompt-m1-01 (kind cluster running with namespace)
- Completed: prompt-m1-02 (cluster foundations — metrics-server, Prometheus, Grafana, OTel Collector)

## Next Step

Once NATS, MongoDB, and Redis are running, proceed to **prompt-m1-04** to deploy Ollama and run the model benchmark gate.
