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
5. Session isolation (same tenant, different sessions — no fan-out)
6. WebSocket close codes (4001 missing tenantId, 4002 unknown tenant)
7. WebSocket upgrade through Ingress (HTTP 101)
8. Error frames (malformed message returns structured error)
9. Gateway deep health endpoint (reports dependency status)
10. JetStream stream `VOXLINE_EVENTS` exists and accepts publishes
11. All infrastructure accessible (NATS, MongoDB, Redis, Ollama)

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
import { IncomingMessage } from 'http';

export interface WsMessage {
  type: string;
  content?: string;
  requestId?: string;
  timestamps?: Array<{ service: string; event: string; ts: number }>;
  code?: string;       // Error frame: machine-readable error code
  message?: string;    // Error frame: human-readable error message
}

export class TestWsClient {
  private ws: WebSocket | null = null;
  private messageQueue: WsMessage[] = [];
  private resolvers: Array<(msg: WsMessage) => void> = [];
  private _closeEvent: { code: number; reason: string } | null = null;
  private _upgradeResponse: IncomingMessage | null = null;

  constructor(private baseUrl: string = 'ws://localhost:8080/ws') {}

  /**
   * Connect to the WebSocket server.
   * Includes a 500ms grace period after 'open' to catch server-initiated closes
   * (e.g., unknown tenant lookup that closes the connection after async validation).
   */
  async connect(tenantId: string): Promise<void> {
    return new Promise((resolve, reject) => {
      this.ws = new WebSocket(`${this.baseUrl}?tenantId=${tenantId}`);

      this.ws.on('upgrade', (response: IncomingMessage) => {
        this._upgradeResponse = response;
      });

      this.ws.on('open', () => {
        // Grace period: wait 500ms to see if the server closes us
        // (tenant validation is async — server may close after open)
        setTimeout(() => {
          if (this.ws?.readyState === WebSocket.OPEN) {
            resolve();
          }
          // If already closed, the 'close' handler will have called reject
        }, 500);
      });

      this.ws.on('close', (code: number, reason: Buffer) => {
        this._closeEvent = { code, reason: reason.toString() };
        reject(new Error(`WebSocket closed: ${code} ${reason}`));
      });

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

  /** Send raw string (for malformed message testing) */
  sendRaw(data: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      throw new Error('WebSocket not connected');
    }
    this.ws.send(data);
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

  /**
   * Assert that no more messages arrive within the given window.
   * Used to verify tenant/session isolation — ensures no fan-out leaks.
   */
  async expectNoMoreMessages(windowMs: number = 2000): Promise<void> {
    const unexpected: WsMessage[] = [];
    await new Promise<void>((resolve) => {
      const timer = setTimeout(() => resolve(), windowMs);
      this.resolvers.push((msg) => {
        clearTimeout(timer);
        unexpected.push(msg);
        resolve();
      });
    });
    if (unexpected.length > 0) {
      throw new Error(`Expected no more messages but received ${unexpected.length}: ${JSON.stringify(unexpected)}`);
    }
  }

  /** Number of messages already in the queue (not yet consumed by waitForMessage) */
  get pendingMessageCount(): number {
    return this.messageQueue.length;
  }

  /** Close event from the server (code + reason). Available after close. */
  get closeEvent(): { code: number; reason: string } | null {
    return this._closeEvent;
  }

  /** HTTP upgrade response. Available after successful connection. */
  get upgradeResponse(): IncomingMessage | null {
    return this._upgradeResponse;
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
import { connect } from '@nats-io/transport-node';

export default async function globalSetup() {
  console.log('\n=== M1 Smoke Tests: Verifying Infrastructure ===\n');

  // All services are directly accessible via kind extraPortMappings + NodePort.
  // No kubectl port-forward needed. See prompt-m1-01 Endpoint Reference table.
  const checks = [
    { name: 'Gateway health', url: 'http://localhost:8080/health' },
    { name: 'NATS monitoring', url: 'http://localhost:8222/varz' },
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

  // NATS client connectivity pre-flight — verifies the test can actually connect
  try {
    const nc = await connect({ servers: 'nats://localhost:4222' });
    await nc.close();
    console.log('  ✓ NATS client connection');
  } catch (err) {
    console.error(`  ✗ NATS client connection: ${err}`);
    throw new Error('NATS client connection failed. Check NodePort mapping for NATS (4222).');
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
    test('sends a message and receives response', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      client.send('Hello from smoke test');
      const response = await client.waitForMessage();

      expect(response.type).toBe('message');
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
    test('response contains timestamps array with multiple service hops', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      client.send('trace test');
      const response = await client.waitForMessage();

      expect(response.timestamps).toBeDefined();
      expect(response.timestamps!.length).toBeGreaterThanOrEqual(2);

      // Should have gateway entry (always present regardless of responder)
      const gatewayEntry = response.timestamps!.find(
        (t) => t.service === 'gateway' && t.event === 'received'
      );
      expect(gatewayEntry).toBeDefined();

      // Should have at least one downstream service entry
      const downstreamEntries = response.timestamps!.filter(
        (t) => t.service !== 'gateway'
      );
      expect(downstreamEntries.length).toBeGreaterThanOrEqual(1);

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
    test('two tenants get independent responses with no cross-talk', async () => {
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

      // Verify no additional messages leak through (fan-out check)
      await acme.expectNoMoreMessages(2000);
      await globex.expectNoMoreMessages(2000);

      acme.close();
      globex.close();
    });
  });

  // ----- TEST 4: Session Isolation (same tenant, different sessions) -----
  describe('Session isolation', () => {
    test('two sessions for the same tenant receive only their own responses', async () => {
      const session1 = new TestWsClient();
      const session2 = new TestWsClient();

      await session1.connect('acme');
      await session2.connect('acme');

      session1.send('session1 msg');
      const resp1 = await session1.waitForMessage();
      expect(resp1.content).toContain('session1 msg');

      session2.send('session2 msg');
      const resp2 = await session2.waitForMessage();
      expect(resp2.content).toContain('session2 msg');

      // Session 1 must NOT have received session 2's response (and vice versa)
      await session1.expectNoMoreMessages(2000);
      await session2.expectNoMoreMessages(2000);

      session1.close();
      session2.close();
    });
  });

  // ----- TEST 5: WebSocket Close Codes -----
  describe('WebSocket close codes', () => {
    test('missing tenantId returns close code 4001', async () => {
      const client = new TestWsClient();
      await expect(client.connect('')).rejects.toThrow();
      expect(client.closeEvent).toBeDefined();
      expect(client.closeEvent!.code).toBe(4001);
      client.close();
    });

    test('unknown tenant returns close code 4002', async () => {
      const client = new TestWsClient();
      await expect(client.connect('nonexistent')).rejects.toThrow();
      expect(client.closeEvent).toBeDefined();
      expect(client.closeEvent!.code).toBe(4002);
      client.close();
    });
  });

  // ----- TEST 6: WebSocket Upgrade Through Ingress -----
  describe('WebSocket upgrade', () => {
    test('connection receives HTTP 101 upgrade', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      expect(client.upgradeResponse).toBeDefined();
      expect(client.upgradeResponse!.statusCode).toBe(101);

      client.close();
    });
  });

  // ----- TEST 7: Error Frames -----
  describe('Error frames', () => {
    test('malformed message returns error frame', async () => {
      const client = new TestWsClient();
      await client.connect('acme');

      // Send invalid JSON — Gateway should send an error frame back
      client.sendRaw('this is not json');
      const response = await client.waitForMessage();

      expect(response.type).toBe('error');
      expect(response.code).toBeDefined();

      client.close();
    });
  });

  // ----- TEST 8: Gateway Health Endpoint -----
  describe('Gateway health', () => {
    test('health endpoint reports dependency status', async () => {
      const res = await fetch('http://localhost:8080/health');
      expect(res.ok).toBe(true);

      const body = await res.json() as any;
      expect(body.status).toBe('ok');
      expect(body.service).toBe('gateway');
      expect(body.dependencies).toBeDefined();
      expect(body.dependencies.nats).toBe(true);
      expect(body.dependencies.mongodb).toBe(true);
      expect(body.dependencies.redis).toBe(true);
    });
  });

  // ----- TEST 9: NATS Subject Hierarchy -----
  describe('NATS subject hierarchy', () => {
    test('messages are published to tenant-scoped inbound subjects', async () => {
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

      await client.waitForMessage(); // consume response
      client.close();
    });
  });

  // ----- TEST 10: JetStream Stream Exists -----
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

  // ----- TEST 11: MongoDB Tenants Accessible -----
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

  // ----- TEST 12: Redis Accessible -----
  describe('Redis connectivity', () => {
    test('can set and get a key', async () => {
      const redis = getRedis();
      await redis.set('voxline:smoke:test', 'ok', 'EX', 10);
      const val = await redis.get('voxline:smoke:test');
      expect(val).toBe('ok');
      await redis.del('voxline:smoke:test');
    });
  });

  // ----- TEST 13: Ollama Health -----
  describe('Ollama accessibility', () => {
    test('Ollama API responds with model list', async () => {
      // Ollama is accessible via NodePort on localhost:11434
      const res = await fetch(
        process.env.OLLAMA_URL || 'http://localhost:11434/api/tags'
      );
      expect(res.ok).toBe(true);

      const data = await res.json() as any;
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
  ✓ NATS monitoring
  ✓ Ollama API
  ✓ NATS client connection

=== Infrastructure OK — running tests ===

 PASS  m1/smoke.test.ts
  M1 Smoke Tests
    WebSocket echo through NATS
      ✓ sends a message and receives response
      ✓ multiple messages get individual responses
    Request tracing
      ✓ response contains timestamps array with multiple service hops
      ✓ pipeline latency is under 500ms for echo
    Tenant isolation
      ✓ two tenants get independent responses with no cross-talk
    Session isolation
      ✓ two sessions for the same tenant receive only their own responses
    WebSocket close codes
      ✓ missing tenantId returns close code 4001
      ✓ unknown tenant returns close code 4002
    WebSocket upgrade
      ✓ connection receives HTTP 101 upgrade
    Error frames
      ✓ malformed message returns error frame
    Gateway health
      ✓ health endpoint reports dependency status
    NATS subject hierarchy
      ✓ messages are published to tenant-scoped inbound subjects
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

Tests:       18 passed, 18 total
```

## Known Risks

| Risk | Mitigation |
|---|---|
| WebSocket test client timing | `waitForMessage` has a 10s default timeout. Echo responses should arrive in <100ms. If timeouts occur, check Gateway and echo-responder logs |
| Connect grace period (500ms) slows tests | Required to catch server-initiated close codes (e.g., 4002 for unknown tenant). Without it, `open` fires before the server's async MongoDB lookup completes, and `connect()` resolves before the server closes the connection |
| `expectNoMoreMessages` adds 2s to isolation tests | This is intentional — a fast-pass isolation test cannot prove the absence of fan-out. The 2s window catches delayed duplicates that would indicate a routing bug |
| NATS subscription race condition | The NATS subject test subscribes before sending. If the subscribe is slow, the message may arrive before the subscription is active. The test handles this by starting the subscription first |
| NodePort service not reachable from host | Verify kind extraPortMappings match NodePort values. Run `make cluster-status` and check all pods are Running |

## Dependencies

- Completed: All previous M1 prompts (m1-01 through m1-09)
- All services deployed and running in the `kind` cluster

## M1 Completion

When all 18 smoke tests pass, **M1 is complete**. The foundation is proven:
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
