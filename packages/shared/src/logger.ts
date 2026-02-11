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
