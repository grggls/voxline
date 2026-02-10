# M1-04: Deploy Ollama and Run Model Benchmark Gate

## Context

NATS, MongoDB, and Redis are running in the `kind` cluster (from prompt-m1-03). Now deploy Ollama, pull the Qwen3 models, and run the benchmark gate.

**This is a gated decision point.** The entire latency budget depends on actual tok/s performance. If numbers don't meet targets, model selection must be adjusted before building any services.

## Resource Budget

| Component | CPU Request | CPU Limit | RAM Request | RAM Limit |
|---|---|---|---|---|
| Ollama (2 models loaded) | 1000m | 2000m | 1.0 Gi | 1.5 Gi |

## What to Build

### 1. Ollama Kubernetes manifest

Create `infra/k8s/ollama.yaml` (plain manifest, not Helm — Ollama doesn't have an official Helm chart worth using):

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ollama
  namespace: voxline
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ollama
  template:
    metadata:
      labels:
        app: ollama
    spec:
      containers:
        - name: ollama
          image: ollama/ollama:latest
          ports:
            - containerPort: 11434
          env:
            - name: OLLAMA_KEEP_ALIVE
              value: "-1"           # Never evict models from memory
            - name: OLLAMA_NUM_PARALLEL
              value: "2"            # Handle concurrent requests
            - name: OLLAMA_HOST
              value: "0.0.0.0"
          resources:
            requests:
              cpu: 1000m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 1536Mi        # 1.5 Gi — generous during model pull
          volumeMounts:
            - name: ollama-data
              mountPath: /root/.ollama
      volumes:
        - name: ollama-data
          persistentVolumeClaim:
            claimName: ollama-data
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ollama-data
  namespace: voxline
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 3Gi              # Enough for both GGUF models
---
apiVersion: v1
kind: Service
metadata:
  name: ollama
  namespace: voxline
spec:
  selector:
    app: ollama
  ports:
    - port: 11434
      targetPort: 11434
      nodePort: 30434              # Accessible at http://localhost:11434
  type: NodePort
```

Key decisions:
- **PersistentVolumeClaim** for model storage — models survive pod restarts, no re-downloading
- **`OLLAMA_KEEP_ALIVE=-1`** — models stay loaded permanently (never evicted)
- **`OLLAMA_NUM_PARALLEL=2`** — handle concurrent classification + chat requests
- **1.5 Gi memory limit** — generous enough for model pull. Both models loaded consume ~1.0-1.1 Gi

### 2. Model pull script

Create `infra/k8s/ollama-pull-models.sh`:

```bash
#!/bin/bash
set -euo pipefail

echo "Waiting for Ollama pod to be ready..."
kubectl wait -n voxline --for=condition=ready pod -l app=ollama --timeout=120s

echo "Pulling Qwen3 0.6B (classification model)..."
kubectl exec -n voxline deploy/ollama -- ollama pull qwen3:0.6b

echo "Pulling Qwen3 1.7B (chat model)..."
kubectl exec -n voxline deploy/ollama -- ollama pull qwen3:1.7b

echo "Verifying models are available..."
kubectl exec -n voxline deploy/ollama -- ollama list

echo "Pre-loading both models (warm start)..."
kubectl exec -n voxline deploy/ollama -- ollama run qwen3:0.6b "" --keepalive -1
kubectl exec -n voxline deploy/ollama -- ollama run qwen3:1.7b "" --keepalive -1
```

### 3. Benchmark script

Create `infra/k8s/ollama-benchmark.sh`:

This is the **decision gate**. Run it manually and read the output.

```bash
#!/bin/bash
set -euo pipefail

echo "=== OLLAMA BENCHMARK GATE ==="
echo ""
echo "--- Qwen3 0.6B (classification, /no_think mode) ---"
echo "Testing 5 classification requests..."
for i in $(seq 1 5); do
  curl -s http://localhost:11434/api/generate \
    -d '{
      "model": "qwen3:0.6b",
      "prompt": "/no_think\nClassify the following user message into exactly one category: faq, general, escalation.\nUser: What are your business hours?\nCategory:",
      "stream": false,
      "options": { "num_predict": 10, "presence_penalty": 1.5 }
    }' | python3 -c "
import sys, json
i = sys.argv[1]
r = json.load(sys.stdin)
dur_s = r.get('total_duration', 0) / 1e9
tps = r.get('eval_count', 0) / (r.get('eval_duration', 1) / 1e9) if r.get('eval_duration') else 0
print(f'  Run {i}: {dur_s:.2f}s total, {tps:.1f} tok/s, response: {r.get(\"response\", \"\").strip()[:50]}')
" "$i"
done

