# PRD: Voxline — Real-Time Voice AI Orchestrator

## Overview

Voxline is a local, mini voice AI platform that processes conversational interactions in real time. It runs entirely inside a Kubernetes cluster on a laptop and demonstrates the core patterns behind a production conversational AI system: low-latency message routing, LLM orchestration, real-time streaming, multi-tenant state management, and event-driven microservices.

This is a learning project. The goal is hands-on fluency with a specific tech stack — not a shippable product.

## Tech Stack

| Component | Technology | Why (learning goal) |
|---|---|---|
| Orchestration layer | TypeScript, Node.js | Core service framework — Express or Fastify, focus on TypeScript patterns |
| Frontend | React | Simple chat + voice UI for testing conversations |
| AI services | Python, FastAPI | LLM integration, prompt routing, response generation |
| Local LLM runtime | Ollama (default) or llama.cpp | Ollama: easiest path, OpenAI-compatible API, native streaming, good k8s story. llama.cpp: lightest possible footprint (~10MB overhead) if resources are tight. Both use GGUF quantized models |
| Local LLM models | Qwen2.5 1.5B (chat), Qwen2.5 0.5B (classification) | Two-model strategy: tiny model for intent classification, slightly larger one for conversation. Both run in Ollama. Total LLM footprint under 2 Gi |
| LLM orchestration | LangChain, LangGraph | **New.** Prompt chaining, conversation memory, stateful agent flows. Introduce in M3 after building the pipeline by hand first |
| Real-time messaging | NATS | **New.** Sub-millisecond pub/sub for the voice processing pipeline. Learn Core NATS + JetStream for durable subscriptions |
| Event streaming | Kafka | Durable event log for conversation history, analytics, replay. Already familiar — use as contrast to NATS |
| Document store | MongoDB | **New.** Conversation state, session management, tenant config. Learn document modeling vs. relational |
| Cache | Redis | Session state, LLM response caching, rate limiting |
| Container orchestration | Kubernetes (kind or minikube) | Local cluster, Helm charts, service mesh basics |
| Infrastructure | Terraform (local provider), Helm, ArgoCD | Familiar tools applied to new stack |

## Architecture

See **[VOXLINE-ARCHITECTURE.svg](VOXLINE-ARCHITECTURE.svg)** for the full system diagram with numbered hot path flow, latency targets, and cold path branches.

**Hot path (NATS):** User message → API Gateway → NATS → Intent Router → LLM Service (Qwen 0.5B classifies, Qwen 1.5B responds) → Response Composer → NATS → API Gateway → User. 5 NATS hops at <1ms each. Target: <500ms time-to-first-token. Full response streams token-by-token over 1-3s (CPU inference with a 1.5B model).

**Cold path (Kafka):** Every interaction published to Kafka for conversation history, analytics, and replay. Consumed by a simple analytics worker. Fire-and-forget — never blocks the hot path.

## Services to Build

### 1. API Gateway (`gateway/` — TypeScript, Node.js)
- WebSocket server for real-time bidirectional streaming
- REST endpoints for tenant config, conversation history
- Publishes user messages to NATS, subscribes to response subjects
- Multi-tenant: route by tenant ID, enforce rate limits via Redis
- **Learning goals:** TypeScript service architecture, WebSocket handling, NATS client integration

### 2. Intent Router (`intent-router/` — TypeScript, Node.js)
- Subscribes to NATS for incoming messages
- Classifies intent (FAQ, handoff, escalation, general conversation)
- Routes to appropriate downstream service via NATS subjects
- **Learning goals:** NATS subject-based routing, request-reply pattern, fan-out

### 3. LLM Service (`llm-service/` — Python, FastAPI)
- Calls Ollama running locally in the cluster (OpenAI-compatible `/v1/chat/completions` endpoint)
- **Two-model strategy:**
  - **Intent classification:** Qwen2.5 0.5B (Q4_K_M) — ~250MB, 30-60 tok/s. Fast enough to classify intent without noticeable latency. The Intent Router calls this via the LLM Service for classification, keeping the Intent Router itself as a pure routing service.
  - **Conversation response:** Qwen2.5 1.5B (Q4_K_M) — ~750MB, 25-45 tok/s. Good multilingual instruction following, realistic chat quality. Swap to TinyLlama 1.1B (~550MB, 20-40 tok/s) or Gemma 3 1B (~500MB, 35-60 tok/s) if preferred.
