# M1-05: Project Scaffolding, Shared Libraries, and Unit Tests

## Context

The `kind` cluster is running with NATS (Core + JetStream), MongoDB, Redis, and Ollama (from prompts m1-01 through m1-04). Models are pulled and benchmarked.

Now scaffold the TypeScript monorepo, create the shared libraries that every service depends on, and write the unit tests for critical abstractions. This must be done before any service is built because every service imports these shared types and utilities.

## What to Build

### 1. Monorepo structure

Initialize a TypeScript monorepo using npm workspaces. All TypeScript services share a common `packages/shared` library.

```
packages/
└── shared/                    # Shared TypeScript library
    ├── src/
    │   ├── types.ts           # TenantContext, message types
    │   ├── nats-headers.ts    # Inject/extract TenantContext to/from NATS headers
    │   ├── logger.ts          # Structured JSON logging with requestId
    │   └── index.ts           # Re-exports
    ├── tests/
    │   └── tenant-context.test.ts
    ├── package.json
    └── tsconfig.json
gateway/                       # (created in prompt-m1-06)
intent-router/                 # (created in M2)
response-composer/             # (created in M2)
llm-service/                   # Python — separate from TS monorepo
analytics/                     # Python — separate from TS monorepo
ui/                            # React — created in prompt-m1-09
package.json                   # Root workspace config
tsconfig.base.json             # Shared TypeScript config
```

### 2. Root `package.json`

```json
{
  "name": "voxline",
  "private": true,
  "workspaces": [
    "packages/*",
    "gateway",
    "echo-responder",
    "intent-router",
    "response-composer",
    "tests"
  ],
  "scripts": {
    "build": "npm run build --workspaces --if-present",
    "test": "npm run test --workspaces --if-present",
    "test:m1": "npm test -w tests -- --testPathPattern=m1/",
    "lint": "eslint ."
  },
  "engines": {
    "node": ">=18"
  },
  "devDependencies": {
    "typescript": "^5.9",
    "eslint": "^9",
    "typescript-eslint": "^8"
  }
}
```

### 3. Root `tsconfig.base.json`

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "commonjs",
    "lib": ["ES2022"],
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true,
    "resolveJsonModule": true,
    "declaration": true,
    "declarationMap": true,
    "sourceMap": true,
    "outDir": "./dist"
  }
}
```

### 4. `packages/shared/src/types.ts`

Core types used by every service:

```typescript
/**
 * TenantContext is created at the Gateway when a WebSocket connection is established
 * and propagated through the entire pipeline via NATS headers.
 * No service ever operates without a tenant context.
 */
export interface TenantContext {
  tenantId: string;
  sessionId: string;
  requestId: string;   // Correlation ID for request tracing — see Request Tracing
  timestamp: number;
}

/**
 * Structured log entry appended by each service at each hop.
 * Carried in the NATS message so the final message contains the full trace.
 */
export interface TimestampEntry {
  service: string;
  event: string;
  ts: number;
}

/**
 * Standard NATS message payload for the Voxline pipeline.
 * type defaults to 'message'. Downstream services set type: 'error' for error frames.
 */
export interface VoxlineMessage {
  tenantContext: TenantContext;
  type?: 'message' | 'error';
  content: string;
  timestamps: TimestampEntry[];
  metadata?: Record<string, unknown>;
}

/**
 * Tenant configuration stored in MongoDB tenants collection.
 */
export interface TenantConfig {
  tenantId: string;
  name: string;
  config: {
    rateLimit: { maxPerMinute: number };
    llm: {
      chatModel: string;
      classifyModel: string;
      provider: string;
      systemPrompt: string;
    };
    features: { streamingEnabled: boolean };
  };
}
```

### 5. `packages/shared/src/nats-headers.ts`

Inject and extract TenantContext to/from NATS message headers:

```typescript
import { TenantContext } from './types';

// NATS header keys — prefixed with voxline- to avoid collisions
const HEADER_TENANT_ID = 'voxline-tenant-id';
const HEADER_SESSION_ID = 'voxline-session-id';
const HEADER_REQUEST_ID = 'voxline-request-id';
const HEADER_TIMESTAMP = 'voxline-timestamp';
const HEADER_REPLY_TO = 'voxline-reply-to';

/**
 * Serialize TenantContext into a plain object suitable for NATS headers.
 * NATS headers are string key-value pairs.
 * Optional replyTo sets the session-scoped outbound subject for downstream services.
 */
