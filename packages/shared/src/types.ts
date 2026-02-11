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
