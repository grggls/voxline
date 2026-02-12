import { connect as natsConnect } from '@nats-io/transport-node';
import type { NatsConnection } from '@nats-io/nats-core';
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
