# M1-04: Deploy Ollama and Run Model Benchmark Gate

## Context

NATS, MongoDB, and Redis are running in the `kind` cluster (from prompt-m1-03). Now deploy Ollama, pull the Qwen3 models, and run the benchmark gate.

**This is a gated decision point.** The entire latency budget depends on actual tok/s performance. If numbers don't meet targets, model selection must be adjusted before building any services.

## Benchmark Gate Outcome

**Decision: Qwen3 0.6B for both classification and chat.**

The benchmark gate revealed that Qwen3 1.7B is unusable inside Docker Desktop's virtualization layer — no Metal acceleration means CPU inference runs at 0.5-0.9 tok/s (vs. the estimated 25-45 tok/s natively on Apple Silicon). Qwen3 0.6B performs well at 28-54 tok/s when warm, exceeding all thresholds.

| Model | Role | Warm tok/s | Threshold | Verdict |
|---|---|---|---|---|
| Qwen3 0.6B | Classification | 28-54 tok/s | >= 25 | **PASS** |
| Qwen3 0.6B | Chat | 18-38 tok/s | >= 20 | **PASS** |
| Qwen3 1.7B | Chat | 0.5-0.9 tok/s | >= 20 | **FAIL** |

**Root cause:** Ollama inside Docker Desktop on macOS ARM runs without Metal acceleration. The Docker VM uses software-only CPU inference, which is orders of magnitude slower for larger models. The 0.6B model's smaller weight footprint and KV cache make it viable even under this constraint.

**Important — thinking mode suppression:** Qwen3's `/no_think` prompt prefix does **not** work with Ollama >= 0.15. The model ignores it and generates thinking tokens, producing an empty `response` field with inflated `eval_count`. All Ollama API requests to Qwen3 must use `"think": false` in the request body to suppress thinking mode. The benchmark script validates this by checking for a `thinking` field in the response.

**Upgrade path:** If Docker Desktop memory is increased to >= 16 GB, or if Ollama is run natively outside the cluster (with Metal acceleration), the 1.7B model can be reintroduced. The `ollama pull qwen3:1.7b` command is all that's needed — the manifest and services use model names from tenant config, so switching is a config change.

### Memory Tuning Journey

The original estimate of 1.5 Gi for "both models loaded" was wrong. Loading two models simultaneously inside the container triggered repeated OOMKills even at 5 Gi due to KV cache allocation overhead (`OLLAMA_NUM_PARALLEL=2` × `default_num_ctx=4096` × two models). The final config uses a single model with 2 Gi limit:

| Attempt | Memory Limit | Models | Result |
|---|---|---|---|
| 1 | 1.5 Gi | 2 models | OOMKilled during 1.7B warm load |
| 2 | 2.0 Gi | 2 models | OOMKilled during 1.7B warm load |
| 3 | 3.0 Gi | 2 models (`MAX_LOADED_MODELS=1`) | OOMKilled during 1.7B inference |
| 4 | 4.0 Gi | 1.7B only (`MAX_LOADED_MODELS=1`) | Stable but 0.5-0.9 tok/s |
| **5** | **2.0 Gi** | **0.6B only** | **Stable, 28-54 tok/s (warm)** |

## Resource Budget (As-Built)

| Component | CPU Request | CPU Limit | RAM Request | RAM Limit |
|---|---|---|---|---|
| Ollama (1 model loaded) | 1000m | 2000m | 1.0 Gi | 2.0 Gi |

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
              value: "-1"           # Never evict model from memory
            - name: OLLAMA_NUM_PARALLEL
              value: "2"            # Handle concurrent requests to qwen3:0.6b
            - name: OLLAMA_HOST
              value: "0.0.0.0"
            - name: OLLAMA_CONTEXT_LENGTH
              value: "2048"         # Halved from 4096 default — sufficient for chat + classification
          resources:
            requests:
              cpu: 1000m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 2Gi           # Qwen3 0.6B (~500 Mi) + KV cache + inference headroom
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
      storage: 3Gi              # Oversized for single 0.6B model (~522 MB) but PVC can't shrink in-place
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
- **PersistentVolumeClaim** for model storage — model survives pod restarts, no re-downloading
- **`OLLAMA_KEEP_ALIVE=-1`** — model stays loaded permanently (never evicted)
- **`OLLAMA_NUM_PARALLEL=2`** — handle concurrent requests to the single 0.6B model
- **`OLLAMA_CONTEXT_LENGTH=2048`** — halved from 4096 default to reduce KV cache memory
- **2 Gi memory limit** — tuned from OOM testing. 0.6B model weights (~500 Mi) + KV cache + inference overhead