export function injectTenantContext(ctx: TenantContext, replyTo?: string): Record<string, string> {
  const headers: Record<string, string> = {
    [HEADER_TENANT_ID]: ctx.tenantId,
    [HEADER_SESSION_ID]: ctx.sessionId,
    [HEADER_REQUEST_ID]: ctx.requestId,
    [HEADER_TIMESTAMP]: ctx.timestamp.toString(),
  };
  if (replyTo) {
    headers[HEADER_REPLY_TO] = replyTo;
  }
  return headers;
}

/**
 * Deserialize TenantContext from NATS headers.
 * Throws if required headers are missing — every NATS message MUST have tenant context.
 */
export function extractTenantContext(headers: Record<string, string | string[] | undefined>): TenantContext {
  const get = (key: string): string => {
    const val = headers[key];
    const str = Array.isArray(val) ? val[0] : val;
    if (!str) throw new Error(`Missing ${key} in NATS headers`);
    return str;
  };

  return {
    tenantId: get(HEADER_TENANT_ID),
    sessionId: get(HEADER_SESSION_ID),
    requestId: get(HEADER_REQUEST_ID),
    timestamp: parseInt(get(HEADER_TIMESTAMP), 10),
  };
}

/**
 * Extract the reply-to subject from NATS headers.
 * Downstream services use this to know where to publish responses.
 * Throws if the header is missing — every inbound message MUST have a reply-to.
 */
export function extractReplyTo(headers: Record<string, string | string[] | undefined>): string {
  const val = headers[HEADER_REPLY_TO];
  const str = Array.isArray(val) ? val[0] : val;
  if (!str) throw new Error(`Missing ${HEADER_REPLY_TO} in NATS headers`);
  return str;
}
```

### 6. `packages/shared/src/logger.ts`

Structured JSON logger that every service uses. Always includes `requestId`, `service`, `event`, `ts`.

```typescript
import { TenantContext } from './types';

/**
 * Structured JSON logger for Voxline services.
 * Every log line is a JSON object with requestId for correlation.
 * Designed for machine parsing — structured logs feed the latency analysis pipeline.
 */
export function createLogger(serviceName: string) {
  return {
    info(event: string, ctx?: Partial<TenantContext>, extra?: Record<string, unknown>) {
      console.log(JSON.stringify({
        level: 'info',
        service: serviceName,
        event,
        requestId: ctx?.requestId,
        tenantId: ctx?.tenantId,
        ts: Date.now(),
        ...extra,
      }));
    },
    error(event: string, error: unknown, ctx?: Partial<TenantContext>) {
      console.error(JSON.stringify({
        level: 'error',
        service: serviceName,
        event,
        requestId: ctx?.requestId,
        tenantId: ctx?.tenantId,
        ts: Date.now(),
        error: error instanceof Error ? error.message : String(error),
      }));
    },
    warn(event: string, ctx?: Partial<TenantContext>, extra?: Record<string, unknown>) {
      console.warn(JSON.stringify({
        level: 'warn',
        service: serviceName,
        event,
        requestId: ctx?.requestId,
        tenantId: ctx?.tenantId,
        ts: Date.now(),
        ...extra,
      }));
    },
  };
}
```

### 7. `packages/shared/src/index.ts`

```typescript
export * from './types';
export * from './nats-headers';
export * from './logger';
```

### 8. `packages/shared/tests/tenant-context.test.ts`

**This is one of two M1 unit tests.** It validates that TenantContext round-trips correctly through NATS headers. If this is wrong, every integration test fails with confusing cross-tenant pollution.

```typescript
import { describe, test, expect } from '@jest/globals';
import { TenantContext, injectTenantContext, extractTenantContext, extractReplyTo } from '../src';

