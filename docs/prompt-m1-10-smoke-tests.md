# M1-10: Smoke Tests (End-to-End M1 Validation)

## Context

All M1 components are deployed: kind cluster, NATS (Core + JetStream), MongoDB (seeded), Redis, Ollama (benchmarked), Gateway, echo responder, and React UI (from prompts m1-01 through m1-09).

Now write the automated smoke test suite that validates M1 success criteria. These tests run against the live `kind` cluster — no mocks. They prove the pipeline works end-to-end before moving to M2.

## M1 Success Criteria to Validate

From the PRD:
1. WebSocket echo through NATS with correct tenant-scoped subjects
2. Request tracing — `requestId` propagates through all hops with timestamps
3. Tenant context extraction/injection round-trip (unit test — already in prompt-m1-05)
4. Multi-tenant isolation (no cross-talk between tenants)
5. JetStream stream `VOXLINE_EVENTS` exists and accepts publishes
6. All infrastructure accessible (NATS, MongoDB, Redis, Ollama)

## What to Build

### 1. Test harness structure

```
tests/
├── m1/
│   ├── smoke.test.ts          # All M1 smoke tests
│   ├── helpers/
│   │   ├── ws-client.ts       # WebSocket test client
│   │   ├── nats-client.ts     # Direct NATS connection for assertions
│   │   ├── mongo-client.ts    # Direct MongoDB connection for assertions
│   │   └── redis-client.ts    # Direct Redis connection for assertions
│   └── setup.ts               # Global setup/teardown
├── jest.config.js
└── package.json
```

### 2. `tests/package.json`

```json
{
  "name": "@voxline/tests",
  "version": "0.1.0",
  "scripts": {
    "test": "jest --runInBand --forceExit",
    "test:m1": "jest --runInBand --forceExit --testPathPattern=m1/"
  },
  "devDependencies": {
    "jest": "^30",
    "ts-jest": "^30",
    "@jest/globals": "^30",
    "@types/jest": "^30",
    "ws": "^8.16",
    "@types/ws": "^8",
    "@nats-io/transport-node": "^3.3",
    "@nats-io/jetstream": "^3.3",
    "mongodb": "^7.1",
    "ioredis": "^5.3",
    "typescript": "^5.9"
  }
}
```

### 3. `tests/jest.config.js`

```javascript
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testTimeout: 30000,        // 30s — some tests wait for NATS messages
  testMatch: ['**/*.test.ts'],
  globalSetup: './m1/setup.ts',
};
```

### 4. `tests/m1/helpers/ws-client.ts`

A test helper that wraps WebSocket for cleaner test assertions:

```typescript
import WebSocket from 'ws';

export interface WsMessage {
  type: string;
  content: string;
  requestId?: string;
  timestamps?: Array<{ service: string; event: string; ts: number }>;
}

export class TestWsClient {
  private ws: WebSocket | null = null;
  private messageQueue: WsMessage[] = [];
  private resolvers: Array<(msg: WsMessage) => void> = [];

  constructor(private baseUrl: string = 'ws://localhost:8080/ws') {}

  async connect(tenantId: string): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${this.baseUrl}?tenantId=${tenantId}`);
      this.ws.on('open', () => resolve());
      this.ws.on('error', (err) => reject(err));
      this.ws.on('message', (data: Buffer) => {
        try {
          const msg = JSON.parse(data.toString()) as WsMessage;
          if (this.resolvers.length > 0) {
            this.resolvers.shift()!(msg);
          } else {
            this.messageQueue.push(msg);
          }
        } catch {
          // ignore unparseable
        }
      });
    });
  }

  send(content: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('WebSocket not connected');
    }
    this.ws.send(JSON.stringify({ content }));
  }

  /** Wait for the next incoming message, with timeout */
  async waitForMessage(timeoutMs: number = 10000): Promise<WsMessage> {
    if (this.messageQueue.length > 0) {
      return this.messageQueue.shift()!;
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('Timeout waiting for message')), timeoutMs);
      this.resolvers.push((msg) => {
        clearTimeout(timer);
        resolve(msg);
      });
    });
  }

  close(): void {
    this.ws?.close();
    this.ws = null;
    this.messageQueue = [];
    this.resolvers = [];
  }
}
```

### 5. `tests/m1/helpers/nats-client.ts`

```typescript
import { connect, NatsConnection } from '@nats-io/transport-node';

