# M1-07: MongoDB Schema, Indexes, and Tenant Seed Data

## Context

The Gateway service is built (from prompt-m1-06) and MongoDB is running in the cluster (from prompt-m1-03). The Gateway loads tenant config from MongoDB on WebSocket connection, so tenants must be seeded before the Gateway can accept connections.

Multi-tenancy is baked in from M1. Every MongoDB document carries a `tenantId` field. Compound indexes with `tenantId` as the prefix ensure queries are always tenant-scoped.

## What to Build

### 1. MongoDB initialization script

Create `infra/mongodb/init-db.js` — a `mongosh` script that creates collections, indexes, and seed data:

```javascript
// infra/mongodb/init-db.js
// Run with: mongosh mongodb://mongodb.voxline.svc.cluster.local:27017/voxline < init-db.js
// The connection string targets /voxline, so `db` is already the voxline database.

// ===== COLLECTIONS =====

// Tenants collection — configuration per tenant
db.createCollection('tenants');

// Conversations collection — individual messages in conversations
db.createCollection('conversations');

// Sessions collection — active conversation sessions
db.createCollection('sessions');

// Analytics collection — aggregated metrics from the analytics worker
db.createCollection('analytics');

// ===== INDEXES =====

// Tenants: lookup by tenantId (unique)
db.tenants.createIndex({ tenantId: 1 }, { unique: true });

// Conversations: always query by tenant, then session, then time
// This is the primary access pattern for loading conversation context
db.conversations.createIndex({ tenantId: 1, sessionId: 1, timestamp: 1 });

// Conversations: tenant + time for listing recent conversations
db.conversations.createIndex({ tenantId: 1, createdAt: 1 });

// Sessions: lookup by tenant + session
db.sessions.createIndex({ tenantId: 1, sessionId: 1 }, { unique: true });

// Sessions: TTL index — auto-delete inactive sessions after 24h
db.sessions.createIndex({ lastActivity: 1 }, { expireAfterSeconds: 86400 });

// Analytics: tenant + time range queries
db.analytics.createIndex({ tenantId: 1, period: 1, timestamp: 1 });

// ===== SEED TENANTS =====

// Acme Corp — default test tenant
db.tenants.updateOne(
  { tenantId: 'acme' },
  {
    $set: {
      tenantId: 'acme',
      name: 'Acme Corp',
      config: {
        rateLimit: { maxPerMinute: 60 },
        llm: {
          chatModel: 'qwen3:0.6b',
          classifyModel: 'qwen3:0.6b',
          provider: 'ollama',
          systemPrompt: 'You are Acme Corp\'s support agent. You help customers with orders, returns, and general questions. Be concise and helpful.',
        },
        features: { streamingEnabled: true },
      },
    },
  },
  { upsert: true }
);

// Globex Inc — second tenant for isolation testing
db.tenants.updateOne(
  { tenantId: 'globex' },
  {
    $set: {
      tenantId: 'globex',
      name: 'Globex Inc',
      config: {
        rateLimit: { maxPerMinute: 30 },
        llm: {
          chatModel: 'qwen3:0.6b',
          classifyModel: 'qwen3:0.6b',
          provider: 'ollama',
          systemPrompt: 'You are Globex Inc\'s virtual assistant. You help employees with HR questions, IT support, and company policies. Be professional.',
        },
        features: { streamingEnabled: true },
      },
    },
  },
  { upsert: true }
);

// Initech — third tenant for multi-tenant load testing
db.tenants.updateOne(
  { tenantId: 'initech' },
  {
    $set: {
      tenantId: 'initech',
      name: 'Initech',
      config: {
        rateLimit: { maxPerMinute: 10 },
        llm: {
          chatModel: 'qwen3:0.6b',
          classifyModel: 'qwen3:0.6b',
          provider: 'ollama',
          systemPrompt: 'You are Initech\'s customer service bot. Help users with TPS reports and general office queries. Keep responses brief.',
        },
        features: { streamingEnabled: true },
      },
    },
  },
  { upsert: true }
);

// ===== VERIFICATION =====
print('=== Seed complete ===');
print('Tenants: ' + db.tenants.countDocuments());
print('Indexes on conversations: ' + JSON.stringify(db.conversations.getIndexes().map(i => i.name)));
print('Indexes on sessions: ' + JSON.stringify(db.sessions.getIndexes().map(i => i.name)));
```

### 2. Seed execution script

Create `infra/mongodb/seed.sh`:

