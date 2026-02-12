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
