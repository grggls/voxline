# M1-08: NATS Echo Responder (Temporary Pipeline Proof)

## Context

The Gateway is deployed, MongoDB is seeded with tenants, and WebSocket connections work (from prompts m1-01 through m1-07). But the NATS pipeline has no downstream service yet — messages published to `voxline.{tenantId}.inbound` go nowhere.

Build a temporary **echo responder** that subscribes to inbound subjects and publishes echoed messages back to outbound subjects. This proves the full pipeline: **WebSocket → Gateway → NATS → service → NATS → Gateway → WebSocket**.

This service is replaced by the Intent Router and LLM Service in M2. Its purpose is purely to validate the M1 infrastructure before building real services.

## Architecture Role

```
UI → WebSocket → Gateway → NATS (inbound) → Echo Responder → NATS (outbound) → Gateway → WebSocket → UI
```

The echo responder:
- Subscribes to `voxline.*.inbound` (wildcard — all tenants)
- Extracts `TenantContext` and `voxline-reply-to` header from NATS headers
- Appends its own timestamp to the `timestamps` array (request tracing)
- Publishes an echo response to the session-scoped subject from `voxline-reply-to` (not a constructed subject)
- Exposes a health HTTP server on port 3001 (for k8s readiness/liveness probes)
- Shuts down gracefully on SIGTERM (unsubscribe, drain NATS)
- Logs structured JSON at each step

## What to Build

### 1. Echo responder service

Create `echo-responder/` (temporary — this directory is deleted after M2):

```
echo-responder/
├── src/
│   ├── index.ts
│   └── config.ts
├── package.json
├── tsconfig.json
└── Dockerfile
```

### 2. `echo-responder/src/config.ts`

```typescript
export const config = {
  nats: {
    url: process.env.NATS_URL || 'nats://nats.voxline.svc.cluster.local:4222',
  },
};
```

### 3. `echo-responder/src/index.ts`

```typescript
import { connect } from '@nats-io/transport-node';
import { headers as natsHeaders } from '@nats-io/nats-core';
import { createServer } from 'http';
import { VoxlineMessage, extractTenantContext, extractReplyTo, injectTenantContext, createLogger } from '@voxline/shared';
import { config } from './config';

const logger = createLogger('echo-responder');

async function main() {
  const nc = await connect({ servers: config.nats.url });
  logger.info('nats.connected');

  // Subscribe to ALL tenants' inbound messages
  const sub = nc.subscribe('voxline.*.inbound');
  logger.info('subscribed', undefined, { subject: 'voxline.*.inbound' });

  // --- Minimal health HTTP server (for readiness/liveness probes) ---
  const healthServer = createServer((_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', service: 'echo-responder' }));
  });
  healthServer.listen(3001, () => {
    logger.info('health.listening', undefined, { port: 3001 });
  });

  // --- Graceful shutdown ---
  const shutdown = async (signal: string) => {
    logger.info('shutdown.start', undefined, { signal });
    sub.unsubscribe();
    await nc.drain();
    healthServer.close();
    logger.info('shutdown.complete');
    process.exit(0);
  };
  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  for await (const msg of sub) {
    try {
      // Extract tenant context and reply-to subject from headers
      const headerMap: Record<string, string> = {};
      if (msg.headers) {
        for (const [key, values] of msg.headers) {
          headerMap[key] = values[0];
        }
      }
      const ctx = extractTenantContext(headerMap);
      const replyTo = extractReplyTo(headerMap);

      // Parse the message payload
      const payload = JSON.parse(msg.string()) as VoxlineMessage;

      logger.info('received', ctx, { content: payload.content.slice(0, 50) });

      // Append echo-responder timestamp (request tracing)
      payload.timestamps.push({
        service: 'echo-responder',
        event: 'received',
        ts: Date.now(),
      });

      // Build echo response
      const response: VoxlineMessage = {
        tenantContext: ctx,
        content: `[echo] ${payload.content}`,
        timestamps: [
          ...payload.timestamps,
          { service: 'echo-responder', event: 'responded', ts: Date.now() },
        ],
      };

      // Publish to the session-scoped outbound subject from the reply-to header
      const h = natsHeaders();
      const ctxHeaders = injectTenantContext(ctx);
      for (const [key, val] of Object.entries(ctxHeaders)) {
        h.set(key, val);
      }

      nc.publish(replyTo, JSON.stringify(response), { headers: h });

      logger.info('published', ctx, { subject: replyTo });
    } catch (err) {
      logger.error('message.error', err);
    }
  }
}

main().catch((err) => {
  logger.error('startup.failed', err);
  process.exit(1);
});
```

### 4. `echo-responder/package.json`

```json
{
  "name": "@voxline/echo-responder",
  "version": "0.1.0",
  "scripts": {
    "build": "tsc",
    "start": "node dist/index.js",
    "dev": "tsx src/index.ts"
  },
  "dependencies": {
    "@nats-io/transport-node": "^3.3",
    "@nats-io/nats-core": "^3.3",
    "@voxline/shared": "*"
  },
  "devDependencies": {
    "tsx": "^4.21",
    "typescript": "^5.9"
  }
}
```

### 5. `echo-responder/tsconfig.json`

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

