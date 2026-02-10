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
nats:
  jetstream:
    enabled: true
    memStorage:
      enabled: true
      size: 64Mi
    fileStorage:
      enabled: true
      size: 1Gi
      storageDirectory: /data/jetstream
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
      nodePort: 30422              # Accessible at nats://localhost:4222
  merge:
    spec:
      type: NodePort
# Expose NATS monitoring HTTP endpoint
config:
  monitor:
    enabled: true
    port: 8222
  http_port: 8222
# Monitoring NodePort service (separate from client port)
extraResources:
  - apiVersion: v1
    kind: Service
    metadata:
      name: nats-monitoring
      namespace: voxline
    spec:
      type: NodePort
      selector:
        app.kubernetes.io/name: nats
      ports:
        - port: 8222
          targetPort: 8222
          nodePort: 30822            # Accessible at http://localhost:8222
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
  nodePortsExtra:
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
      redis: 30379                 # Accessible at redis://localhost:6379
replica:
  replicaCount: 0         # No replicas for local dev
```

Install command:
```bash
helm install redis bitnami/redis -n voxline -f infra/helm/redis-values.yaml
```

### 4. Deployment script

Create `infra/helm/deploy-infra.sh`:

- Add all Helm repos (nats, bitnami)
- `helm repo update`
- Install/upgrade each chart with its values file into the `voxline` namespace
- Wait for all pods to be ready
- Create the JetStream stream `VOXLINE_EVENTS` after NATS is running:
  ```bash
  kubectl exec -n voxline deploy/nats -c nats -- \
    nats stream add VOXLINE_EVENTS \
      --subjects "voxline.events.>" \
      --retention limits \
      --max-msgs 10000 \
      --max-age 24h \
      --storage file \
      --replicas 1 \
      --discard old
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
   # Requires nats CLI installed locally
   nats server info --server nats://localhost:4222
   # Should show server info with JetStream enabled
   ```

3. **NATS monitoring (from host):**
   ```bash
   curl -s http://localhost:8222/varz | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'NATS {d[\"server_id\"]}: {d[\"connections\"]} connections')"
   # Should show server ID and connection count
   ```

4. **NATS JetStream stream exists:**
   ```bash
   kubectl exec -n voxline deploy/nats -c nats -- nats stream info VOXLINE_EVENTS
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
   kubectl exec -n voxline deploy/mongodb -- mongosh --eval "db.test.insertOne({x:1})"
   # Restart the pod
   kubectl delete pod -n voxline -l app.kubernetes.io/name=mongodb
   # Wait for pod to come back
   kubectl wait -n voxline --for=condition=ready pod -l app.kubernetes.io/name=mongodb --timeout=60s
   # Verify data survived
   kubectl exec -n voxline deploy/mongodb -- mongosh --eval "db.test.find()"
   # Should show {x:1}
   ```

## Known Risks

| Risk | Mitigation |
|---|---|
| Bitnami chart defaults too heavy for `kind` | All values files explicitly set `resources`, `auth.enabled: false`, `persistence.size`. Test each chart individually before combining |
| PVC stuck in Pending | Verify `kind` has a default StorageClass: `kubectl get sc`. Should show `standard (default)` |
| NATS JetStream not enabled | Verify with `nats server info` — look for `jetstream: enabled` in output |
| MongoDB auth blocks connections | `auth.enabled: false` in values. If accidentally left on, password is in a Secret: `kubectl get secret -n voxline` |

## Dependencies

- Completed: prompt-m1-01 (kind cluster running with namespace)
- Completed: prompt-m1-02 (cluster foundations — metrics-server, Prometheus, Grafana, OTel Collector)

## Next Step

Once NATS, MongoDB, and Redis are running, proceed to **prompt-m1-04** to deploy Ollama and run the model benchmark gate.
