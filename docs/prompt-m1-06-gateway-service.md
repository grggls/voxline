# M1-06: Gateway Service (Express + WebSocket + NATS)

## Context

The monorepo is scaffolded with shared types and utilities (from prompt-m1-05). NATS, MongoDB, Redis, and Ollama are running in the `kind` cluster (from prompts m1-01 through m1-04).

Now build the Gateway — the entry point for all client communication. It bridges WebSocket connections from the React UI to the NATS message bus, creating tenant context and request tracing from the first message.

In M1, the Gateway publishes messages to NATS inbound subjects and subscribes to outbound subjects. There is no Intent Router or LLM Service yet — an echo responder (prompt-m1-08) will close the loop for testing.

## Architecture Role

```
React UI ←→ [WebSocket] ←→ Gateway ←→ [NATS] ←→ downstream services
                              ↕
                          [Redis] (rate limit, cache, session)
                              ↕
                          [MongoDB] (tenant config)
```

The Gateway:
- Accepts WebSocket connections with a `tenantId` parameter
- Loads tenant config from MongoDB on connection
- Generates `sessionId` per connection, `requestId` per message (request tracing)
- Publishes user messages to `voxline.{tenantId}.inbound` via Core NATS
- Includes `voxline-reply-to` header with session-scoped outbound subject
- Subscribes to `voxline.{tenantId}.{sessionId}.outbound` for responses (session-scoped — no fan-out)
- Forwards responses and error frames back to the WebSocket client
- Reports deep health status (NATS, MongoDB, Redis) via event-driven state tracking
- Shuts down gracefully on SIGTERM (stop accepting → close WebSockets → drain NATS → close deps)
- Initializes connection pools at startup (not per-request)

## What to Build

### 1. Gateway service structure

```
gateway/
├── src/
│   ├── index.ts              # Entry point — Express + WS server startup
│   ├── config.ts             # Environment config (NATS URL, Mongo URL, Redis URL, port)
│   ├── connections.ts        # Connection pool initialization (NATS, MongoDB, Redis)
│   ├── websocket.ts          # WebSocket handler — tenant context, message routing
│   ├── nats-bridge.ts        # Publish to NATS inbound, subscribe to NATS outbound
│   └── request-tracing.ts    # requestId generation, timestamp injection
├── package.json
├── tsconfig.json
└── Dockerfile
```

### 2. `gateway/src/config.ts`

```typescript
export const config = {
  port: parseInt(process.env.PORT || '3000', 10),
  nats: {
    url: process.env.NATS_URL || 'nats://nats.voxline.svc.cluster.local:4222',
  },
  mongodb: {
    url: process.env.MONGODB_URL || 'mongodb://mongodb.voxline.svc.cluster.local:27017/voxline',
  },
  redis: {
    url: process.env.REDIS_URL || 'redis://redis-master.voxline.svc.cluster.local:6379',
  },
};
```

### 3. `gateway/src/connections.ts`

Initialize all connections at startup. This is a critical M1 requirement — connection pools MUST be created once at startup, not per-request.

```typescript
import { connect as natsConnect, NatsConnection } from '@nats-io/transport-node';
import { MongoClient, Db } from 'mongodb';
import Redis from 'ioredis';
import { config } from './config';
import { createLogger } from '@voxline/shared';

const logger = createLogger('gateway');

let natsConn: NatsConnection;
let mongoClient: MongoClient;
let mongoDB: Db;
let redisClient: Redis;

// --- Health state: updated via event listeners, never queried on probe path ---
const health = { nats: true, mongodb: true, redis: true };

export async function initConnections(): Promise<void> {
  // NATS — persistent connection with auto-reconnect
  natsConn = await natsConnect({ servers: config.nats.url });
  logger.info('nats.connected');

  // Track NATS connection health via status events
  (async () => {
    for await (const s of natsConn.status()) {
      if (s.type === 'disconnect' || s.type === 'error') {
        health.nats = false;
        logger.warn('nats.unhealthy', undefined, { event: s.type });
      } else if (s.type === 'reconnect') {
        health.nats = true;
        logger.info('nats.reconnected');
      }
    }
  })();

  // MongoDB — connection pool managed by driver
  mongoClient = new MongoClient(config.mongodb.url);
  await mongoClient.connect();
  mongoDB = mongoClient.db();
  logger.info('mongodb.connected');

  // Track MongoDB health via topology events
  mongoClient.on('serverHeartbeatFailed', () => {
    health.mongodb = false;
    logger.warn('mongodb.unhealthy');
  });
  mongoClient.on('serverHeartbeatSucceeded', () => {
    if (!health.mongodb) {
      health.mongodb = true;
      logger.info('mongodb.reconnected');
    }
  });

  // Redis — persistent connection
  redisClient = new Redis(config.redis.url);
  logger.info('redis.connected');

  redisClient.on('error', () => { health.redis = false; });
  redisClient.on('ready', () => { health.redis = true; });
}

/**
 * Returns current health state. No I/O — reads event-driven booleans only.
 * Used by /health endpoint and readiness probe.
 */
export function getHealth(): { nats: boolean; mongodb: boolean; redis: boolean } {
  return { ...health };
}

/**
 * Graceful shutdown: close all connections in reverse order.
 * Called by SIGTERM handler in index.ts.
 */
export async function closeConnections(): Promise<void> {
  await redisClient?.quit();
  await mongoClient?.close();
  await natsConn?.drain();
}

export function getNats(): NatsConnection { return natsConn; }
export function getMongoDB(): Db { return mongoDB; }
export function getRedis(): Redis { return redisClient; }
```