echo ""
echo "--- Qwen3 1.7B (chat) ---"
echo "Testing 5 chat requests..."
for i in $(seq 1 5); do
  curl -s http://localhost:11434/api/generate \
    -d '{
      "model": "qwen3:1.7b",
      "prompt": "/no_think\nYou are a helpful support agent. Answer briefly.\nUser: How do I reset my password?\nAgent:",
      "stream": false,
      "options": { "num_predict": 50, "presence_penalty": 1.5 }
    }' | python3 -c "
import sys, json
i = sys.argv[1]
r = json.load(sys.stdin)
dur_s = r.get('total_duration', 0) / 1e9
tps = r.get('eval_count', 0) / (r.get('eval_duration', 1) / 1e9) if r.get('eval_duration') else 0
print(f'  Run {i}: {dur_s:.2f}s total, {tps:.1f} tok/s')
" "$i"
done

echo ""
echo "=== DECISION GATE ==="
echo "Review the tok/s numbers above."
echo ""
echo "PASS criteria:"
echo "  Qwen3 0.6B: >= 25 tok/s"
echo "  Qwen3 1.7B: >= 20 tok/s"
echo ""
echo "If 1.7B < 20 tok/s → consider Qwen3 0.6B for both roles"
echo "If 1.7B < 15 tok/s → consider TinyLlama 1.1B or Gemma 3 1B"
echo "If 0.6B < 25 tok/s → revisit latency budget for classification hop"
echo ""
```

### 4. Makefile targets

Add to root `Makefile`:

```makefile
.PHONY: ollama-up ollama-pull ollama-benchmark

ollama-up:
	kubectl apply -f infra/k8s/ollama.yaml

ollama-pull:
	bash infra/k8s/ollama-pull-models.sh

ollama-benchmark:
	bash infra/k8s/ollama-benchmark.sh
```

## Directory Structure

```
infra/
├── kind/
│   └── ...
├── helm/
│   └── ...
└── k8s/
    ├── ollama.yaml
    ├── ollama-pull-models.sh
    └── ollama-benchmark.sh
```

## Validation

1. **Ollama pod is Running:**
   ```bash
   kubectl get pods -n voxline -l app=ollama
   # Should be Running
   ```

2. **Both models are available:**
   ```bash
   kubectl exec -n voxline deploy/ollama -- ollama list
   # Should show qwen3:0.6b and qwen3:1.7b
   ```

3. **Ollama API responds from within cluster:**
   ```bash
   kubectl exec -n voxline deploy/ollama -- curl -s http://localhost:11434/api/tags
   # Should return JSON with both models
   ```

4. **Service DNS works (other pods can reach Ollama):**
   ```bash
   kubectl run -n voxline test-curl --rm -i --restart=Never --image=curlimages/curl -- \
     curl -s http://ollama.voxline.svc.cluster.local:11434/api/tags
   # Should return model list
   ```

5. **Benchmark gate passes:**
   ```bash
   make ollama-benchmark
   # Review tok/s numbers. Both models must meet minimum thresholds.
   ```

6. **Models survive pod restart:**
   ```bash
   kubectl delete pod -n voxline -l app=ollama
   kubectl wait -n voxline --for=condition=ready pod -l app=ollama --timeout=120s
   kubectl exec -n voxline deploy/ollama -- ollama list
   # Both models should still be present (stored on PVC)
   ```

## Known Risks

| Risk | Mitigation |
|---|---|
| Ollama pod OOMKilled during model pull | Memory limit is 1.5 Gi — should be sufficient. If pull fails, temporarily increase limit to 2 Gi, pull, then reduce |
| Model pull is slow (10+ minutes) | Expected for first pull in `kind`. Models are ~300MB and ~850MB. PVC ensures this only happens once |
| `/no_think` mode not working as expected | Benchmark script tests this directly. If Qwen3 ignores `/no_think` and produces reasoning, fallback to structured JSON-only prompt |
| Tok/s significantly below estimates | ARM (Apple Silicon) and Intel have very different performance profiles. Benchmark gate catches this. Have fallback models ready |

## Dependencies

- Completed: prompt-m1-01 (kind cluster)
- Completed: prompt-m1-02 (cluster foundations — metrics-server, Prometheus, Grafana, OTel Collector)
- Completed: prompt-m1-03 (NATS, MongoDB, Redis running — not strictly required for Ollama, but cluster must exist)

## Next Step

After the benchmark gate passes, proceed to **prompt-m1-05** to scaffold the project monorepo and build shared libraries (TenantContext, logging, NATS header utilities).
