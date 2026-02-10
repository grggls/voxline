# M1-09: React UI (Chat Interface + Tenant Selector)

## Context

The full pipeline is working end-to-end: Gateway accepts WebSocket connections, publishes to NATS, the echo responder echoes back, and the Gateway forwards the response over WebSocket (from prompts m1-01 through m1-08).

Now build a minimal React frontend that provides:
- A chat interface for sending/receiving messages
- A tenant selector to simulate multi-tenancy
- Real-time display of streamed responses (in M1 these are echo responses; in M2 they'll be LLM-generated)
- Display of request tracing timestamps (for latency validation)

This UI is deliberately minimal — the goal is to test the pipeline, not build a polished product.

## What to Build

### 1. React app structure

Create the UI using Vite + React + TypeScript:

```
ui/
├── src/
│   ├── App.tsx              # Root component — tenant selector + chat
│   ├── components/
│   │   ├── TenantSelector.tsx
│   │   ├── ChatWindow.tsx
│   │   ├── MessageList.tsx
│   │   └── MessageInput.tsx
│   ├── hooks/
│   │   └── useWebSocket.ts  # WebSocket connection management
│   ├── types.ts             # Frontend message types
│   ├── main.tsx
│   └── index.css
├── index.html
├── package.json
├── tsconfig.json
├── vite.config.ts
└── Dockerfile
```

### 2. `ui/src/types.ts`

```typescript
export interface Message {
  id: string;
  role: 'user' | 'assistant' | 'error';
  content: string;
  requestId?: string;
  timestamps?: Array<{ service: string; event: string; ts: number }>;
  receivedAt?: number;
  errorCode?: string;
}

export interface WebSocketResponse {
  type: 'message';
  content: string;
  requestId: string;
  timestamps: Array<{ service: string; event: string; ts: number }>;
}

export interface WebSocketErrorResponse {
  type: 'error';
  code: string;
  message: string;
  requestId: string;
}
```

### 3. `ui/src/hooks/useWebSocket.ts`

Custom hook that manages the WebSocket connection lifecycle:

```typescript
import { useRef, useState, useCallback, useEffect } from 'react';
import { Message, WebSocketResponse, WebSocketErrorResponse } from '../types';

export function useWebSocket(tenantId: string | null) {
  const wsRef = useRef<WebSocket | null>(null);
  const [connected, setConnected] = useState(false);
  const [messages, setMessages] = useState<Message[]>([]);

  // Connect/disconnect when tenantId changes
  useEffect(() => {
    if (!tenantId) {
      wsRef.current?.close();
      setConnected(false);
      setMessages([]);
      return;
    }

    const wsUrl = `ws://${window.location.host}/ws?tenantId=${tenantId}`;
    const ws = new WebSocket(wsUrl);

    ws.onopen = () => setConnected(true);

    ws.onmessage = (event) => {
      try {
        const data: WebSocketResponse | WebSocketErrorResponse = JSON.parse(event.data);
        if (data.type === 'error') {
          const err = data as WebSocketErrorResponse;
          setMessages((prev) => [
            ...prev,
            {
              id: err.requestId || crypto.randomUUID(),
              role: 'error',
              content: err.message || 'Unknown error',
              requestId: err.requestId,
              errorCode: err.code,
              receivedAt: Date.now(),
            },
          ]);
        } else {
          const msg = data as WebSocketResponse;
          setMessages((prev) => [
            ...prev,
            {
              id: msg.requestId || crypto.randomUUID(),
              role: 'assistant',
              content: msg.content,
              requestId: msg.requestId,
              timestamps: msg.timestamps,
              receivedAt: Date.now(),
            },
          ]);
        }
      } catch {
        // Ignore unparseable messages
      }
    };

    ws.onclose = () => setConnected(false);
    ws.onerror = () => setConnected(false);

    wsRef.current = ws;

    return () => {
      ws.close();
    };
  }, [tenantId]);

  const sendMessage = useCallback(
    (content: string) => {
      if (!wsRef.current || wsRef.current.readyState !== WebSocket.OPEN) return;

      const msg: Message = {
        id: crypto.randomUUID(),
        role: 'user',
        content,
      };

      setMessages((prev) => [...prev, msg]);
      wsRef.current.send(JSON.stringify({ content }));
    },
    []
  );

  const clearMessages = useCallback(() => setMessages([]), []);

  return { connected, messages, sendMessage, clearMessages };
}
```

### 4. `ui/src/components/TenantSelector.tsx`

```typescript
interface Props {
  selectedTenant: string | null;
  onSelect: (tenantId: string) => void;
}

const TENANTS = [
  { id: 'acme', name: 'Acme Corp' },
  { id: 'globex', name: 'Globex Inc' },
  { id: 'initech', name: 'Initech' },
];