describe('TenantContext NATS header round-trip', () => {
  test('tenant context survives injection and extraction', () => {
    const ctx: TenantContext = {
      tenantId: 'acme',
      sessionId: 'sess_1',
      requestId: 'req_abc123',
      timestamp: 1707500000000,
    };

    const headers = injectTenantContext(ctx);
    const extracted = extractTenantContext(headers);

    expect(extracted).toEqual(ctx);
  });

  test('handles array header values (NATS can return arrays)', () => {
    const headers = {
      'voxline-tenant-id': ['acme'],
      'voxline-session-id': ['sess_1'],
      'voxline-request-id': ['req_abc123'],
      'voxline-timestamp': ['1707500000000'],
    };

    const extracted = extractTenantContext(headers);
    expect(extracted.tenantId).toBe('acme');
  });

  test('throws on missing tenantId', () => {
    expect(() => extractTenantContext({})).toThrow('Missing voxline-tenant-id');
  });

  test('throws on missing requestId', () => {
    const headers = {
      'voxline-tenant-id': 'acme',
      'voxline-session-id': 'sess_1',
      'voxline-timestamp': '1707500000000',
    };
    expect(() => extractTenantContext(headers)).toThrow('Missing voxline-request-id');
  });

  test('all header keys are prefixed with voxline-', () => {
    const ctx: TenantContext = {
      tenantId: 'test',
      sessionId: 'sess',
      requestId: 'req',
      timestamp: 0,
    };
    const headers = injectTenantContext(ctx);
    for (const key of Object.keys(headers)) {
      expect(key).toMatch(/^voxline-/);
    }
  });

  test('reply-to header round-trips through inject and extract', () => {
    const ctx: TenantContext = {
      tenantId: 'acme',
      sessionId: 'sess_1',
      requestId: 'req_abc123',
      timestamp: 1707500000000,
    };

    const headers = injectTenantContext(ctx, 'voxline.acme.sess_1.outbound');
    expect(headers['voxline-reply-to']).toBe('voxline.acme.sess_1.outbound');

    const replyTo = extractReplyTo(headers);
    expect(replyTo).toBe('voxline.acme.sess_1.outbound');
  });

  test('extractReplyTo throws on missing reply-to header', () => {
    expect(() => extractReplyTo({})).toThrow('Missing voxline-reply-to');
  });
});
```

### 9. `packages/shared/package.json`

```json
{
  "name": "@voxline/shared",
  "version": "0.1.0",
  "main": "dist/index.js",
  "types": "dist/index.d.ts",
  "scripts": {
    "build": "tsc",
    "test": "jest"
  },
  "devDependencies": {
    "jest": "^30",
    "ts-jest": "^30",
    "@jest/globals": "^30",
    "@types/jest": "^30"
  }
}
```

### 10. `packages/shared/tsconfig.json`

```json
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "outDir": "./dist",
    "rootDir": "./src"
  },
  "include": ["src/**/*"]
}
```

### 11. ESLint flat config

Create `eslint.config.mjs` in the project root. ESLint 9 requires flat config — `.eslintrc` is no longer supported. The `.mjs` extension is required because the root `package.json` does not have `"type": "module"`, and this config uses ESM `import` syntax:

```javascript
import eslint from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.recommended,
  {
    ignores: ['**/dist/', '**/node_modules/', 'ui/'],
  },
);
```

### 12. Jest configuration for shared package

Create `packages/shared/jest.config.js`:

```javascript
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'node',
  testMatch: ['**/tests/**/*.test.ts'],
};
```

## Validation

1. **Install dependencies:**
   ```bash
   npm install
   # Should complete without errors, workspaces linked
   ```

2. **Build shared package:**
   ```bash
   npm run build -w packages/shared
   # Should compile TypeScript to dist/ without errors
   ```

3. **Unit tests pass:**
   ```bash
   npm test -w packages/shared
   # All 7 tests should pass (5 original + 2 reply-to tests)
   ```

4. **Verify workspace linking:**
   ```bash
   # From any workspace, @voxline/shared should resolve
   node -e "console.log(require.resolve('@voxline/shared'))"
   ```

5. **Verify NATS v3 imports resolve correctly:**
   ```bash
   # The NATS v3 client is split across multiple packages:
   #   @nats-io/transport-node — connect(), NatsConnection
   #   @nats-io/nats-core — headers(), MsgHdrs (re-exported by transport-node but import directly for clarity)
   #   @nats-io/jetstream — jetstream(), jetstreamManager()
   # Verify the import that services will use:
   node -e "const { connect } = require('@nats-io/transport-node'); console.log('transport-node OK')"
   ```

## Dependencies

- Completed: prompt-m1-01 through m1-04 (cluster, foundations, infrastructure, and Ollama running — not strictly needed for this step, but establishes the project context)

## Next Step

After the shared package is built and tests pass, proceed to **prompt-m1-06** to build the Gateway service (Express + WebSocket + NATS + Redis + MongoDB connections).