### 4. `gateway/src/request-tracing.ts`

```typescript
import { randomBytes } from 'crypto';

/**
 * Generate a unique request ID for tracing through all service hops.
 * Format: req_{timestamp}_{random hex}
 */
export function generateRequestId(): string {
  return `req_${Date.now()}_${randomBytes(4).toString('hex')}`;
}
```

### 5. `gateway/src/websocket.ts`

WebSocket handler. Each connection requires a `tenantId` query parameter. On each incoming message:
1. Generate `requestId`
2. Build `TenantContext`
3. Create `VoxlineMessage` with initial timestamp
4. Publish to NATS `voxline.{tenantId}.inbound`

```typescript
import { WebSocket, WebSocketServer } from 'ws';
import { IncomingMessage } from 'http';
import { URL } from 'url';
import { TenantContext, VoxlineMessage, TenantConfig, createLogger, injectTenantContext } from '@voxline/shared';
import { getNats, getMongoDB } from './connections';
import { generateRequestId } from './request-tracing';
import { headers as natsHeaders } from '@nats-io/nats-core';

const logger = createLogger('gateway');

export function setupWebSocket(wss: WebSocketServer): void {
  wss.on('connection', async (ws: WebSocket, req: IncomingMessage) => {
    // Extract tenantId from query string: ws://host/?tenantId=acme
    const url = new URL(req.url || '', `http://${req.headers.host}`);
    const tenantId = url.searchParams.get('tenantId');

    if (!tenantId) {
      ws.close(4001, 'Missing tenantId query parameter');
      return;
    }

    // Load tenant config from MongoDB
    const db = getMongoDB();
    const tenantConfig = await db.collection<TenantConfig>('tenants').findOne({ tenantId });

    if (!tenantConfig) {
      ws.close(4002, `Unknown tenant: ${tenantId}`);
      return;
    }

    // Generate session ID for this connection
    const sessionId = `sess_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`;

    logger.info('ws.connected', { tenantId, sessionId } as Partial<TenantContext>, { tenant: tenantConfig.name });

    // Session-scoped outbound subject — only this WebSocket connection receives responses
    const nats = getNats();
    const replyTo = `voxline.${tenantId}.${sessionId}.outbound`;
    const sub = nats.subscribe(replyTo);

    // Forward NATS outbound messages to WebSocket
    (async () => {
      for await (const msg of sub) {
        try {
          const payload = JSON.parse(msg.string()) as VoxlineMessage;

          // Downstream services set type: 'error' for error frames (e.g., Ollama dies mid-stream).
          // The gateway transforms these into WebSocket error frames per the error frame protocol.
          if (payload.type === 'error') {
            ws.send(JSON.stringify({
              type: 'error',
              code: payload.metadata?.code ?? 'UNKNOWN',
              message: payload.metadata?.message ?? payload.content,
              requestId: payload.tenantContext.requestId,
            }));
          } else {
            ws.send(JSON.stringify({
              type: 'message',
              content: payload.content,
              requestId: payload.tenantContext.requestId,
              timestamps: payload.timestamps,
            }));
          }
        } catch (err) {
          logger.error('ws.forward.error', err);
        }
      }
    })();

    // Handle incoming WebSocket messages
    ws.on('message', (data: Buffer) => {
      try {
        const parsed = JSON.parse(data.toString());
        const requestId = generateRequestId();

        const ctx: TenantContext = {
          tenantId,
          sessionId,
          requestId,
          timestamp: Date.now(),
        };

        const message: VoxlineMessage = {
          tenantContext: ctx,
          content: parsed.content || parsed.message || '',
          timestamps: [{ service: 'gateway', event: 'received', ts: Date.now() }],
        };

        // Publish to NATS inbound subject with tenant context + reply-to in headers
        const h = natsHeaders();
        const headerMap = injectTenantContext(ctx, replyTo);
        for (const [key, val] of Object.entries(headerMap)) {
          h.set(key, val);
        }

        nats.publish(
          `voxline.${tenantId}.inbound`,
          JSON.stringify(message),
          { headers: h }
        );

        logger.info('nats.published', ctx, { subject: `voxline.${tenantId}.inbound` });
      } catch (err) {
        logger.error('ws.message.error', err);
        // Send error frame to the client for malformed messages
        ws.send(JSON.stringify({
          type: 'error',
          code: 'INTERNAL_ERROR',
          message: 'Failed to process message',
        }));
      }
    });

    // Cleanup on disconnect
    ws.on('close', () => {
      sub.unsubscribe();
      logger.info('ws.disconnected', { tenantId, sessionId } as Partial<TenantContext>);
    });
  });
}
```

### 6. `gateway/src/index.ts`

```typescript
import express from 'express';
import { createServer } from 'http';
import { WebSocketServer } from 'ws';
import { config } from './config';
import { initConnections, getHealth, closeConnections } from './connections';
import { setupWebSocket } from './websocket';
import { createLogger } from '@voxline/shared';