```bash
#!/bin/bash
set -euo pipefail

echo "Seeding MongoDB..."
kubectl exec -n voxline deploy/mongodb -- \
  mongosh mongodb://localhost:27017/voxline --file /dev/stdin < infra/mongodb/init-db.js

echo "Verifying seed data..."
kubectl exec -n voxline deploy/mongodb -- \
  mongosh mongodb://localhost:27017/voxline --eval "
    print('Tenants:');
    db.tenants.find({}, {tenantId: 1, name: 1, _id: 0}).forEach(t => print('  - ' + t.tenantId + ': ' + t.name));
    print('Collections:');
    db.getCollectionNames().forEach(c => print('  - ' + c));
  "
```

### 3. Makefile target

Add to root `Makefile`:

```makefile
.PHONY: db-seed db-reset

db-seed:
	bash infra/mongodb/seed.sh

db-reset:
	kubectl exec -n voxline deploy/mongodb -- mongosh mongodb://localhost:27017/voxline --eval "db.dropDatabase()"
	$(MAKE) db-seed
```

## Directory Structure

```
infra/
├── mongodb/
│   ├── init-db.js
│   └── seed.sh
└── ...
```

## Document Schemas (Reference)

These schemas document what services will write. The seed script creates the collections and indexes. Actual document writes happen in services.

**conversations collection:**
```javascript
{
  tenantId: "acme",              // Always present — compound index prefix
  sessionId: "sess_abc123",
  requestId: "req_170750_a1b2",  // Correlates to request tracing
  role: "user" | "assistant",
  content: "What's my order status?",
  intent: "general" | "faq" | "escalation",  // Set by intent classifier
  timestamp: ISODate("2026-02-09T14:30:00Z"),
  createdAt: ISODate("2026-02-09T14:30:00Z"),
  metadata: {
    model: "qwen3:0.6b",         // Which model generated (for assistant messages)
    tokensGenerated: 45,
    ttftMs: 312,                  // Time to first token
    totalMs: 1450,                // Total generation time
  }
}
```

**sessions collection:**
```javascript
{
  tenantId: "acme",
  sessionId: "sess_abc123",
  startedAt: ISODate("2026-02-09T14:00:00Z"),
  lastActivity: ISODate("2026-02-09T14:30:00Z"),  // Updated on each message, TTL index key
  messageCount: 5,
  metadata: {}
}
```

**analytics collection:**
```javascript
{
  tenantId: "acme",
  period: "hour",                   // "minute", "hour", "day"
  timestamp: ISODate("2026-02-09T14:00:00Z"),
  metrics: {
    messageCount: 42,
    avgTtftMs: 325,
    p95TtftMs: 480,
    avgTotalMs: 1200,
    intentDistribution: {
      general: 30,
      faq: 10,
      escalation: 2
    }
  }
}
```

## Validation

1. **Seed script runs without errors:**
   ```bash
   make db-seed
   # Should print tenant names and collection list
   ```

2. **All three tenants exist:**
   ```bash
   kubectl exec -n voxline deploy/mongodb -- \
     mongosh mongodb://localhost:27017/voxline --eval "db.tenants.find({},{tenantId:1,_id:0}).toArray()"
   # Should show acme, globex, initech
   ```

3. **Indexes are created:**
   ```bash
   kubectl exec -n voxline deploy/mongodb -- \
     mongosh mongodb://localhost:27017/voxline --eval "db.conversations.getIndexes()"
   # Should show compound indexes with tenantId prefix
   ```

4. **Tenant config loads correctly (test the Gateway's access pattern):**
   ```bash
   kubectl exec -n voxline deploy/mongodb -- \
     mongosh mongodb://localhost:27017/voxline --eval "db.tenants.findOne({tenantId:'acme'})"
   # Should return full tenant config document
   ```

5. **Seed is idempotent:**
   ```bash
   make db-seed
   make db-seed
   # Running twice should not create duplicates (uses updateOne with upsert)
   ```

6. **Gateway now accepts WebSocket connections:**
   ```bash
   npx wscat -c "ws://localhost:8080/ws?tenantId=acme"
   # Should connect successfully (Gateway loads acme config from MongoDB)
   ```

7. **Gateway rejects unknown tenant:**
   ```bash
   npx wscat -c "ws://localhost:8080/ws?tenantId=unknown"
   # Should close with code 4002
   ```

## Dependencies

- Completed: prompt-m1-03 (MongoDB running in cluster)
- Completed: prompt-m1-06 (Gateway service built — needed for validation steps 6-7)

## Next Step

Proceed to **prompt-m1-08** to build the NATS echo responder — a temporary service that subscribes to inbound subjects and echoes messages back to outbound, proving the full WebSocket → NATS → service → NATS → WebSocket pipeline.
