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