export async function createNatsClient(): Promise<NatsConnection> {
  // NATS is accessible via NodePort on localhost:4222
  return connect({
    servers: process.env.NATS_URL || 'nats://localhost:4222',
  });
}
```

### 6. `tests/m1/helpers/mongo-client.ts`

```typescript
import { MongoClient, Db } from 'mongodb';

let client: MongoClient;
let db: Db;

export async function getMongoDb(): Promise<Db> {
  if (!db) {
    const url = process.env.MONGODB_URL || 'mongodb://localhost:27017/voxline';
    client = new MongoClient(url);
    await client.connect();
    db = client.db();
  }
  return db;
}

export async function closeMongo(): Promise<void> {
  await client?.close();
}
```

### 7. `tests/m1/helpers/redis-client.ts`

```typescript
import Redis from 'ioredis';

let redis: Redis;

export function getRedis(): Redis {
  if (!redis) {
    redis = new Redis(process.env.REDIS_URL || 'redis://localhost:6379');
  }
  return redis;
}

export async function closeRedis(): Promise<void> {
  await redis?.quit();
}
```

### 8. `tests/m1/setup.ts`

Global setup that verifies infrastructure is reachable before running tests. All services are accessible via NodePort on localhost — no port-forwards needed.

```typescript
export default async function globalSetup() {
  console.log('\n=== M1 Smoke Tests: Verifying Infrastructure ===\n');

  // All services are directly accessible via kind extraPortMappings + NodePort.
  // No kubectl port-forward needed. See prompt-m1-01 Endpoint Reference table.
  const checks = [
    { name: 'Gateway health', url: 'http://localhost:8080/health' },
    { name: 'Ollama API', url: 'http://localhost:11434/api/tags' },
  ];

  for (const check of checks) {
    try {
      const res = await fetch(check.url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      console.log(`  ✓ ${check.name}`);
    } catch (err) {
      console.error(`  ✗ ${check.name}: ${err}`);
      throw new Error(`Infrastructure not ready: ${check.name} failed. Is the kind cluster running?`);
    }
  }

  console.log('\n=== Infrastructure OK — running tests ===\n');
}
```

### 9. `tests/m1/smoke.test.ts`

The main test file:

```typescript
import { describe, test, expect, afterAll, beforeAll } from '@jest/globals';
import { TestWsClient, WsMessage } from './helpers/ws-client';
import { createNatsClient } from './helpers/nats-client';
import { getMongoDb, closeMongo } from './helpers/mongo-client';
import { getRedis, closeRedis } from './helpers/redis-client';
import { NatsConnection } from '@nats-io/transport-node';
import { jetstream, jetstreamManager } from '@nats-io/jetstream';

let nats: NatsConnection;

beforeAll(async () => {
  nats = await createNatsClient();
});

afterAll(async () => {
  await nats?.close();
  await closeMongo();
  await closeRedis();
});

describe('M1 Smoke Tests', () => {
  // ----- TEST 1: WebSocket Echo Round-Trip -----
  describe('WebSocket echo through NATS', () => {
    test('sends a message and receives echo response', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      client.send('Hello from smoke test');
      const response = await client.waitForMessage();

      expect(response.type).toBe('message');
      expect(response.content).toContain('[echo]');
      expect(response.content).toContain('Hello from smoke test');
      expect(response.requestId).toMatch(/^req_/);

      client.close();
    });

    test('multiple messages get individual responses', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      client.send('message one');
      const resp1 = await client.waitForMessage();
      expect(resp1.content).toContain('message one');

      client.send('message two');
      const resp2 = await client.waitForMessage();
      expect(resp2.content).toContain('message two');

      // Each response has a unique requestId
      expect(resp1.requestId).not.toBe(resp2.requestId);

      client.close();
    });
  });

  // ----- TEST 2: Request Tracing -----
  describe('Request tracing', () => {
    test('response contains timestamps array with gateway and echo-responder entries', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      client.send('trace test');
      const response = await client.waitForMessage();

      expect(response.timestamps).toBeDefined();
      expect(response.timestamps!.length).toBeGreaterThanOrEqual(2);

      // Should have gateway entry
      const gatewayEntry = response.timestamps!.find(
        (t) => t.service === 'gateway' && t.event === 'received'
      );
      expect(gatewayEntry).toBeDefined();

      // Should have echo-responder entries
      const echoReceived = response.timestamps!.find(
        (t) => t.service === 'echo-responder' && t.event === 'received'
      );
      const echoResponded = response.timestamps!.find(
        (t) => t.service === 'echo-responder' && t.event === 'responded'
      );
      expect(echoReceived).toBeDefined();
      expect(echoResponded).toBeDefined();

      // Timestamps should be monotonically increasing
      for (let i = 1; i < response.timestamps!.length; i++) {
        expect(response.timestamps![i].ts).toBeGreaterThanOrEqual(
          response.timestamps![i - 1].ts
        );
      }

      client.close();
    });

    test('pipeline latency is under 500ms for echo', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      client.send('latency check');
      const response = await client.waitForMessage();

      const timestamps = response.timestamps!;
      const firstTs = timestamps[0].ts;
      const lastTs = timestamps[timestamps.length - 1].ts;
      const pipelineLatency = lastTs - firstTs;

      // Echo pipeline (no LLM) should be well under 100ms
      expect(pipelineLatency).toBeLessThan(500);

      client.close();
    });
  });

  // ----- TEST 3: Multi-Tenant Isolation -----
  describe('Tenant isolation', () => {
    test('two tenants get independent echo responses', async () => {
      const acme = new TestWsClient();
      const globex = new TestWsClient();

      await acme.connect('acme');
      await globex.connect('globex');

      acme.send('acme message');
      globex.send('globex message');

      const acmeResp = await acme.waitForMessage();
      const globexResp = await globex.waitForMessage();

      expect(acmeResp.content).toContain('acme message');
      expect(globexResp.content).toContain('globex message');

      // Verify no cross-talk: acme didn't get globex's message
      expect(acmeResp.content).not.toContain('globex');
      expect(globexResp.content).not.toContain('acme message');

      acme.close();
      globex.close();
    });

    test('unknown tenant is rejected', async () => {
      const client = new TestWsClient();
      await expect(client.connect('nonexistent')).rejects.toThrow();
      client.close();
    });
  });

  // ----- TEST 4: NATS Subject Hierarchy -----
  describe('NATS subject hierarchy', () => {
    test('messages are published to tenant-scoped subjects', async () => {
      // Subscribe to acme's inbound before sending a message
      const sub = nats.subscribe('voxline.acme.inbound');
      const msgPromise = (async () => {
        for await (const msg of sub) {
          sub.unsubscribe();
          return JSON.parse(msg.string());
        }
      })();

      const client = new TestWsClient();
      await client.connect('acme');
      client.send('subject test');

      const natsMsg = await msgPromise;
      expect(natsMsg.tenantContext.tenantId).toBe('acme');
      expect(natsMsg.content).toBe('subject test');

      await client.waitForMessage(); // consume echo
      client.close();
    });
  });

  // ----- TEST 5: JetStream Stream Exists -----
  describe('JetStream VOXLINE_EVENTS stream', () => {
    test('stream exists and accepts test publish', async () => {
      const jsm = await jetstreamManager(nats);
      const streamInfo = await jsm.streams.info('VOXLINE_EVENTS');

      expect(streamInfo.config.name).toBe('VOXLINE_EVENTS');
      expect(streamInfo.config.subjects).toContain('voxline.events.>');

      // Publish a test event
      const js = jetstream(nats);
      const ack = await js.publish(
        'voxline.events.test',
        JSON.stringify({ type: 'smoke_test', ts: Date.now() })
      );
      expect(ack.seq).toBeGreaterThan(0);
    });
  });

  // ----- TEST 6: MongoDB Tenants Accessible -----
  describe('MongoDB tenant data', () => {
    test('all three seed tenants exist', async () => {
      const db = await getMongoDb();
      const tenants = await db.collection('tenants').find({}).toArray();

      const ids = tenants.map((t) => t.tenantId);
      expect(ids).toContain('acme');
      expect(ids).toContain('globex');
      expect(ids).toContain('initech');
    });

    test('tenant config has required fields', async () => {
      const db = await getMongoDb();
      const acme = await db.collection('tenants').findOne({ tenantId: 'acme' });

      expect(acme).toBeDefined();
      expect(acme!.config.rateLimit.maxPerMinute).toBeGreaterThan(0);
      expect(acme!.config.llm.chatModel).toBe('qwen3:1.7b');
      expect(acme!.config.llm.classifyModel).toBe('qwen3:0.6b');
      expect(acme!.config.llm.systemPrompt).toBeTruthy();
    });

    test('compound indexes exist on conversations collection', async () => {
      const db = await getMongoDb();
      const indexes = await db.collection('conversations').indexes();
      const indexKeys = indexes.map((i) => Object.keys(i.key));

      // Should have tenant+session+timestamp compound index
      const hasCompound = indexKeys.some(
        (keys) =>
          keys[0] === 'tenantId' &&
          keys.includes('sessionId') &&
          keys.includes('timestamp')
      );
      expect(hasCompound).toBe(true);
    });
  });

  // ----- TEST 7: Redis Accessible -----
  describe('Redis connectivity', () => {
    test('can set and get a key', async () => {
      const redis = getRedis();
      await redis.set('voxline:smoke:test', 'ok', 'EX', 10);
      const val = await redis.get('voxline:smoke:test');
      expect(val).toBe('ok');
      await redis.del('voxline:smoke:test');
    });
  });

  // ----- TEST 8: Ollama Health -----
  describe('Ollama accessibility', () => {
    test('Ollama API responds with model list', async () => {
      // Ollama is accessible via NodePort on localhost:11434
      const res = await fetch(
        process.env.OLLAMA_URL || 'http://localhost:11434/api/tags'
      );
      expect(res.ok).toBe(true);

      const data = await res.json();
      const modelNames = data.models.map((m: any) => m.name);

      // Both models should be available
      expect(modelNames.some((n: string) => n.includes('qwen3:0.6b') || n.includes('qwen3'))).toBe(true);
    });
  });
});
```

### 10. Makefile targets

Add to root `Makefile`:

```makefile
.PHONY: test-m1

