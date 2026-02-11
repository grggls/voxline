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