### 2. Model pull script

Create `infra/k8s/ollama-pull-models.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Benchmark gate decision: Qwen3 0.6B for both classification and chat.
# Qwen3 1.7B achieves only 0.5-0.9 tok/s inside Docker Desktop (no Metal acceleration).
#
# IMPORTANT: Use "think":false in all Ollama API requests to Qwen3.
# The /no_think prompt prefix does NOT work with Ollama >= 0.15.

echo "Waiting for Ollama pod to be ready..."
kubectl wait -n voxline --for=condition=ready pod -l app=ollama --timeout=120s

echo "Pulling Qwen3 0.6B (classification + chat model)..."
kubectl exec -n voxline deploy/ollama -- ollama pull qwen3:0.6b

echo "Verifying model is available..."
kubectl exec -n voxline deploy/ollama -- ollama list

echo "Pre-loading Qwen3 0.6B..."
curl -s --max-time 120 http://localhost:11434/api/generate \
  -d '{"model": "qwen3:0.6b", "prompt": "warmup", "stream": false, "think": false, "options": {"num_predict": 1}}' > /dev/null

echo ""
echo "Model pulled and pre-loaded."
echo "Active model: qwen3:0.6b (both classification and chat)"
```

**Notes:**

- The original script used `ollama run qwen3:0.6b "" --keepalive -1` for warm loading, but the `--keepalive` flag requires a time unit (e.g., `-1s`), not a bare `-1`. The API-based warm load via `curl` is more reliable.
- The warm load uses `"think": false` to suppress Qwen3's thinking mode. Without this, the model generates thinking tokens and returns an empty response.

### 3. Benchmark script

Create `infra/k8s/ollama-benchmark.sh`:

This is the **decision gate**. Run it manually and read the output. Exits non-zero if any run fails.

The benchmark measures three things:

1. **tok/s** — generation throughput from Ollama's `eval_count / eval_duration`
2. **TTFT** — time-to-first-token from `load_duration + prompt_eval_duration`
3. **Thinking suppression** — validates `think:false` is respected (no `thinking` field in response)

Key design decisions:

- **3 warmup requests** before measured runs — a single warmup isn't enough; `load_duration` and `prompt_eval_duration` remain high for the first 2-3 requests after a pod restart
- **`"think": false`** in every request — the `/no_think` prompt prefix does not work with Ollama >= 0.15
- **Automated pass/fail** — exits non-zero if any run falls below tok/s threshold, exceeds TTFT threshold, or has thinking mode active
- **Per-run TTFT breakdown** — shows load vs. prompt eval components so you can distinguish cold model loading from prompt processing