const logger = createLogger('gateway');

async function main() {
  // Initialize all connection pools at startup
  await initConnections();

  const app = express();
  app.use(express.json());

  // Liveness check — returns 200 if the process is running.
  // Does NOT check dependencies. Prevents Kubernetes from restarting the pod
  // when a dependency (e.g., Redis) is temporarily down.
  app.get('/livez', (_req, res) => {
    res.status(200).json({ status: 'ok' });
  });

  // Readiness check — returns 200 when all deps are healthy, 503 when degraded.
  // No I/O on the probe path — reads event-driven booleans from connections.ts.
  // Used by readiness probe to stop routing traffic when deps are unhealthy.
  app.get('/health', (_req, res) => {
    const deps = getHealth();
    const allHealthy = deps.nats && deps.mongodb && deps.redis;
    res.status(allHealthy ? 200 : 503).json({
      status: allHealthy ? 'ok' : 'degraded',
      service: 'gateway',
      dependencies: deps,
    });
  });

  const server = createServer(app);

  // WebSocket server shares the HTTP server
  const wss = new WebSocketServer({ server, path: '/ws' });
  setupWebSocket(wss);

  server.listen(config.port, () => {
    logger.info('server.started', undefined, { port: config.port });
  });

  // --- Graceful shutdown ---
  const shutdown = async (signal: string) => {
    logger.info('shutdown.start', undefined, { signal });

    // 1. Stop accepting new connections
    server.close();

    // 2. Close all WebSocket connections
    for (const client of wss.clients) {
      client.close(1001, 'Server shutting down');
    }

    // 3. Close infrastructure connections (drain NATS, close Mongo, quit Redis)
    await closeConnections();

    logger.info('shutdown.complete');
    process.exit(0);
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));
}

