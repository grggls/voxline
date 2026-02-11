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