### 6. `echo-responder/Dockerfile`

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY package.json tsconfig.base.json ./
COPY packages/shared/package.json packages/shared/
COPY echo-responder/package.json echo-responder/
RUN npm install
COPY packages/shared/ packages/shared/
COPY echo-responder/ echo-responder/
RUN npm run build -w packages/shared && npm run build -w echo-responder

FROM node:24-alpine
WORKDIR /app
COPY --from=builder /app/package.json ./
COPY --from=builder /app/packages/shared/package.json packages/shared/
COPY --from=builder /app/packages/shared/dist packages/shared/dist
COPY --from=builder /app/echo-responder/package.json echo-responder/
COPY --from=builder /app/echo-responder/dist echo-responder/dist
COPY --from=builder /app/node_modules node_modules
CMD ["node", "echo-responder/dist/index.js"]
```

### 7. Kubernetes manifest

Create `infra/k8s/echo-responder.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-responder
  namespace: voxline
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo-responder
  template:
    metadata:
      labels:
        app: echo-responder
    spec:
      containers:
        - name: echo-responder
          image: voxline/echo-responder:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 3001
          env:
            - name: NATS_URL
              value: "nats://nats.voxline.svc.cluster.local:4222"
          readinessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /
              port: 3001
            initialDelaySeconds: 5
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
```

### 8. Add to root `package.json` workspaces

Update root `package.json` to include `echo-responder` in the workspaces array:

```json
"workspaces": [
  "packages/*",
  "gateway",
  "echo-responder",
  "intent-router",
  "response-composer"
]
```

### 9. Makefile targets

Add to root `Makefile`:

```makefile
.PHONY: echo-build echo-deploy echo-teardown

echo-build:
	docker build -t voxline/echo-responder:latest -f echo-responder/Dockerfile .
	kind load docker-image voxline/echo-responder:latest --name voxline

echo-deploy: echo-build
	kubectl apply -f infra/k8s/echo-responder.yaml
	kubectl rollout restart deployment/echo-responder -n voxline
	kubectl rollout status deployment/echo-responder -n voxline --timeout=60s

echo-teardown:
	kubectl delete -f infra/k8s/echo-responder.yaml --ignore-not-found
```

## Validation

1. **Build and deploy succeeds:**
   ```bash
   make echo-deploy
   kubectl get pods -n voxline -l app=echo-responder
   # Should be Running
   ```

2. **Echo responder subscribes to NATS:**
   ```bash
   kubectl logs -n voxline deployment/echo-responder | head -3
   # Should show nats.connected and subscribed events
   ```

3. **Full round-trip works via wscat:**
   ```bash
   # Terminal 1: connect as acme tenant
   npx wscat -c "ws://localhost:8080/ws?tenantId=acme"
   # Type: {"content": "Hello from acme"}
   # Should receive: {"type":"message","content":"[echo] Hello from acme","requestId":"req_...","timestamps":[...]}
   ```

4. **Tenant isolation — two tenants get their own echoes:**
   ```bash
   # Terminal 1:
   npx wscat -c "ws://localhost:8080/ws?tenantId=acme"
   # Send: {"content": "acme message"}
   # Receive: [echo] acme message

   # Terminal 2:
   npx wscat -c "ws://localhost:8080/ws?tenantId=globex"
   # Send: {"content": "globex message"}
   # Receive: [echo] globex message
   # Verify: acme connection does NOT receive globex's echo
   ```

5. **Request tracing — timestamps array is populated:**
   ```bash
   # After receiving a response in wscat, verify the timestamps array:
   # Should contain entries from:
   #   - gateway (received)
   #   - echo-responder (received)
   #   - echo-responder (responded)
   ```

6. **Structured logs show request flow:**
   ```bash
   # Gateway logs:
   kubectl logs -n voxline deployment/gateway --tail=10
   # Should show ws.message and nats.published events with requestId

   # Echo responder logs:
   kubectl logs -n voxline deployment/echo-responder --tail=10
   # Should show received and published events with same requestId
   ```

7. **NATS subjects are tenant-scoped:**
   ```bash
   # Monitor NATS subjects from inside the cluster:
   kubectl exec -n voxline deploy/nats -c nats -- nats sub "voxline.>" --count 5 &
   # Send messages from wscat for acme and globex
   # Verify subjects: voxline.acme.inbound, voxline.acme.outbound, voxline.globex.inbound, etc.
   ```

## Known Risks

| Risk | Mitigation |
|---|---|
| NATS header iteration API changed in v3 | Using `@nats-io/transport-node` v3. The `msg.headers` API returns an iterable of `[key, string[]]` pairs. `StringCodec` is removed — use `msg.string()` to decode and pass strings directly to `publish()` |
| Wildcard subscription `voxline.*.inbound` doesn't match | NATS uses `*` for single token wildcard. Verify with `nats sub "voxline.*.inbound"` from the NATS pod |

## Lifecycle

This service is **temporary**. It exists only for M1 to validate the pipeline. In M2, the Intent Router and LLM Service replace it. After M2:
- Run `make echo-teardown`
- Delete the `echo-responder/` directory
- Remove from root `package.json` workspaces

## Dependencies

- Completed: prompt-m1-01 through m1-07 (cluster, foundations, infra, Ollama, shared packages, Gateway, MongoDB seeded)

## Next Step

Proceed to **prompt-m1-09** to build the React UI with chat interface, tenant selector, and WebSocket connection.