main().catch((err) => {
  logger.error('startup.failed', err);
  process.exit(1);
});
```

### 7. `gateway/package.json`

```json
{
  "name": "@voxline/gateway",
  "version": "0.1.0",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js",
    "dev": "tsx src/index.ts"
  },
  "dependencies": {
    "express": "^5.2",
    "ws": "^8.16",
    "@nats-io/transport-node": "^3.3",
    "@nats-io/nats-core": "^3.3",
    "mongodb": "^7.1",
    "ioredis": "^5.3",
    "@voxline/shared": "*"
  },
  "devDependencies": {
    "@types/express": "^5",
    "@types/ws": "^8",
    "tsx": "^4.21",
    "typescript": "^5.9"
  }
}
```

### 8. `gateway/tsconfig.json`

```json
{
  "extends": "../tsconfig.base.json",
  "compilerOptions": {
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"]
}
```

### 9. `gateway/Dockerfile`

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY package.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/
COPY gateway/package.json gateway/
RUN npm install
COPY packages/shared/ packages/shared/
COPY gateway/ gateway/
RUN npm run build -w packages/shared && npm run build -w gateway

FROM node:24-alpine
WORKDIR /app
COPY --from=builder /app/package.json ./
COPY --from=builder /app/packages/shared/package.json packages/shared/
COPY --from=builder /app/packages/shared/dist packages/shared/dist
COPY --from=builder /app/gateway/package.json gateway/
COPY --from=builder /app/gateway/dist gateway/dist
COPY --from=builder /app/node_modules node_modules
EXPOSE 3000
CMD ["node", "gateway/dist/index.js"]
```

### 10. Kubernetes manifest

Create `infra/k8s/gateway.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gateway
  namespace: voxline
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gateway
  template:
    metadata:
      labels:
        app: gateway
    spec:
      containers:
        - name: gateway
          image: voxline/gateway:latest
          imagePullPolicy: Never     # Use local image loaded into kind
          ports:
            - containerPort: 3000
          env:
            - name: PORT
              value: "3000"
            - name: NATS_URL
              value: "nats://nats.voxline.svc.cluster.local:4222"
            - name: MONGODB_URL
              value: "mongodb://mongodb.voxline.svc.cluster.local:27017/voxline"
            - name: REDIS_URL
              value: "redis://redis-master.voxline.svc.cluster.local:6379"
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
            initialDelaySeconds: 5
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /livez
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 10
            failureThreshold: 3
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 5"]   # Allow in-flight requests to drain
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 250m
              memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: gateway
  namespace: voxline
spec:
  selector:
    app: gateway
  ports:
    - port: 3000
      targetPort: 3000
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: gateway
  namespace: voxline
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /ws
            pathType: Prefix
            backend:
              service:
                name: gateway
                port:
                  number: 3000
          - path: /api
            pathType: Prefix
            backend:
              service:
                name: gateway
                port:
                  number: 3000
          - path: /health
            pathType: Exact
            backend:
              service:
                name: gateway
                port:
                  number: 3000
          - path: /livez
            pathType: Exact
            backend:
              service:
                name: gateway
                port:
                  number: 3000
```

### 11. Build and load script

Add to `Makefile`:

```makefile
.PHONY: gateway-build gateway-deploy

gateway-build:
	docker build -t voxline/gateway:latest -f gateway/Dockerfile .
	kind load docker-image voxline/gateway:latest --name voxline

gateway-deploy: gateway-build
	kubectl apply -f infra/k8s/gateway.yaml
	kubectl rollout restart deployment/gateway -n voxline
	kubectl rollout status deployment/gateway -n voxline --timeout=60s
```

## Validation

1. **Build succeeds:**
   ```bash
   npm run build -w gateway
   # No TypeScript errors
   ```

2. **Docker build succeeds:**
   ```bash
   make gateway-build
   # Image built and loaded into kind
   ```

3. **Pod is Running:**
   ```bash
   kubectl get pods -n voxline -l app=gateway
   # Should be Running
   ```

4. **Health check responds (readiness):**
   ```bash
   curl http://localhost:8080/health
   # Should return {"status":"ok","service":"gateway","dependencies":{"nats":true,"mongodb":true,"redis":true}}
   ```

5. **Liveness check responds (always 200):**
   ```bash
   curl http://localhost:8080/livez
   # Should return {"status":"ok"} — always 200, does not check dependencies
   ```

6. **WebSocket connects with tenantId:**
   ```bash
   # Requires tenant in MongoDB — see prompt-m1-07
   # After seeding, test with wscat:
   npx wscat -c "ws://localhost:8080/ws?tenantId=acme"
   # Should connect (not close with error)
   ```

7. **WebSocket rejects missing tenantId:**
   ```bash
   npx wscat -c "ws://localhost:8080/ws"
   # Should close with code 4001
   ```

8. **Structured logs contain requestId:**
   ```bash
   kubectl logs -n voxline deployment/gateway | head -5
   # Each line should be valid JSON with service, event, ts fields
   ```

## Known Risks

| Risk | Mitigation |
|---|---|
| WebSocket upgrade through nginx Ingress fails | Nginx Ingress supports WebSocket by default, but verify with `wscat`. If it fails, check Ingress annotations for `proxy-read-timeout` and `proxy-send-timeout` |
| NATS connection fails inside cluster | Verify DNS: `kubectl exec` into gateway pod and `nslookup nats.voxline.svc.cluster.local`. If DNS fails, check NATS service name |
| MongoDB connection string wrong | Service name depends on Helm chart — check with `kubectl get svc -n voxline` |

## Dependencies

- Completed: prompt-m1-01 through m1-05 (cluster, foundations, infra, Ollama, shared packages)
- Note: Full WebSocket testing requires tenant seed data (prompt-m1-07). Build the gateway first, test health endpoint, then seed tenants for full WS testing.

## Next Step

Proceed to **prompt-m1-07** to create MongoDB schema, indexes, and seed tenant data.
