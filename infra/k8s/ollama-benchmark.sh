#!/bin/bash
set -euo pipefail

# Benchmark gate for Ollama model selection.
# Measures tok/s (generation throughput) and TTFT (time-to-first-token).
# Validates thinking mode is suppressed (think:false API parameter).
# Exits non-zero if any metric falls below threshold.
#
# IMPORTANT: Qwen3 thinking mode suppression requires "think":false in the
# Ollama API request body. The /no_think prompt prefix does NOT work with
# Ollama >= 0.15 — the model ignores it and generates thinking tokens,
# producing an empty response with inflated eval_count.

CLASSIFY_TPS_THRESHOLD=25
CHAT_TPS_THRESHOLD=20
TTFT_THRESHOLD_MS=500

FAILED=0

echo "=== OLLAMA BENCHMARK GATE ==="
echo ""

# Warmup: 3 requests to ensure model is loaded and KV cache is primed.
# A single warmup isn't enough — load_duration and prompt_eval_duration
# remain high for the first 2-3 requests after a pod restart.
echo "Warming up model (3 requests, not measured)..."
for _ in $(seq 1 3); do
  curl -s --max-time 120 http://localhost:11434/api/generate \
    -d '{"model": "qwen3:0.6b", "prompt": "warmup", "stream": false, "think": false, "options": {"num_predict": 1}}' > /dev/null
done
echo ""

parse_result() {
  local run_num="$1"
  local tps_threshold="$2"
  python3 -c "
import sys, json

run = sys.argv[1]
tps_thresh = float(sys.argv[2])
ttft_thresh = float(sys.argv[3])
data = sys.stdin.read().strip()

if not data:
    print(f'  Run {run}: ERROR — empty response from Ollama')
    sys.exit(1)

try:
    r = json.loads(data)
except json.JSONDecodeError as e:
    print(f'  Run {run}: ERROR — invalid JSON: {e}')
    sys.exit(1)

# tok/s: eval_count / eval_duration (generation throughput)
eval_dur = r.get('eval_duration', 0)
eval_count = r.get('eval_count', 0)
tps = eval_count / (eval_dur / 1e9) if eval_dur else 0

# TTFT: load_duration + prompt_eval_duration (time before first generated token)
load_dur_ms = r.get('load_duration', 0) / 1e6
prompt_eval_ms = r.get('prompt_eval_duration', 0) / 1e6
ttft_ms = load_dur_ms + prompt_eval_ms

total_s = r.get('total_duration', 0) / 1e9
resp = r.get('response', '').strip()[:60]

# Thinking mode validation: check if think:false was respected.
# If response is empty but thinking field has content, the model ignored think:false.
thinking = r.get('thinking', '')
think_warn = ''
if thinking:
    think_warn = f' WARNING: thinking mode active ({len(thinking)} chars) — think:false not respected'
if not resp and not thinking:
    think_warn = ' WARNING: empty response and no thinking — possible model issue'

# Check thresholds
fail_markers = []
if tps < tps_thresh:
    fail_markers.append(f'tok/s below {tps_thresh}')
if ttft_ms > ttft_thresh:
    fail_markers.append(f'TTFT above {ttft_thresh}ms')
if thinking:
    fail_markers.append('thinking mode not suppressed')

status = ' FAIL: ' + ', '.join(fail_markers) if fail_markers else ''

print(f'  Run {run}: {total_s:.2f}s total, {tps:.1f} tok/s, TTFT {ttft_ms:.0f}ms (load {load_dur_ms:.0f}ms + prompt {prompt_eval_ms:.0f}ms), response: {resp}{think_warn}{status}')

# Exit non-zero if any threshold missed
if fail_markers:
    sys.exit(1)
" "$run_num" "$tps_threshold" "$TTFT_THRESHOLD_MS"
}

echo "--- Qwen3 0.6B (classification, think:false) ---"
echo "Thresholds: >= ${CLASSIFY_TPS_THRESHOLD} tok/s, TTFT < ${TTFT_THRESHOLD_MS}ms"
echo "Testing 5 classification requests..."
for i in $(seq 1 5); do
  if ! curl -s --max-time 120 http://localhost:11434/api/generate \
    -d '{
      "model": "qwen3:0.6b",
      "prompt": "Classify the following user message into exactly one category: faq, general, escalation.\nUser: What are your business hours?\nCategory:",
      "stream": false,
      "think": false,
      "options": { "num_predict": 10, "presence_penalty": 1.5 }
    }' | parse_result "$i" "$CLASSIFY_TPS_THRESHOLD"; then
    FAILED=1
  fi
done

echo ""
echo "--- Qwen3 0.6B (chat, think:false) ---"
echo "Thresholds: >= ${CHAT_TPS_THRESHOLD} tok/s, TTFT < ${TTFT_THRESHOLD_MS}ms"
echo "Testing 5 chat requests..."
for i in $(seq 1 5); do
  if ! curl -s --max-time 120 http://localhost:11434/api/generate \
    -d '{
      "model": "qwen3:0.6b",
      "prompt": "You are a helpful support agent. Answer briefly.\nUser: How do I reset my password?\nAgent:",
      "stream": false,
      "think": false,
      "options": { "num_predict": 50, "presence_penalty": 1.5 }
    }' | parse_result "$i" "$CHAT_TPS_THRESHOLD"; then
    FAILED=1
  fi
done

echo ""
echo "=== DECISION GATE ==="
echo ""
echo "PASS criteria (Qwen3 0.6B for both roles):"
echo "  Classification: >= ${CLASSIFY_TPS_THRESHOLD} tok/s"
echo "  Chat:           >= ${CHAT_TPS_THRESHOLD} tok/s"
echo "  TTFT:           < ${TTFT_THRESHOLD_MS}ms (load + prompt eval)"
echo "  Thinking:       suppressed (think:false respected)"
echo ""

if [ "$FAILED" -eq 0 ]; then
  echo "RESULT: ALL RUNS PASSED"
else
  echo "RESULT: SOME RUNS FAILED — review output above"
  echo ""
  echo "If tok/s is low → check Docker Desktop CPU allocation and other pod resource usage"
  echo "If TTFT > 500ms → model may need more warmup runs, or pod just restarted"
  echo "If thinking mode active → Ollama version may not support think:false parameter"
  echo ""
  echo "Fallback models: TinyLlama 1.1B or Gemma 3 1B"
fi

echo ""
echo "Note: Qwen3 1.7B was benchmarked at 0.5-0.9 tok/s inside Docker Desktop"
echo "(no Metal acceleration). Use 1.7B only if running Ollama natively or with"
echo "Docker Desktop memory increased to >= 16 GB."
echo ""

exit "$FAILED"