export function TenantSelector({ selectedTenant, onSelect }: Props) {
  return (
    <div style={{ display: 'flex', gap: 8, padding: 12, borderBottom: '1px solid #ddd' }}>
      <span style={{ fontWeight: 'bold', marginRight: 8 }}>Tenant:</span>
      {TENANTS.map((t) => (
        <button
          key={t.id}
          onClick={() => onSelect(t.id)}
          style={{
            padding: '4px 12px',
            borderRadius: 4,
            border: '1px solid #ccc',
            background: selectedTenant === t.id ? '#3B82F6' : 'white',
            color: selectedTenant === t.id ? 'white' : 'black',
            cursor: 'pointer',
          }}
        >
          {t.name}
        </button>
      ))}
    </div>
  );
}
```

### 5. `ui/src/components/MessageList.tsx`

Display messages with optional request tracing info:

```typescript
import { Message } from '../types';

interface Props {
  messages: Message[];
}

export function MessageList({ messages }: Props) {
  return (
    <div style={{ flex: 1, overflow: 'auto', padding: 16 }}>
      {messages.length === 0 && (
        <div style={{ color: '#999', textAlign: 'center', marginTop: 40 }}>
          Select a tenant and start chatting
        </div>
      )}
      {messages.map((msg) => (
        <div
          key={msg.id}
          style={{
            marginBottom: 12,
            textAlign: msg.role === 'user' ? 'right' : 'left',
          }}
        >
          <div
            style={{
              display: 'inline-block',
              maxWidth: '70%',
              padding: '8px 12px',
              borderRadius: 8,
              background:
                msg.role === 'user'
                  ? '#3B82F6'
                  : msg.role === 'error'
                    ? '#FEE2E2'
                    : '#F1F5F9',
              color:
                msg.role === 'user'
                  ? 'white'
                  : msg.role === 'error'
                    ? '#991B1B'
                    : 'black',
              border: msg.role === 'error' ? '1px solid #FECACA' : 'none',
            }}
          >
            {msg.role === 'error' && (
              <div style={{ fontWeight: 'bold', fontSize: 12, marginBottom: 4 }}>
                Error: {msg.errorCode ?? 'UNKNOWN'}
              </div>
            )}
            {msg.content}
          </div>
          {msg.timestamps && msg.timestamps.length > 0 && (
            <div style={{ fontSize: 11, color: '#999', marginTop: 2 }}>
              {msg.requestId} &middot;{' '}
              {msg.timestamps.length} hops &middot;{' '}
              {msg.timestamps[msg.timestamps.length - 1].ts - msg.timestamps[0].ts}ms pipeline
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
```

### 6. `ui/src/components/MessageInput.tsx`

```typescript
import { useState, FormEvent } from 'react';

interface Props {
  onSend: (content: string) => void;
  disabled: boolean;
}

export function MessageInput({ onSend, disabled }: Props) {
  const [input, setInput] = useState('');

  const handleSubmit = (e: FormEvent) => {
    e.preventDefault();
    if (!input.trim() || disabled) return;
    onSend(input.trim());
    setInput('');
  };

  return (
    <form onSubmit={handleSubmit} style={{ display: 'flex', padding: 12, borderTop: '1px solid #ddd' }}>
      <input
        value={input}
        onChange={(e) => setInput(e.target.value)}
        placeholder={disabled ? 'Select a tenant to start...' : 'Type a message...'}
        disabled={disabled}
        style={{ flex: 1, padding: 8, borderRadius: 4, border: '1px solid #ccc', marginRight: 8 }}
      />
      <button
        type="submit"
        disabled={disabled || !input.trim()}
        style={{
          padding: '8px 16px',
          borderRadius: 4,
          border: 'none',
          background: disabled ? '#ccc' : '#3B82F6',
          color: 'white',
          cursor: disabled ? 'default' : 'pointer',
        }}
      >
        Send
      </button>
    </form>
  );
}
```

### 7. `ui/src/App.tsx`

```typescript
import { useState } from 'react';
import { TenantSelector } from './components/TenantSelector';
import { MessageList } from './components/MessageList';
import { MessageInput } from './components/MessageInput';
import { useWebSocket } from './hooks/useWebSocket';

export default function App() {
  const [tenantId, setTenantId] = useState<string | null>(null);
  const { connected, messages, sendMessage, clearMessages } = useWebSocket(tenantId);

  const handleSelectTenant = (id: string) => {
    clearMessages();
    setTenantId(id);
  };

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column', fontFamily: 'system-ui' }}>
      <div style={{ padding: '8px 16px', background: '#0F172A', color: 'white', display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <span style={{ fontWeight: 'bold' }}>Voxline</span>
        <span style={{ fontSize: 12, color: connected ? '#4ADE80' : '#F87171' }}>
          {connected ? 'Connected' : tenantId ? 'Connecting...' : 'Disconnected'}
        </span>
      </div>
      <TenantSelector selectedTenant={tenantId} onSelect={handleSelectTenant} />
      <MessageList messages={messages} />
      <MessageInput onSend={sendMessage} disabled={!connected} />
    </div>
  );
}
```

### 8. `ui/Dockerfile`

```dockerfile
FROM node:24-alpine AS builder
WORKDIR /app
COPY ui/package.json ui/
RUN cd ui && npm install
COPY ui/ ui/
RUN cd ui && npm run build

FROM nginx:alpine
COPY --from=builder /app/ui/dist /usr/share/nginx/html
COPY ui/nginx.conf /etc/nginx/conf.d/default.conf
EXPOSE 80
```

### 9. `ui/nginx.conf`

```nginx
server {
    listen 80;
    root /usr/share/nginx/html;
    index index.html;

    location / {
        try_files $uri $uri/ /index.html;
    }
}
```

### 10. Kubernetes manifest

Create `infra/k8s/ui.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ui
  namespace: voxline
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ui
  template:
    metadata:
      labels:
        app: ui
    spec:
      containers:
        - name: ui
          image: voxline/ui:latest
          imagePullPolicy: Never
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: ui
  namespace: voxline
spec:
  selector:
    app: ui
  ports:
    - port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ui
  namespace: voxline
spec:
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ui
                port:
                  number: 80
```

**Important:** The UI Ingress and Gateway Ingress share the same host. The Gateway Ingress paths (`/ws`, `/api`, `/health`) are more specific and should take priority. The UI Ingress catches everything else (`/`). Verify that the nginx Ingress controller routes correctly — more specific paths match first.

### 11. Makefile targets

Add to root `Makefile`:

```makefile
.PHONY: ui-build ui-deploy

ui-build:
	docker build -t voxline/ui:latest -f ui/Dockerfile .
	kind load docker-image voxline/ui:latest --name voxline

ui-deploy: ui-build
	kubectl apply -f infra/k8s/ui.yaml
	kubectl rollout restart deployment/ui -n voxline
	kubectl rollout status deployment/ui -n voxline --timeout=60s
```

### 12. Initialize the Vite project

Run these commands to scaffold the UI:

```bash
cd ui
npm create vite@latest . -- --template react-ts
npm install
```

Then replace the generated `App.tsx`, `main.tsx`, and add the components/hooks listed above.

## Validation

1. **Vite dev build succeeds:**
   ```bash
   cd ui && npm run build
   # Should produce dist/ with index.html and bundled JS
   ```

2. **Docker build succeeds:**
   ```bash
   make ui-build
   # Image built and loaded into kind
   ```

3. **UI pod is Running:**
   ```bash
   kubectl get pods -n voxline -l app=ui
   # Should be Running
   ```

4. **UI loads in browser:**
   ```
   Open http://localhost:8080/ in browser
   Should show: Voxline header, tenant selector buttons, empty chat
   Status should show "Disconnected"
   ```

5. **Selecting a tenant connects WebSocket:**
   ```
   Click "Acme Corp" button
   Status should change to "Connected" (green)
   ```

6. **Sending a message gets echo response:**
   ```
   Type "Hello" and press Send
   Should see:
     - Your message (blue, right-aligned): "Hello"
     - Echo response (gray, left-aligned): "[echo] Hello"
     - Tracing info below the response: requestId, hop count, pipeline latency
   ```

7. **Switching tenants clears history and reconnects:**
   ```
   Click "Globex Inc" after sending messages to Acme
   Chat should clear, new WebSocket connection established
   Send message — should get echo response scoped to Globex
   ```

8. **Multiple tenants in separate browser tabs work independently:**
   ```
   Tab 1: Acme — send "acme msg"
   Tab 2: Globex — send "globex msg"
   Verify no cross-talk between tabs
   ```

9. **Error frames display with red styling:**
   ```
   If a downstream service publishes a type: 'error' frame to the session outbound subject,
   the UI should render it left-aligned with:
     - Red background (#FEE2E2), dark red text (#991B1B)
     - Bold "Error: CODE" header above the message content
     - No timestamp/hop info (error frames don't carry timestamps)
   This is tested automatically by the m1-10 smoke test for error frame forwarding.
   ```

## Known Risks

| Risk | Mitigation |
|---|---|
| Ingress path conflict between UI (`/`) and Gateway (`/ws`, `/api`) | Nginx Ingress routes by most specific path first. `/ws` and `/api` should match Gateway before the catch-all `/` matches UI. Test both routes after deploying both Ingress resources |
| WebSocket URL must include port for non-standard ports | The `useWebSocket` hook uses `window.location.host` (not `hostname`) to construct the WS URL. `.host` includes the port (e.g. `localhost:8080`), so the WebSocket connects to the correct address |
| Vite dev server proxy needed for local development outside k8s | For local dev, add `vite.config.ts` proxy to forward `/ws` to the Gateway. For k8s deployment this isn't needed — Ingress handles routing |

## Dependencies

- Completed: prompt-m1-01 through m1-08 (cluster, foundations, infra, Ollama, shared packages, Gateway, MongoDB seeded, echo responder)

## Next Step

Proceed to **prompt-m1-10** to write the M1 smoke test suite that validates the full pipeline end-to-end.
