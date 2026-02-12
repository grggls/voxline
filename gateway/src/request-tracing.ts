import { randomBytes } from 'crypto';

/**
 * Generate a unique request ID for tracing through all service hops.
 * Format: req_{timestamp}_{random hex}
 */
export function generateRequestId(): string {
  return `req_${Date.now()}_${randomBytes(4).toString('hex')}`;
}
