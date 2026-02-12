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