See [ollama-benchmark.sh](../infra/k8s/ollama-benchmark.sh) for the full script.

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
   # Should be Running, 0 restarts
   ```

2. **Model is available:**
   ```bash
   kubectl exec -n voxline deploy/ollama -- ollama list
   # Should show qwen3:0.6b
   ```

3. **Ollama API responds via HostPort:**
   ```bash
   curl -s http://localhost:11434/api/tags
   # Should return JSON with qwen3:0.6b
   ```
   Note: The Ollama container image does not include `curl`, so `kubectl exec ... curl` will not work. Use the HostPort (NodePort 30434 → localhost:11434) instead.

4. **Service DNS works (other pods can reach Ollama):**
   ```bash
   kubectl run -n voxline test-curl --rm -i --restart=Never --image=curlimages/curl -- \
     curl -s http://ollama.voxline.svc.cluster.local:11434/api/tags
   # Should return model list
   ```

5. **Benchmark gate passes:**
   ```bash
   make ollama-benchmark
   # Review tok/s numbers. Qwen3 0.6B must meet thresholds for both classification and chat.
   ```

6. **Model survives pod restart:**
   ```bash
   kubectl delete pod -n voxline -l app=ollama
   kubectl wait -n voxline --for=condition=ready pod -l app=ollama --timeout=120s
   kubectl exec -n voxline deploy/ollama -- ollama list
   # qwen3:0.6b should still be present (stored on PVC)
   ```

## Known Risks

| Risk | Mitigation | Status |
|---|---|---|
| Ollama pod OOMKilled during model pull | Memory limit set to 2 Gi — sufficient for 0.6B. If using 1.7B, temporarily increase limit | Resolved for 0.6B |
| Model pull is slow (10+ minutes) | Expected for first pull in `kind`. Model is ~522 MB. PVC ensures this only happens once | Expected |
| `/no_think` prompt prefix does not work with Ollama >= 0.15 | **Triggered.** The model ignores `/no_think` in the prompt and generates thinking tokens, producing an empty `response` with inflated `eval_count`. Use `"think": false` in the Ollama API request body instead. The benchmark validates this by checking for a `thinking` field in the response | Resolved — all API calls use `think:false` |
| Tok/s significantly below estimates | **Triggered.** 1.7B achieved 0.5-0.9 tok/s inside Docker Desktop (no Metal). Decision gate activated — using 0.6B for both roles | Resolved |
| `ollama run --keepalive -1` flag syntax error | The `--keepalive` flag requires a time unit (e.g., `-1s`). Use the HTTP API for warm loading instead | Resolved |
| Ollama container has no `curl` | Cannot use `kubectl exec ... curl` for API validation. Use HostPort (localhost:11434) or a sidecar curl container | Resolved |
| OOM when loading two models simultaneously | KV cache allocation for two models with `NUM_PARALLEL=2` and `num_ctx=4096` exceeds container memory even at 5 Gi. Single-model config (`MAX_LOADED_MODELS` not needed) avoids this entirely | Resolved |
| Docker Desktop memory limit (7.65 Gi) constrains cluster | kind + observability + infrastructure already uses ~2.5 Gi. Ollama gets 2 Gi of the remaining ~5 Gi. Larger models require increasing Docker Desktop memory allocation | Documented |
| tok/s highly variable under Docker Desktop CPU contention | Warm tok/s ranges 8-54 depending on host CPU load. The Docker VM shares CPU with macOS processes. Benchmark runs after heavy host activity may show lower numbers. 3 warmup requests help stabilize, but variance remains | Documented — benchmark uses warmup and per-run reporting |

## Impact on Downstream Prompts

The benchmark gate decision to use Qwen3 0.6B for both roles affects several aspects of the system documented in the README:

1. **Latency budget:** Classification and chat use the same model, so there's no model-swap penalty on the hot path. TTFT should be faster than the two-model design since 0.6B is smaller.
2. **Tenant config:** The default `chatModel` and `classifyModel` in tenant config will both be `qwen3:0.6b`. The provider interface remains the same.
3. **LLM Service (M2):** The two-model strategy simplifies to a single model. The LLM Service still supports model selection per-request via tenant config, so upgrading to 1.7B later is a config change. **All Ollama API calls must include `"think": false`** to suppress Qwen3's thinking mode — the `/no_think` prompt prefix does not work with Ollama >= 0.15.
4. **Quality:** 0.6B chat quality is lower than 1.7B. The response quality rubric (M4) will establish the baseline. LangGraph refactoring (M3) may compensate somewhat through better prompt construction.

## Dependencies

- Completed: prompt-m1-01 (kind cluster)
- Completed: prompt-m1-02 (cluster foundations — metrics-server, Prometheus, Grafana, OTel Collector)
- Completed: prompt-m1-03 (NATS, MongoDB, Redis running — not strictly required for Ollama, but cluster must exist)

## Next Step

After the benchmark gate passes, proceed to **prompt-m1-05** to scaffold the project monorepo and build shared libraries (TenantContext, logging, NATS header utilities).
