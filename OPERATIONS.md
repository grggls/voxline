# Voxline Operations Reference

Central reference for all CLIs, web UIs, and commands to access, administer, and observe the Voxline system.

## Prerequisites

These tools must be installed before operating the cluster:

| Tool | Purpose | Install |
|------|---------|---------|
| `docker` | Container runtime (Docker Desktop) | [docker.com](https://docs.docker.com/desktop/) |
| `kind` | Kubernetes-in-Docker cluster management | `brew install kind` |
| `kubectl` | Kubernetes CLI | `brew install kubectl` |
| `helm` | Kubernetes package manager | `brew install helm` |
| `node` / `npm` | TypeScript build toolchain (>= 18) | `brew install node` |

## Quick Start (Full Stack)

```bash
make cluster-up        # Create kind cluster + nginx Ingress
make foundations-up     # Install Prometheus, Grafana, OTel, metrics-server
make infra-up          # Install NATS, MongoDB, Redis + JetStream stream
make ollama-up         # Deploy Ollama pod
make ollama-pull       # Pull Qwen3 0.6B and pre-load it
make gateway-deploy    # Build + deploy gateway service
```

---

## Cluster Lifecycle

| Command | What it does |
|---------|-------------|
| `make cluster-up` | Create the `voxline` kind cluster with nginx Ingress, namespace, and port mappings |
| `make cluster-down` | **Permanently delete** the cluster (interactive confirmation required) |
| `make cluster-stop` | Stop the cluster Docker container. All state (PVCs, pods, configs) is preserved |
| `make cluster-start` | Restart a stopped cluster. Waits for API server and system pods |
| `make cluster-status` | Show nodes, all pods, and resource usage |

### Kubectl context

The cluster uses kubectl context `kind-voxline`. It's set automatically by `make cluster-up` and `make cluster-start`.

```bash
kubectl config use-context kind-voxline
```

---

## Web UIs

| Service | URL | Credentials | Notes |
|---------|-----|-------------|-------|
| **Grafana** | http://localhost:30000 | `admin` / `voxline` | Pre-provisioned Voxline dashboard |
| **Prometheus** | http://localhost:9090 | none | PromQL query UI, 24h retention |
| **NATS Monitoring** | http://localhost:8222 | none | Connection/subscription stats (JSON endpoints) |
| **Ollama API** | http://localhost:11434 | none | Model management and inference |
| **Gateway** (via Ingress) | http://localhost:8080 | none | Health, liveness, WebSocket, API routes |

---

## Gateway Service

### Endpoints (via Ingress on port 8080)

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `http://localhost:8080/health` | GET | Readiness probe — 200 when all deps healthy, 503 when degraded |
| `http://localhost:8080/livez` | GET | Liveness probe — always 200 if process is running |
| `ws://localhost:8080/ws?tenantId=<id>` | WebSocket | Client connection — requires `tenantId` query parameter |
| `http://localhost:8080/api/*` | * | REST API routes (future) |

### Health check

```bash
# Readiness (dependency health)
curl http://localhost:8080/health
# {"status":"ok","service":"gateway","dependencies":{"nats":true,"mongodb":true,"redis":true}}

# Liveness (process alive)
curl http://localhost:8080/livez
# {"status":"ok"}
```

### WebSocket testing

```bash
# Connect with tenant ID (requires tenant in MongoDB — see seed data)
npx wscat -c "ws://localhost:8080/ws?tenantId=acme"

# Missing tenantId — closes with code 4001
npx wscat -c "ws://localhost:8080/ws"

# Unknown tenant — closes with code 4002
npx wscat -c "ws://localhost:8080/ws?tenantId=nonexistent"
```

### Build and deploy

| Command | What it does |
|---------|-------------|
| `make gateway-build` | Docker build + load image into kind |
| `make gateway-deploy` | Build + `kubectl apply` + rollout restart + wait for ready |
| `npm run build -w gateway` | TypeScript compile only (no Docker) |
| `npm run dev -w gateway` | Run locally with tsx (requires env vars for NATS/Mongo/Redis) |

### Logs

```bash
kubectl logs -n voxline deployment/gateway
kubectl logs -n voxline deployment/gateway -f     # follow
kubectl logs -n voxline deployment/gateway --tail=20
```

All log lines are structured JSON with `service`, `event`, `ts`, `requestId`, `tenantId` fields.

---

## Infrastructure Services

### NATS (Core + JetStream)

| Access | Address |
|--------|---------|
| Client (from host) | `nats://localhost:4222` |
| Client (in-cluster) | `nats://nats.voxline.svc.cluster.local:4222` |
| Monitoring (from host) | http://localhost:8222 |

**Monitoring endpoints (HTTP, from host):**

```bash
curl -s http://localhost:8222/varz | jq .   # Server version, uptime, connections
curl -s http://localhost:8222/connz | jq .  # Active client connections
curl -s http://localhost:8222/subsz | jq .  # Active subscriptions
curl -s http://localhost:8222/jsz | jq .    # JetStream state (streams, consumers, storage)
curl -s http://localhost:8222/routez | jq . # Cluster route info
```

**Core NATS (pub/sub via nats-box):**

```bash
# Subscribe to all voxline subjects (wildcard) — useful for watching traffic
kubectl exec -n voxline deploy/nats-box -- nats sub "voxline.>"

# Subscribe to a specific tenant's inbound messages
kubectl exec -n voxline deploy/nats-box -- nats sub "voxline.acme.inbound"

# Subscribe to a specific session's outbound messages
kubectl exec -n voxline deploy/nats-box -- nats sub "voxline.acme.sess_abc.outbound"

# Publish a test message to a subject
kubectl exec -n voxline deploy/nats-box -- nats pub voxline.test "hello"

# Publish with headers (simulating gateway message)
kubectl exec -n voxline deploy/nats-box -- nats pub voxline.acme.inbound \
  --header "voxline-tenant-id:acme" \
  --header "voxline-session-id:sess_test" \
  --header "voxline-request-id:req_manual_001" \
  --header "voxline-reply-to:voxline.acme.sess_test.outbound" \
  '{"tenantContext":{"tenantId":"acme","sessionId":"sess_test","requestId":"req_manual_001","timestamp":0},"content":"test message","timestamps":[]}'

# Request-reply pattern (send and wait for response, 5s timeout)
kubectl exec -n voxline deploy/nats-box -- nats req voxline.acme.inbound "ping" --timeout 5s
```

**JetStream (durable streams and consumers):**

```bash
# List all streams
kubectl exec -n voxline deploy/nats-box -- nats stream ls

# Show VOXLINE_EVENTS stream details (messages, bytes, consumer count)
kubectl exec -n voxline deploy/nats-box -- nats stream info VOXLINE_EVENTS

# View recent messages in a stream (last 10)
kubectl exec -n voxline deploy/nats-box -- nats stream view VOXLINE_EVENTS --last 10

# Purge all messages from a stream (use with caution)
kubectl exec -n voxline deploy/nats-box -- nats stream purge VOXLINE_EVENTS -f

# List consumers on a stream
kubectl exec -n voxline deploy/nats-box -- nats consumer ls VOXLINE_EVENTS

# Show consumer details (lag, pending, ack floor)
kubectl exec -n voxline deploy/nats-box -- nats consumer info VOXLINE_EVENTS <consumer-name>

# Server-level report: connections, accounts, JetStream
kubectl exec -n voxline deploy/nats-box -- nats server report connections
kubectl exec -n voxline deploy/nats-box -- nats server report jetstream
```

### MongoDB

| Access | Address |
|--------|---------|
| From host | `mongodb://localhost:27017/voxline` |
| In-cluster | `mongodb://mongodb.voxline.svc.cluster.local:27017/voxline` |

**Connecting:**

```bash
# Interactive shell from host
mongosh "mongodb://localhost:27017/voxline"

# Interactive shell via pod
kubectl exec -it -n voxline deploy/mongodb -- mongosh voxline

# One-liner from host (--eval for scripts / quick checks)
mongosh "mongodb://localhost:27017/voxline" --eval "db.tenants.find().pretty()"
```

**Exploring data:**

```bash
# List all collections
mongosh "mongodb://localhost:27017/voxline" --eval "db.getCollectionNames()"

# Count documents in a collection
mongosh "mongodb://localhost:27017/voxline" --eval "db.tenants.countDocuments()"

# Find all tenants
mongosh "mongodb://localhost:27017/voxline" --eval "db.tenants.find().pretty()"

# Find a specific tenant
mongosh "mongodb://localhost:27017/voxline" --eval 'db.tenants.findOne({tenantId: "acme"})'

# Find conversations for a tenant (when conversation data exists)
mongosh "mongodb://localhost:27017/voxline" --eval 'db.conversations.find({tenantId: "acme"}).sort({timestamp: -1}).limit(10).pretty()'
```

**Indexes and schema inspection:**

```bash
# List indexes on a collection
mongosh "mongodb://localhost:27017/voxline" --eval "db.tenants.getIndexes()"

# Collection stats (document count, storage size, index size)
mongosh "mongodb://localhost:27017/voxline" --eval "db.tenants.stats()"

# Database stats (total size, collections, indexes)
mongosh "mongodb://localhost:27017/voxline" --eval "db.stats()"
```

**Writing and modifying (development use):**

```bash
# Insert a test tenant
mongosh "mongodb://localhost:27017/voxline" --eval '
  db.tenants.insertOne({
    tenantId: "test-tenant",
    name: "Test Corp",
    config: {
      rateLimit: { maxPerMinute: 60 },
      llm: { chatModel: "qwen3:0.6b", classifyModel: "qwen3:0.6b", provider: "ollama", systemPrompt: "You are a helpful assistant." },
      features: { streamingEnabled: true }
    }
  })
'

# Update a tenant's system prompt
mongosh "mongodb://localhost:27017/voxline" --eval '
  db.tenants.updateOne(
    {tenantId: "acme"},
    {$set: {"config.llm.systemPrompt": "You are Acme support. Be concise."}}
  )
'

# Delete a test tenant
mongosh "mongodb://localhost:27017/voxline" --eval 'db.tenants.deleteOne({tenantId: "test-tenant"})'

# Drop a collection (use with caution)
mongosh "mongodb://localhost:27017/voxline" --eval "db.conversations.drop()"
```

Auth is disabled for local development.

### Redis

| Access | Address |
|--------|---------|
| From host | `redis://localhost:6379` |
| In-cluster | `redis://redis-master.voxline.svc.cluster.local:6379` |

**Connecting:**

```bash
# Interactive shell from host
redis-cli -h localhost -p 6379

# Interactive shell via pod
kubectl exec -it -n voxline deploy/redis-master -- redis-cli

# One-liner from host
redis-cli PING    # PONG
```

**Inspecting keys (Voxline uses `{tenantId}:` prefixed keys):**

```bash
# List all keys
redis-cli KEYS "*"

# List keys for a specific tenant
redis-cli KEYS "acme:*"

# List session keys
redis-cli KEYS "*:session:*"

# List rate limit keys
redis-cli KEYS "*:ratelimit:*"

# List cache keys
redis-cli KEYS "*:cache:*"

# Get key type (string, hash, list, set, zset)
redis-cli TYPE "acme:session:sess_abc"

# Get a string value
redis-cli GET "acme:session:sess_abc"

# Get TTL on a key (seconds remaining, -1 = no expiry, -2 = doesn't exist)
redis-cli TTL "acme:cache:prompt_hash_abc"

# Count keys matching a pattern
redis-cli --scan --pattern "acme:*" | wc -l
```

**Server and memory info:**

```bash
# Memory usage summary
redis-cli INFO memory

# Connected clients and blocked clients
redis-cli INFO clients

# Command stats (calls, usec per call)
redis-cli INFO commandstats

# Overall server info
redis-cli INFO server

# Database key count
redis-cli INFO keyspace

# Monitor all commands in real-time (ctrl-c to stop — use sparingly, impacts perf)
redis-cli MONITOR
```

**Writing and modifying (development use):**

```bash
# Set a key with TTL (60 seconds)
redis-cli SET "test:key" "hello" EX 60

# Set a hash (simulate session state)
redis-cli HSET "acme:session:sess_test" "tenantId" "acme" "connected" "true"
redis-cli HGETALL "acme:session:sess_test"

# Increment a counter (simulate rate limit)
redis-cli INCR "acme:ratelimit:window_123"
redis-cli GET "acme:ratelimit:window_123"

# Delete a key
redis-cli DEL "test:key"

# Delete all keys matching a pattern (use with caution)
redis-cli --scan --pattern "test:*" | xargs redis-cli DEL

# Flush entire database (use with caution)
redis-cli FLUSHDB
```

Auth is disabled for local development.

---

## Ollama (AI Model Runtime)

| Access | Address |
|--------|---------|
| From host | http://localhost:11434 |
| In-cluster | `http://ollama.voxline.svc.cluster.local:11434` |

| Command | What it does |
|---------|-------------|
| `make ollama-up` | Deploy Ollama pod + PVC + NodePort service |
| `make ollama-pull` | Pull Qwen3 0.6B and pre-load it |
| `make ollama-benchmark` | Run benchmark gate — 5 classification + 5 chat requests with threshold checks |

**Model management:**

```bash
# List all downloaded models (name, size, quantization)
curl -s http://localhost:11434/api/tags | jq '.models[] | {name, size, format: .details.quantization_level}'

# Check which models are currently loaded in memory
curl -s http://localhost:11434/api/ps | jq .

# Pull a model (from Ollama registry)
curl http://localhost:11434/api/pull -d '{"name": "qwen3:0.6b"}'

# Pull via kubectl (if curl from host isn't working)
kubectl exec -n voxline deploy/ollama -- ollama pull qwen3:0.6b

# List models via kubectl
kubectl exec -n voxline deploy/ollama -- ollama list

# Delete a model
kubectl exec -n voxline deploy/ollama -- ollama rm qwen3:0.6b

# Show model details (parameters, template, license)
kubectl exec -n voxline deploy/ollama -- ollama show qwen3:0.6b
```

**Inference — non-streaming (good for testing and benchmarking):**

```bash
# Basic generation (thinking suppressed, required for Qwen3 on Ollama >= 0.15)
curl -s http://localhost:11434/api/generate -d '{
  "model": "qwen3:0.6b",
  "prompt": "Hello, who are you?",
  "stream": false,
  "think": false,
  "options": {"num_predict": 30, "presence_penalty": 1.5}
}' | jq '{response, eval_count, eval_duration}'

# Classification test
curl -s http://localhost:11434/api/generate -d '{
  "model": "qwen3:0.6b",
  "prompt": "Classify the following into exactly one category: faq, general, escalation.\nUser: What are your business hours?\nCategory:",
  "stream": false,
  "think": false,
  "options": {"num_predict": 10, "presence_penalty": 1.5}
}' | jq '{response, eval_count}'

# Chat completion (OpenAI-compatible endpoint — what the LLM Service will use)
curl -s http://localhost:11434/v1/chat/completions -d '{
  "model": "qwen3:0.6b",
  "messages": [
    {"role": "system", "content": "You are a helpful support agent. Be concise."},
    {"role": "user", "content": "How do I reset my password?"}
  ],
  "stream": false,
  "think": false,
  "presence_penalty": 1.5
}' | jq '.choices[0].message.content'

# Multi-turn conversation
curl -s http://localhost:11434/v1/chat/completions -d '{
  "model": "qwen3:0.6b",
  "messages": [
    {"role": "system", "content": "You are a helpful assistant."},
    {"role": "user", "content": "My name is Greg."},
    {"role": "assistant", "content": "Nice to meet you, Greg!"},
    {"role": "user", "content": "What is my name?"}
  ],
  "stream": false,
  "think": false,
  "presence_penalty": 1.5
}' | jq '.choices[0].message.content'
```

**Inference — streaming (what the real pipeline does):**

```bash
# Stream tokens as they're generated (each line is a JSON object)
curl http://localhost:11434/api/generate -d '{
  "model": "qwen3:0.6b",
  "prompt": "Explain what NATS is in two sentences.",
  "stream": true,
  "think": false,
  "options": {"num_predict": 60, "presence_penalty": 1.5}
}'
```

**Performance diagnostics:**

```bash
# Full timing breakdown (load, prompt eval, generation)
curl -s http://localhost:11434/api/generate -d '{
  "model": "qwen3:0.6b",
  "prompt": "What is 2+2?",
  "stream": false,
  "think": false,
  "options": {"num_predict": 10}
}' | jq '{
  total_s: (.total_duration / 1e9),
  load_ms: (.load_duration / 1e6),
  prompt_eval_ms: (.prompt_eval_duration / 1e6),
  eval_ms: (.eval_duration / 1e6),
  tokens: .eval_count,
  tok_per_sec: (.eval_count / (.eval_duration / 1e9))
}'

# Warmup (run 3x before benchmarking — first requests are always slower)
for i in 1 2 3; do
  curl -s http://localhost:11434/api/generate \
    -d '{"model":"qwen3:0.6b","prompt":"warmup","stream":false,"think":false,"options":{"num_predict":1}}' > /dev/null
done

# Run the full benchmark gate
make ollama-benchmark
```

**Active config**: Qwen3 0.6B for both classification and chat. `KEEP_ALIVE=-1` (never evict), `NUM_PARALLEL=2`, `CONTEXT_LENGTH=2048`.

**Important**: All Qwen3 requests must include `"think": false`. The `/no_think` prompt prefix does not work with Ollama >= 0.15. Quantized models should also use `"presence_penalty": 1.5` to suppress repetition.

---

## Observability Stack

### Deploy / Teardown

| Command | What it does |
|---------|-------------|
| `make foundations-up` | Install metrics-server, Prometheus + Grafana, OTel Collector |
| `make foundations-down` | Uninstall the observability stack |
| `make foundations-status` | Show monitoring pod status and access URLs |

### Prometheus

http://localhost:9090

```bash
# Example PromQL queries
# CPU usage by pod in voxline namespace
sum(rate(container_cpu_usage_seconds_total{namespace="voxline"}[5m])) by (pod)

# Memory usage by pod
sum(container_memory_working_set_bytes{namespace="voxline"}) by (pod)
```

### Grafana

http://localhost:30000 (admin / voxline)

Pre-provisioned dashboard: **Voxline** (under the Voxline folder). Shows cluster resource usage and pod metrics.

### OpenTelemetry Collector

| Protocol | In-cluster endpoint |
|----------|-------------------|
| OTLP gRPC | `otel-collector.monitoring:4317` |
| OTLP HTTP | `otel-collector.monitoring:4318` |

Metrics are forwarded to Prometheus via remote write. Traces are logged to stdout (debug exporter) until a trace backend is added in M4.

### metrics-server

```bash
kubectl top nodes         # Node CPU/memory
kubectl top pods -n voxline   # Pod CPU/memory in voxline namespace
kubectl top pods -A           # All namespaces
```

---

## TypeScript Development

| Command | What it does |
|---------|-------------|
| `npm run build` | Build all workspaces |
| `npm run build -w packages/shared` | Build shared package only |
| `npm run build -w gateway` | Build gateway only |
| `npm run test` | Run tests across all workspaces |
| `npm run test:m1` | Run M1 integration tests only |
| `npm run lint` | ESLint across all workspaces |
| `make build` | Alias for `npm run build` |
| `make test` | Alias for `npm run test` |
| `make lint` | Alias for `npm run lint` |

### Workspaces

| Workspace | Path | Description |
|-----------|------|-------------|
| `@voxline/shared` | `packages/shared/` | Shared types, NATS header utilities, structured logger |
| `@voxline/gateway` | `gateway/` | Express + WebSocket + NATS bridge |

---

## Kubernetes Quick Reference

### Pod inspection

```bash
# All pods across namespaces
kubectl get pods -A

# Voxline namespace only
kubectl get pods -n voxline

# Describe a pod (events, conditions, resource usage)
kubectl describe pod -n voxline <pod-name>

# Exec into a pod
kubectl exec -it -n voxline deploy/gateway -- sh
kubectl exec -it -n voxline deploy/ollama -- bash
kubectl exec -it -n voxline deploy/nats-box -- sh
```

### Logs

```bash
kubectl logs -n voxline deploy/gateway
kubectl logs -n voxline deploy/ollama
kubectl logs -n voxline deploy/nats-box
kubectl logs -n monitoring deploy/kube-prometheus-stack-grafana
```

### Services and networking

```bash
kubectl get svc -n voxline              # Service endpoints
kubectl get ingress -n voxline          # Ingress routes
kubectl get svc -n ingress-nginx        # Ingress controller
```

### Resources and storage

```bash
kubectl get pvc -n voxline              # Persistent volume claims
kubectl top pods -n voxline             # Resource usage
kubectl get events -n voxline --sort-by='.lastTimestamp'   # Recent events
```

### DNS resolution (from inside a pod)

```bash
kubectl exec -n voxline deploy/nats-box -- nslookup nats.voxline.svc.cluster.local
kubectl exec -n voxline deploy/nats-box -- nslookup mongodb.voxline.svc.cluster.local
kubectl exec -n voxline deploy/nats-box -- nslookup redis-master.voxline.svc.cluster.local
kubectl exec -n voxline deploy/nats-box -- nslookup ollama.voxline.svc.cluster.local
```

---

## Port Mapping Summary

All ports are mapped via kind `extraPortMappings` in `infra/kind/cluster-config.yaml`.

| Host Port | Service | Protocol | Kind NodePort |
|-----------|---------|----------|---------------|
| 8080 | nginx Ingress (HTTP) | TCP | 80 |
| 8443 | nginx Ingress (HTTPS) | TCP | 443 |
| 30000 | Grafana | TCP | 30000 |
| 9090 | Prometheus | TCP | 30090 |
| 4222 | NATS client | TCP | 30422 |
| 8222 | NATS monitoring | TCP | 30822 |
| 27017 | MongoDB | TCP | 30017 |
| 6379 | Redis | TCP | 30379 |
| 11434 | Ollama API | TCP | 30434 |

---

## Troubleshooting

### Port already in use

```bash
# Check which process is using a port
lsof -i :8080
lsof -i :4222

# Kill the process or change the hostPort in infra/kind/cluster-config.yaml
```

### Pod stuck in CrashLoopBackOff

```bash
kubectl describe pod -n voxline <pod-name>    # Check events
kubectl logs -n voxline <pod-name> --previous  # Previous container logs
```

### Gateway can't reach NATS/MongoDB/Redis

```bash
# Verify DNS from inside the gateway pod
kubectl exec -n voxline deploy/gateway -- nslookup nats.voxline.svc.cluster.local

# Verify services exist
kubectl get svc -n voxline
```

### Ollama model not loaded

```bash
# Check if model is available
curl http://localhost:11434/api/tags

# Check running models (should show qwen3:0.6b)
curl http://localhost:11434/api/ps

# Re-pull and pre-load
make ollama-pull
```

### WebSocket connection fails through Ingress

```bash
# Test direct pod access (bypass Ingress)
kubectl port-forward -n voxline deploy/gateway 3000:3000
npx wscat -c "ws://localhost:3000/ws?tenantId=acme"

# Check Ingress controller logs
kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=20
```