- Prompt construction with conversation context from MongoDB
- Streaming response back via NATS (token-by-token from Ollama's streaming API)
- Response caching in Redis (identical prompts within TTL)
- Provider interface so Ollama can be swapped for OpenAI/Azure OpenAI without changing the service:
  ```python
  class LLMProvider(Protocol):
      async def stream(self, messages: list[dict], model: str) -> AsyncIterator[str]: ...
  ```
- **M3 addition:** Replace hand-rolled prompt construction with LangChain. Introduce conversation memory (LangChain `ConversationBufferWindowMemory` backed by MongoDB) and prompt templates. This gives a before/after comparison — build it by hand first, then refactor with LangChain to understand what the framework gives you.
- **Learning goals:** FastAPI async patterns, NATS Python client (nats-py), streaming LLM responses, Ollama model management, model selection per task (right-sizing), LangChain prompt chains + memory

### 4. Response Composer (`response-composer/` — TypeScript, Node.js)
- Assembles final response from LLM output + business rules
- Publishes to NATS response subject and Kafka event log
- Writes conversation turn to MongoDB
- **Learning goals:** NATS + Kafka dual-publish pattern, MongoDB write patterns

### 5. Analytics Worker (`analytics/` — Python)
- Kafka consumer: processes conversation events
- Calculates metrics: response latency, conversation length, intent distribution
- Writes to MongoDB analytics collection
- **Learning goals:** Kafka consumer groups, offset management, aggregation patterns

### 6. Frontend (`ui/` — React)
- Chat interface with WebSocket connection to gateway
- Shows real-time streaming responses (token by token)
- Tenant switcher (simulate multi-tenancy)
- Simple dashboard showing analytics from the worker
- **Learning goals:** WebSocket in React, streaming UI patterns, minimal but functional

## Kubernetes Setup

```
namespace: voxline
├── gateway (Deployment + Service + Ingress)
├── intent-router (Deployment)
├── llm-service (Deployment)
├── response-composer (Deployment)
├── analytics-worker (Deployment)
├── nats (StatefulSet via Helm chart — nats-io/nats)
├── kafka (StatefulSet via Helm chart — bitnami/kafka)
├── mongodb (StatefulSet via Helm chart — bitnami/mongodb)
├── redis (Deployment via Helm chart — bitnami/redis)
├── ollama (Deployment + Service — run model on host CPU, NodePort or ClusterIP)
└── ui (Deployment + Service + Ingress)
```

- Use `kind` (Kubernetes in Docker) — lighter than minikube, better for multi-node simulation
- Helm charts for all infrastructure (NATS, Kafka, MongoDB, Redis)
- Application services deployed via Helm charts or Kustomize
- Optional: ArgoCD for GitOps if we want to practice that pattern

## Resource Estimates

Running the full stack in `kind` on a laptop. All numbers are for CPU-only inference with quantized small models.

### Local LLM Runtime Options

Before the per-component breakdown — the runtime choice affects the LLM footprint significantly:

| Runtime | Overhead | OpenAI API | Streaming | K8s Ready | Best For |
|---|---|---|---|---|---|
| **Ollama** | ~50 MB | Yes | Yes | Excellent | Default choice. Easiest model management, proven in k8s, good docs |
| **llama.cpp** (raw server) | ~10 MB | Partial | Yes | Good (needs custom image) | Extreme minimalism. Lightest footprint if every MB matters |
| **LocalAI** | ~100-200 MB | Yes | Yes | Good | Backend flexibility. Can swap between llama.cpp, whisper, etc. behind one API. Heavier than needed here |
| **vLLM / TGI** | 300-500 MB | Yes | Yes | Good | GPU-first. Not suited for CPU-only on a laptop |
| **Llamafile** | ~20 MB | HTTP (not OpenAI) | Partial | Moderate | Single-binary portability. Interesting but less k8s-native |
| **MLC LLM** | Varies | Yes | Yes | Good | ML compiler optimization. Newer, less battle-tested |

**Recommendation:** Ollama. The 50MB overhead is negligible, model management is trivial (`ollama pull`), the OpenAI-compatible API means our provider interface works out of the box, and it runs clean in a container. If we're squeezing resources hard later, we can drop to llama.cpp server mode with minimal code changes.

### Model Options (Q4_K_M quantization — the sweet spot for CPU)

| Model | Params | RAM (quantized) | Chat Quality | CPU tok/s | Role in Voxline |
|---|---|---|---|---|---|
| **Qwen2.5 0.5B** | 0.5B | ~250 Mi | Basic — good for classification/routing | 30-60 | Intent classification |
| **Gemma 3 1B** | 1B | ~500 Mi | Good for 1B class, fast | 35-60 | Alternative chat model (fastest) |
| **TinyLlama 1.1B** | 1.1B | ~550 Mi | Strong general chat, mature ecosystem | 20-40 | Alternative chat model (most proven) |
| **Qwen2.5 1.5B** | 1.5B | ~750 Mi | Good instruction following, multilingual | 25-45 | **Default chat model** |
| **Gemma 2 2B** | 2B | ~1.0 Gi | Strong, Google's efficient training | 30-50 | Upgrade if headroom allows |
| **Phi-3 Mini 3.8B** | 3.8B | ~2.3 Gi | Excellent reasoning | 8-12 | Only if 32+ GB machine |

**Default config:** Qwen2.5 0.5B for intent classification + Qwen2.5 1.5B for chat. Two models loaded in Ollama, total LLM RAM ~1.0-1.5 Gi. Massive reduction from the 3-4 Gi a single Phi-3 would need.

### Per-Component Breakdown

| Component | CPU Request | CPU Limit | RAM Request | RAM Limit | Notes |
|---|---|---|---|---|---|
| **Ollama (2 models)** | 1000m | 2000m | 1.0 Gi | 1.5 Gi | Qwen 0.5B + 1.5B loaded. Ollama keeps idle models in memory but can evict |
| **Kafka (KRaft, single broker)** | 500m | 1000m | 1.0 Gi | 1.5 Gi | KRaft mode (no Zookeeper). Tune bitnami chart defaults down for local |
| **MongoDB** | 250m | 500m | 256 Mi | 512 Mi | Single replica, WiredTiger cache capped at 256MB |
| **NATS** | 100m | 250m | 64 Mi | 128 Mi | Extremely lightweight. Core NATS + JetStream |
| **Redis** | 100m | 250m | 64 Mi | 128 Mi | In-memory, small dataset |
| **Gateway** | 100m | 250m | 128 Mi | 256 Mi | Node.js — light |
| **Intent Router** | 100m | 250m | 128 Mi | 256 Mi | Node.js — light |
| **LLM Service** | 100m | 250m | 128 Mi | 256 Mi | Python/FastAPI — just an HTTP client to Ollama |
| **Response Composer** | 100m | 250m | 128 Mi | 256 Mi | Node.js — light |
| **Analytics Worker** | 100m | 250m | 128 Mi | 256 Mi | Python — Kafka consumer, periodic writes |
| **React UI** | 50m | 100m | 64 Mi | 128 Mi | Static serve via nginx |

### Totals

| | CPU Request | CPU Limit | RAM Request | RAM Limit |
|---|---|---|---|---|
| **Infrastructure** (Ollama, Kafka, Mongo, NATS, Redis) | 1.95 cores | 4.0 cores | 2.4 Gi | 3.8 Gi |
| **Application services** (6 services) | 0.55 cores | 1.35 cores | 0.7 Gi | 1.4 Gi |
| **Total** | **2.5 cores** | **5.35 cores** | **3.1 Gi** | **5.2 Gi** |

Add ~1-2 Gi for `kind` + Docker overhead.

### What Your Machine Needs

| Machine | Verdict |
|---|---|
| **16 GB / 8 cores** | **Comfortable.** ~5 Gi for the stack + ~2 Gi Docker overhead = ~7 Gi. Plenty of room for the OS and other apps. Can even run load tests. |
| **32 GB / 10+ cores** | **Plenty of headroom.** Swap chat model to Phi-3 3.8B or Mistral 7B for better quality. Run aggressive load tests. |

The two-model strategy with sub-2B models is the difference between "close Chrome and pray" and "works fine in the background."

### Latency Reality Check

With Qwen2.5 1.5B on CPU: expect 25-45 tok/s, so a 50-100 token response completes in ~1-3 seconds. Streaming token-by-token through NATS → WebSocket means the user sees the first token in ~100-300ms. The <500ms target is **time-to-first-token** — the metric production voice AI systems actually optimize for.

Intent classification with Qwen2.5 0.5B: 30-60 tok/s for a ~10 token classification response = sub-500ms total. Effectively invisible in the pipeline.

### Going Even Lighter

If resources are truly constrained, the absolute minimum viable setup:

| Setup | LLM RAM | Runtime | Total Stack RAM | Trade-off |
|---|---|---|---|---|
| **Default** (Qwen 0.5B + 1.5B, Ollama) | ~1.0 Gi | Ollama | ~3.1 Gi request | Good balance |
| **Light** (TinyLlama 1.1B only, Ollama) | ~600 Mi | Ollama | ~2.7 Gi request | Single model, skip separate classifier |
| **Minimal** (Qwen 0.5B only, llama.cpp) | ~260 Mi | llama.cpp | ~2.0 Gi request | Basic chat quality, lightest possible |

## Multi-Tenancy (Logical Isolation)

Multi-tenancy is baked in from M1, not bolted on in M4. Every message, document, subject, and cache key carries a tenant ID from the moment it enters the system.

### Tenant Context

A `TenantContext` object is created at the gateway when a WebSocket connection is established and propagated through the entire pipeline:

```typescript
interface TenantContext {
  tenantId: string;
  sessionId: string;
  timestamp: number;
}
```

The gateway injects this into every NATS message header. Every downstream service extracts it before doing anything else. No service ever operates without a tenant context.

### Isolation by Layer

**NATS — subject hierarchy:**
```
voxline.{tenantId}.inbound        // gateway → intent router
voxline.{tenantId}.intent.faq     // intent router → FAQ handler
voxline.{tenantId}.intent.general // intent router → LLM service
voxline.{tenantId}.llm.response   // LLM service → response composer
voxline.{tenantId}.outbound       // response composer → gateway
```
Each service subscribes to `voxline.*.{its-subject}` for fan-in, but publishes to tenant-specific subjects. This means NATS does the routing — services don't need tenant-aware if/else logic internally, they just subscribe to the right subject patterns.

**MongoDB — tenant field + compound indexes:**
```javascript
// Every document
{
  tenantId: "acme",
  sessionId: "sess_abc123",
  role: "user",
  content: "What's my order status?",
  timestamp: ISODate("2026-02-09T14:30:00Z"),
  // ...
}

// Compound indexes — tenantId is always the prefix
{ tenantId: 1, sessionId: 1, timestamp: 1 }
{ tenantId: 1, createdAt: 1 }
```
No query ever runs without `tenantId` in the filter. This is enforced at the data access layer, not left to individual service code.

**Redis — key prefixes:**
```
{tenantId}:session:{sessionId}     // session state
{tenantId}:ratelimit:{windowKey}   // sliding window counter
{tenantId}:cache:{promptHash}      // LLM response cache
```

**Kafka — single topic, tenant in headers:**
```
Topic: voxline.events
Headers: { tenantId: "acme", eventType: "conversation.turn" }
Payload: { full conversation turn data }
```
Single topic keeps Kafka simple. The analytics worker filters by tenant when aggregating. If we needed per-tenant retention or throughput isolation, we'd move to per-tenant topics — but for a learning project, headers are sufficient and demonstrate the trade-off.

### Tenant Configuration

Stored in MongoDB `tenants` collection:
```javascript
{
  tenantId: "acme",
  name: "Acme Corp",
  config: {
    rateLimit: { maxPerMinute: 60 },
    llm: { chatModel: "qwen2.5:1.5b", classifyModel: "qwen2.5:0.5b", provider: "ollama", systemPrompt: "You are Acme's support agent..." },
    features: { streamingEnabled: true }
  }
}
```
The gateway loads tenant config on connection and passes relevant bits (system prompt, model selection) downstream via NATS headers. This means different tenants can have different LLM models, different system prompts, and different rate limits — which is exactly how multi-tenant SaaS works.

### What This Proves

- Tenant isolation without infrastructure duplication (no separate databases, no separate clusters)
- NATS subject hierarchy as a routing and isolation mechanism
- MongoDB compound indexing strategy for tenant-scoped queries
- The trade-off between shared-topic (Kafka) vs. tenant-subject (NATS) approaches
- Rate limiting and configuration per tenant

## LangChain + LangGraph Strategy

### Why Include Them

Conversational AI platforms (the kind this project models) need three things beyond raw LLM calls: structured prompt management, conversation memory, and multi-step orchestration. LangChain and LangGraph are the dominant open-source frameworks for all three. Understanding them — and understanding their trade-offs — is directly relevant to building and discussing this kind of system.

### Build By Hand First, Then Refactor

The deliberate approach:

**M2 (hand-rolled):** The LLM Service constructs prompts manually — string concatenation, manual context windowing (last N turns from MongoDB), direct Ollama API calls. This teaches you what's actually happening under the hood: how context windows fill up, how system prompts interact with conversation history, where token limits bite.

**M3 (LangChain refactor):** Replace the hand-rolled code with:
- `ChatPromptTemplate` for structured prompt construction
- `ConversationBufferWindowMemory` backed by MongoDB for automatic context management
- `ChatOllama` as the LLM wrapper (drop-in, since Ollama is OpenAI-compatible)
- Output parsers for structured responses (intent classification returns JSON, not freetext)

This gives you a concrete before/after comparison. You'll be able to say: "I built the prompt pipeline by hand first, then refactored with LangChain. Here's what the framework gives you — templating, memory management, output parsing — and here's what it costs you — abstraction overhead, debugging opacity, version churn."

### LangGraph for Orchestration

LangGraph models the conversation pipeline as a directed graph with state:

```
┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
│ Classify │────▶│  Route   │────▶│ Generate │────▶│ Compose  │
│  Intent  │     │          │     │ Response │     │  Output  │
└──────────┘     └────┬─────┘     └──────────┘     └──────────┘
                      │
                      ├──▶ FAQ (static lookup)
                      ├──▶ General (LLM)
                      └──▶ Escalation (human handoff)
```

Each node is a function. The graph manages state transitions, retries, and branching. This is exactly how production conversational AI platforms model their agent flows — and it's a much more interesting interview talking point than "I called the OpenAI API."

LangGraph also supports persistence (checkpoint conversation state) and human-in-the-loop (pause at a node, wait for human input) — both relevant patterns for enterprise voice AI.

### What This Doesn't Replace

LangChain/LangGraph run inside the LLM Service (Python). They don't replace NATS, Kafka, or the microservice architecture. The pipeline is still: Gateway → NATS → Intent Router → LLM Service (LangChain/LangGraph inside) → Response Composer → NATS → Gateway. The orchestration frameworks handle the AI logic; the infrastructure handles the distributed systems concerns.

## Latency Optimizations

The target is <500ms time-to-first-token. Most of that budget is Ollama inference (~100-300ms). Everything else in the pipeline needs to be nearly invisible. These optimizations are baked into the design, not applied as an afterthought.

### Tier 1: Built Into the Architecture

**1. Stream at every hop — never buffer a full response**
Every service in the hot path forwards tokens the instant they arrive. The LLM Service doesn't wait for a complete response before publishing to NATS. The Response Composer doesn't wait for all tokens before forwarding to the outbound subject. The Gateway doesn't wait before pushing to the WebSocket. Each token flows through 5 NATS hops at <1ms each and reaches the user as fast as Ollama can produce it.

This is the single biggest latency win. Without it, the user waits 1-3s for a full response. With it, the user sees the first token in ~100-300ms and the rest stream in naturally.

**2. Ollama KV cache reuse (system prompt caching)**
Ollama caches the KV cache for repeated prompt prefixes. If every request for tenant "acme" starts with the same system prompt ("You are Acme's support agent..."), Ollama only processes the new user message on subsequent requests — not the full prompt. For a 200-500 token system prompt, this can cut time-to-first-token in half on warm requests.

Implementation: Tenant system prompts are stable per-session. Ollama's caching handles this automatically as long as models stay loaded (see #3).

**3. Model preloading — keep models warm**
Ollama evicts idle models from memory. A cold model load adds 2-5 seconds — catastrophic for a real-time pipeline. Set `OLLAMA_KEEP_ALIVE=-1` in the Ollama deployment to keep both models loaded permanently. The RAM cost (~1 Gi) is already budgeted in the resource estimates.

```yaml
env:
  - name: OLLAMA_KEEP_ALIVE
    value: "-1"        # never evict
  - name: OLLAMA_NUM_PARALLEL
    value: "2"         # handle concurrent requests
```

**4. FAQ short-circuit — skip the LLM entirely**
If the Intent Router classifies a message as "FAQ", don't route to the LLM Service at all. Serve a static response from Redis or MongoDB directly. Zero LLM latency for common questions. This is a standard production pattern in voice AI — every FAQ response served without hitting the model is a win for both latency and compute.

The NATS subject hierarchy makes this clean: the Intent Router publishes to `voxline.{tenantId}.intent.faq` instead of `voxline.{tenantId}.intent.general`, and a lightweight FAQ responder (could be a function in the Response Composer) handles it.

**5. Core NATS for hot path, JetStream only where needed**
Core NATS is sub-millisecond pub/sub with no persistence overhead. JetStream adds disk writes and acknowledgment round-trips. Use Core NATS for the entire real-time pipeline. Only use JetStream where message durability matters — guaranteed delivery for the analytics cold path, or for messages that arrive while a downstream service is restarting.

### Tier 2: Implementation-Level Wins

**6. Parallel context loading**
When the LLM Service receives a message, it needs two things: the conversation context from MongoDB and the tenant's system prompt. Load them in parallel (`Promise.all` / `asyncio.gather`), not sequentially. Better yet: the Gateway pre-fetches the last N conversation turns from MongoDB and includes them in the NATS message header, so the LLM Service doesn't need to query MongoDB at all — it gets everything from the NATS message.

**7. Connection pooling everywhere**
Persistent connections to Ollama, MongoDB, Redis, NATS. All clients maintain connection pools initialized at service startup. No TCP handshake per request. This sounds obvious but it's easy to accidentally create new connections per request in Node.js HTTP clients or Python FastAPI dependency injection.

**8. Context window pruning**
Don't send the entire conversation history to the LLM. Use a sliding window — last 5-10 turns. Smaller prompts mean fewer input tokens, which means faster time-to-first-token (the model has to process the full input before generating the first output token). With Qwen 1.5B on CPU, every 100 input tokens adds roughly 50-100ms to TTFT.

**9. Redis pipelining**
When a message arrives at the Gateway, it needs to: (a) check rate limit, (b) check response cache, (c) load session state. Pipeline all three as a single Redis round-trip instead of three sequential calls. Redis pipelining turns 3 × ~1ms = ~3ms into a single ~1ms call.

```typescript
const pipeline = redis.pipeline();
pipeline.get(`${tenantId}:cache:${promptHash}`);
pipeline.incr(`${tenantId}:ratelimit:${windowKey}`);
pipeline.get(`${tenantId}:session:${sessionId}`);
const [cached, count, session] = await pipeline.exec();
```

**10. Async Kafka publish (fire-and-forget)**
The Response Composer publishes to Kafka on the cold path. This is fire-and-forget — don't await the Kafka acknowledgment before publishing the response to NATS. If the Kafka write fails, that's an analytics gap, not a user-facing problem. The cold path must never add latency to the hot path.

**11. Async MongoDB writes**
Writing the conversation turn to MongoDB happens after the response is already streaming to the user. The user doesn't need to wait for the persistence write to complete before seeing their response.

### Tier 3: Tuning

**12. Ollama `num_predict` limit**
Cap the maximum response length. For a support agent, 100-150 tokens is plenty. Shorter generation = faster total response time. Prevents the model from rambling into a 500-token essay when 50 tokens would do.

**13. Ollama `num_ctx` tuning**
Reduce the context window from the default (often 2048-4096) to what you actually need. If the sliding window is 10 turns of ~50 tokens each + a 300-token system prompt, 1024 tokens of context is plenty. Smaller context = less memory pressure and faster prompt processing.

**14. MessagePack over JSON for NATS payloads**
JSON serialization adds ~0.5-1ms per message on Node.js for a typical payload. MessagePack is 2-3x faster to serialize and produces smaller payloads. Not a massive win per hop, but across 5 hops per request under load, it adds up.

### Latency Budget

| Hop | Target | Notes |
|---|---|---|
| UI → Gateway (WebSocket) | <1ms | Persistent connection, localhost |
| Gateway: Redis pipeline (rate limit + cache) | ~1ms | Single pipelined call |
| Gateway → NATS → Intent Router | <1ms | Core NATS, sub-millisecond |
| Intent classification (Qwen 0.5B) | ~100-200ms | 10-token classification, 30-60 tok/s |
| Intent Router → NATS → LLM Service | <1ms | Core NATS |
| LLM Service: load context (pre-fetched or MongoDB) | 0-5ms | 0ms if pre-fetched in NATS header, ~5ms if querying MongoDB |
| Ollama TTFT (Qwen 1.5B, warm, pruned context) | ~100-300ms | Dominant cost. KV cache reuse helps on warm prompts |
| LLM Service → NATS → Response Composer → NATS → Gateway → UI | <3ms | 3 NATS hops + streaming pass-through |
| **Total TTFT** | **~200-500ms** | **Within budget** |
| Full response streaming | 1-3s | 50-100 tokens at 25-45 tok/s, streamed token-by-token |

### What This Teaches

These aren't just micro-optimizations — they're the patterns that production voice AI systems use. In an interview, being able to walk through a latency budget hop-by-hop, explain where the time goes, and describe the trade-offs (streaming vs. buffering, fire-and-forget vs. acknowledged writes, context pruning vs. full history) demonstrates real systems thinking. The fact that you can back it up with measured numbers from your own local cluster makes it concrete.

## Testing Strategy

The goal is proving the system works — services talking to each other, doing real work, data flowing through the pipeline correctly. Not unit test coverage for its own sake.

### Integration Tests (Primary)

These are the tests that matter. Each one exercises the real pipeline through real infrastructure (NATS, Kafka, MongoDB, Redis) running in the `kind` cluster.

**1. Full conversation round-trip**
```
Send WebSocket message as tenant "acme"
→ Verify NATS receives on voxline.acme.inbound
→ Verify Intent Router classifies and routes
→ Verify LLM Service receives, calls model, streams response
→ Verify Response Composer writes to MongoDB and publishes to Kafka
→ Verify gateway receives response on WebSocket
→ Assert: response contains LLM-generated content (not echo, not hardcoded)
→ Assert: MongoDB has the conversation turn with correct tenantId
→ Assert: Kafka topic has the event with correct headers
```

**2. Multi-turn conversation with context**
```
Send message 1: "My name is Greg"
Send message 2: "What's my name?"
→ Assert: LLM response to message 2 references "Greg"
→ Assert: MongoDB has both turns in the same session
→ Assert: LLM Service loaded conversation history from MongoDB before prompting
```
This proves MongoDB context loading actually works — the LLM couldn't answer correctly without it.

**3. Tenant isolation**
```
Send message as tenant "acme": "Set my preference to blue"
Send message as tenant "globex": "What's my preference?"
→ Assert: globex gets no knowledge of acme's preference
→ Assert: MongoDB documents are tenant-scoped
→ Assert: NATS messages went to different subject hierarchies
→ Assert: Redis cache keys are prefixed correctly
```

**4. Kafka event pipeline**
```
Send 10 messages across 2 tenants
Wait for analytics worker processing (poll MongoDB analytics collection)
→ Assert: analytics collection has per-tenant aggregated metrics
→ Assert: event count matches (no dropped messages)
→ Assert: latency percentiles are calculated
```

**5. Rate limiting**
```
Configure tenant "acme" with rateLimit.maxPerMinute = 5
Send 6 messages in rapid succession
→ Assert: first 5 succeed
→ Assert: 6th returns rate limit error via WebSocket
→ Assert: Redis sliding window counter is correct
```

**6. LLM response caching**
```
Send identical message twice as same tenant within cache TTL
→ Assert: first response hits LLM API (check latency or mock counter)
→ Assert: second response served from Redis cache (measurably faster)
→ Assert: both responses are identical
```

### How to Run

Integration tests run against the live `kind` cluster using a test harness that:
1. Connects via WebSocket to the gateway (like a real client)
2. Sends messages and asserts on responses
3. Directly queries MongoDB, Redis, and Kafka to verify side effects
4. Uses real NATS, real Kafka, real MongoDB — no mocks

```bash
# Spin up the cluster and all services
make up

# Run the full integration suite
make test-integration

# Run a specific test
make test-integration TEST=multi-turn-context
```

The test harness itself is a simple Node.js/TypeScript script using `ws` for WebSocket, `mongodb` driver for state assertions, `kafkajs` for event verification, and `ioredis` for cache checks.

### Load Testing

After integration tests pass, run load tests to understand latency characteristics:

```bash
# k6 load test: 10 concurrent tenants, 5 conversations each
make test-load TENANTS=10 CONCURRENCY=5
```

Measure:
- p50/p95/p99 end-to-end latency per conversation turn
- NATS hop latency (gateway → intent router, intent router → LLM, etc.)
- MongoDB read/write latency under concurrent tenant load
- Kafka producer latency (does dual-publish to NATS + Kafka create backpressure?)

### What We Don't Test

- Unit tests for individual functions (not worth the time for a learning project)
- UI tests (manual verification is fine)
- Performance at production scale (it's a laptop — the patterns matter, not the numbers)

## Learning Goals (Prioritized)

### P0 — Core gaps to close
1. **NATS:** Pub/sub, request-reply, subject-based routing, JetStream for durable subscriptions. Understand when to use NATS vs. Kafka in the same system.
2. **MongoDB:** Document modeling for conversations and sessions, indexing strategies, aggregation pipeline for analytics. Contrast with PostgreSQL mental model.

### P1 — Deepen existing knowledge
3. **Real-time streaming patterns:** WebSocket ↔ NATS ↔ LLM streaming pipeline. Token-by-token response delivery.
4. **Kafka + NATS coexistence:** Hot path (NATS, ephemeral, fast) vs. cold path (Kafka, durable, replayable). Dual-publish patterns.
5. **Multi-tenant architecture:** Tenant isolation in a shared infrastructure — routing, rate limiting, data segregation in MongoDB.
6. **LLM orchestration:** Prompt construction, context windowing, response streaming, caching strategies. Local model management with Ollama.
7. **LangChain + LangGraph:** Prompt chaining and templating, conversation memory backed by MongoDB, and stateful agent workflows. Build the LLM pipeline by hand first (M2), then refactor with LangChain (M3) to understand what the framework abstracts away. LangGraph extends this to graph-based conversation flows — model the intent-classify → route → generate → compose pipeline as a LangGraph state machine, which maps directly to how Parloa-style platforms orchestrate multi-step agent interactions.

### P2 — Nice to have
8. **Azure patterns:** Deploy to AKS if desired as a stretch goal. Understand Azure-specific networking, identity, and monitoring.
9. **Latency measurement:** Instrument the entire pipeline with OpenTelemetry. Measure and visualize per-stage latency.
10. **Chaos engineering:** Kill NATS/Kafka pods, observe behavior. Test graceful degradation.

## Milestones

### M1: Foundations + Tenant Model (2-3 days)
- `kind` cluster running with NATS, Kafka, MongoDB, Redis, **Ollama** via Helm/manifests
- Pull Qwen2.5 0.5B and Qwen2.5 1.5B into Ollama, verify inference works via `curl`
- Ollama configured with `KEEP_ALIVE=-1` and `NUM_PARALLEL=2` — models stay warm from day 1
- Gateway service with WebSocket server — tenant ID on connection from day 1
- TenantContext injected into every NATS message header
- Connection pools to NATS, MongoDB, Redis initialized at service startup (not per-request)
- NATS subject hierarchy (`voxline.{tenantId}.*`) working end-to-end — Core NATS for hot path
- MongoDB tenant collection seeded with 2-3 test tenants
- React UI connects with tenant selector, sends/receives messages
- **Test:** WebSocket echo through NATS with correct tenant-scoped subjects

### M2: Hot Path (2-3 days)
- Intent Router subscribing to NATS and routing messages per tenant subject
- LLM Service calling Ollama: Qwen 0.5B for intent classification, Qwen 1.5B for chat response — hand-rolled prompt construction, tenant-specific system prompts
- **Streaming at every hop:** Ollama → LLM Service → NATS → Response Composer → NATS → Gateway → WebSocket — each service forwards tokens on arrival, never buffers a full response
- FAQ short-circuit: Intent Router routes FAQ intents directly to a static responder, bypassing the LLM entirely
- Redis pipelining in Gateway: rate limit + cache check + session load in a single round-trip
- Response Composer: async Kafka publish (fire-and-forget), async MongoDB write — cold path never blocks hot path
- **Test:** Full conversation round-trip (integration test 1)
- **Test:** Tenant isolation — two tenants, verify no cross-talk (integration test 3)

### M3: Cold Path + Context + LangChain (2-3 days)
- Kafka event log for all conversation turns (tenant in headers)
- MongoDB storing conversation history, loaded as context for LLM
- **Refactor LLM Service:** Replace hand-rolled prompt construction with LangChain prompt templates and `ConversationBufferWindowMemory` backed by MongoDB. Compare before/after — understand what LangChain abstracts.
- **Introduce LangGraph:** Model the intent-classify → route → generate → compose flow as a LangGraph state machine. This replaces the implicit NATS-based flow with an explicit, visualizable graph.
- Analytics worker consuming from Kafka and writing per-tenant metrics
- Rate limiting per tenant via Redis sliding window
- **Test:** Multi-turn conversation with context (integration test 2)
- **Test:** Kafka event pipeline (integration test 4)
- **Test:** Rate limiting (integration test 5)

### M4: Polish + Load (1-2 days)
- LLM response caching in Redis (integration test 6)
- Analytics dashboard in React UI
- Latency instrumentation with OpenTelemetry — measure per-hop latency against the latency budget
- Ollama tuning: `num_predict` cap (100-150 tokens), `num_ctx` reduction (1024), verify KV cache reuse across requests
- Gateway: context pre-fetching — include last N conversation turns in the NATS message header so LLM Service skips the MongoDB query
- k6 load test: 10 concurrent tenants — validate latency budget under concurrency
- Try Phi-3 3.8B or Gemma 2 2B if machine has headroom — compare quality vs. latency trade-off across model sizes
- Optional: MessagePack for NATS payloads — measure serialization speedup vs. JSON
- **Test:** Load test with latency percentiles

## Success Criteria

- [ ] Can explain NATS vs. Kafka trade-offs from hands-on experience, not just docs
- [ ] Comfortable with MongoDB document modeling and aggregation pipeline
- [ ] Can build a TypeScript Node.js service from scratch with clean architecture
- [ ] Time-to-first-token <500ms for a conversation turn (local Ollama + streaming)
- [ ] All 6 integration tests pass — proving real services doing real work through real infrastructure
- [ ] Can articulate what LangChain gives you vs. hand-rolled prompt construction — built it both ways
- [ ] Can whiteboard the full architecture and explain every design decision
- [ ] Feels natural to discuss in an interview — not theoretical, built and ran it

## Non-Goals

- Production readiness, TLS, auth, RBAC
- Voice/audio processing (text chat is sufficient to learn the patterns)
- Azure deployment (stretch goal only)
- Performance at scale (it's a laptop)
