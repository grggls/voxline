import { describe, test, expect, jest, beforeEach, afterEach } from '@jest/globals';
import { createLogger } from '../src';

describe('createLogger', () => {
  let logSpy: ReturnType<typeof jest.spyOn>;
  let errorSpy: ReturnType<typeof jest.spyOn>;
  let warnSpy: ReturnType<typeof jest.spyOn>;

  beforeEach(() => {
    logSpy = jest.spyOn(console, 'log').mockImplementation(() => {});
    errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});
    warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});
  });

  afterEach(() => {
    jest.restoreAllMocks();
  });

  function parsed(spy: ReturnType<typeof jest.spyOn>): Record<string, unknown> {
    return JSON.parse(spy.mock.calls[0][0] as string);
  }

  test('info emits valid JSON with required fields', () => {
    const logger = createLogger('gateway');
    logger.info('connection.open', { requestId: 'req_1', tenantId: 'acme' });

    const out = parsed(logSpy);
    expect(out.level).toBe('info');
    expect(out.service).toBe('gateway');
    expect(out.event).toBe('connection.open');
    expect(out.requestId).toBe('req_1');
    expect(out.tenantId).toBe('acme');
    expect(typeof out.ts).toBe('number');
  });

  test('error extracts message from Error instances', () => {
    const logger = createLogger('llm-service');
    logger.error('ollama.timeout', new Error('connection refused'), { requestId: 'req_2' });

    const out = parsed(errorSpy);
    expect(out.level).toBe('error');
    expect(out.service).toBe('llm-service');
    expect(out.error).toBe('connection refused');
  });

  test('error stringifies non-Error values', () => {
    const logger = createLogger('intent-router');
    logger.error('unexpected', 'raw string error');

    const out = parsed(errorSpy);
    expect(out.error).toBe('raw string error');
  });

  test('warn emits at warn level', () => {
    const logger = createLogger('response-composer');
    logger.warn('cache.miss', { tenantId: 'globex' }, { key: 'prompt_hash_abc' });

    const out = parsed(warnSpy);
    expect(out.level).toBe('warn');
    expect(out.service).toBe('response-composer');
    expect(out.tenantId).toBe('globex');
    expect(out.key).toBe('prompt_hash_abc');
  });

  test('info spreads extra fields into output', () => {
    const logger = createLogger('gateway');
    logger.info('message.received', undefined, { bytes: 256, subject: 'voxline.acme.inbound' });

    const out = parsed(logSpy);
    expect(out.bytes).toBe(256);
    expect(out.subject).toBe('voxline.acme.inbound');
  });

  test('works without optional context', () => {
    const logger = createLogger('analytics');
    logger.info('worker.started');

    const out = parsed(logSpy);
    expect(out.service).toBe('analytics');
    expect(out.requestId).toBeUndefined();
    expect(out.tenantId).toBeUndefined();
  });
});