test-m1:
	cd tests && npm test -- --testPathPattern=m1/
```

## Running the Tests

All services are accessible via NodePort on localhost — no port-forwards needed. Just run:

```bash
make test-m1
```

## Expected Output

```
=== M1 Smoke Tests: Verifying Infrastructure ===
  ✓ Gateway health

=== Infrastructure OK — running tests ===

 PASS  m1/smoke.test.ts
  M1 Smoke Tests
    WebSocket echo through NATS
      ✓ sends a message and receives echo response
      ✓ multiple messages get individual responses
    Request tracing
      ✓ response contains timestamps array with gateway and echo-responder entries
      ✓ pipeline latency is under 500ms for echo
    Tenant isolation
      ✓ two tenants get independent echo responses
      ✓ unknown tenant is rejected
    NATS subject hierarchy
      ✓ messages are published to tenant-scoped subjects
    JetStream VOXLINE_EVENTS stream
      ✓ stream exists and accepts test publish
    MongoDB tenant data
      ✓ all three seed tenants exist
      ✓ tenant config has required fields
      ✓ compound indexes exist on conversations collection
    Redis connectivity
      ✓ can set and get a key
    Ollama accessibility
      ✓ Ollama API responds with model list

Tests:       13 passed, 13 total
```

## Known Risks

| Risk | Mitigation |
|---|---|
| WebSocket test client timing | `waitForMessage` has a 10s default timeout. Echo responses should arrive in <100ms. If timeouts occur, check Gateway and echo-responder logs |
| NATS subscription race condition | The NATS subject test subscribes before sending. If the subscribe is slow, the message may arrive before the subscription is active. The test handles this by starting the subscription first |
| NodePort service not reachable from host | Verify kind extraPortMappings match NodePort values. Run `make cluster-status` and check all pods are Running |

## Dependencies

- Completed: All previous M1 prompts (m1-01 through m1-09)
- All services deployed and running in the `kind` cluster

## M1 Completion

When all 13 smoke tests pass, **M1 is complete**. The foundation is proven:
- Kind cluster with all infrastructure running
- NATS pub/sub with tenant-scoped subjects
- JetStream stream for cold path
- MongoDB with indexed collections and seed data
- Redis accessible
- Ollama with models loaded and benchmarked
- Gateway bridging WebSocket to NATS
- Request tracing propagating through all hops
- Multi-tenant isolation verified
- React UI functional

Proceed to **M2 prompts** to build the Intent Router, LLM Service, and Response Composer — replacing the echo responder with real AI processing.
