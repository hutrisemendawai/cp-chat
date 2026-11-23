import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest';

import { auth, createHarness, registerUser, TEST_CONFIG, truncateAll, type TestHarness } from './helpers.js';
import { createContext } from '../src/http/context.js';
import { buildServer } from '../src/http/server.js';
import { createLogger } from '../src/lib/logger.js';
import {
  LOG_CHANNEL,
  LOG_KEY,
  LogStore,
  pinoLineToInput,
  redactValue,
  type LogEntry,
} from '../src/lib/log-store.js';

let harness: TestHarness;
let store: LogStore;

beforeAll(async () => {
  harness = await createHarness();
});

afterAll(async () => {
  await harness.close();
});

beforeEach(async () => {
  await truncateAll(harness.db);
  await harness.redis.del(LOG_KEY);
  store = new LogStore(harness.redis, { retentionSeconds: 3600, maxEntries: 5000 });
});

describe('LogStore retention', () => {
  it('prunes entries older than the retention window with ZREMRANGEBYSCORE', async () => {
    const now = Date.now();
    const stale = now - 2 * 60 * 60 * 1000;
    await store.append({ service: 'rest', level: 'info', message: 'stale', ts: stale });
    await store.append({ service: 'rest', level: 'info', message: 'fresh', ts: now });

    await store.prune();

    const remaining = await harness.redis.zrange(LOG_KEY, 0, -1);
    const messages = remaining.map((raw) => (JSON.parse(raw) as LogEntry).message);
    expect(messages).toEqual(['fresh']);
  });

  it('drops oldest entries beyond LOG_MAX_ENTRIES with ZREMRANGEBYRANK', async () => {
    const capped = new LogStore(harness.redis, { retentionSeconds: 3600, maxEntries: 3 });
    const base = Date.now();
    for (let index = 0; index < 6; index += 1) {
      await capped.append({
        service: 'rest',
        level: 'info',
        message: `entry-${index}`,
        ts: base + index,
      });
    }

    await capped.prune();

    const remaining = await harness.redis.zrange(LOG_KEY, 0, -1);
    const messages = remaining.map((raw) => (JSON.parse(raw) as LogEntry).message);
    expect(messages).toEqual(['entry-3', 'entry-4', 'entry-5']);
  });

  it('sets a safety TTL of retention + 300 seconds', async () => {
    await store.append({ service: 'gateway', level: 'info', message: 'ttl check' });

    const ttl = await harness.redis.ttl(LOG_KEY);
    expect(ttl).toBeGreaterThan(3600);
    expect(ttl).toBeLessThanOrEqual(3600 + 300);
  });

  it('serves entries newest-first query results oldest-first within the 1h window', async () => {
    const base = Date.now();
    await store.append({ service: 'rest', level: 'info', message: 'one', ts: base - 1000 });
    await store.append({ service: 'gateway', level: 'warn', message: 'two', ts: base - 500 });
    await store.append({ service: 'mobile', level: 'error', message: 'three', ts: base });

    const result = await store.query({});
    expect(result.logs.map((entry) => entry.message)).toEqual(['one', 'two', 'three']);
  });
});

describe('LogStore filtering', () => {
  beforeEach(async () => {
    const base = Date.now();
    await store.append({ service: 'rest', level: 'info', message: 'User signed in', ts: base - 3000 });
    await store.append({ service: 'gateway', level: 'warn', message: 'Slow socket', ts: base - 2000 });
    await store.append({ service: 'mobile', level: 'error', message: 'Upload failed', ts: base - 1000 });
    await store.append({ service: 'rest', level: 'debug', message: 'Cache warmed', ts: base });
  });

  it('filters by service', async () => {
    const result = await store.query({ service: 'rest' });
    expect(result.logs.map((entry) => entry.message)).toEqual(['User signed in', 'Cache warmed']);
  });

  it('filters by minimum level', async () => {
    const result = await store.query({ level: 'warn' });
    expect(result.logs.map((entry) => entry.message)).toEqual(['Slow socket', 'Upload failed']);
  });

  it('filters by case-insensitive substring', async () => {
    const result = await store.query({ q: 'UPLOAD' });
    expect(result.logs.map((entry) => entry.message)).toEqual(['Upload failed']);
  });

  it('respects since and limit', async () => {
    const base = Date.now();
    const since = await store.query({ since: base - 1500 });
    expect(since.logs.map((entry) => entry.message)).toEqual(['Upload failed', 'Cache warmed']);

    const limited = await store.query({ limit: 1 });
    expect(limited.logs.map((entry) => entry.message)).toEqual(['Cache warmed']);
  });
});

describe('LogStore redaction', () => {
  it('never stores authorization headers, passwords, tokens, or message content', () => {
    const redacted = redactValue({
      authorization: 'Bearer abc',
      password: 'hunter2',
      refresh_token: 'refresh-abc',
      content: 'secret message',
      plaintext: 'decrypted text',
      nested: { jwt_token: 'abc', safe: 'visible' },
    }) as Record<string, unknown>;

    expect(redacted.authorization).toBe('[redacted]');
    expect(redacted.password).toBe('[redacted]');
    expect(redacted.refresh_token).toBe('[redacted]');
    expect(redacted.content).toBe('[redacted]');
    expect(redacted.plaintext).toBe('[redacted]');
    expect(redacted.nested).toEqual({ jwt_token: '[redacted]', safe: 'visible' });
  });

  it('scrubs JWT-shaped strings and E2EE envelopes from messages and meta', async () => {
    const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ1c2VyLTEifQ.c2lnbmF0dXJlLXNpZw';
    const entry = await store.append({
      service: 'gateway',
      level: 'warn',
      message: `rejected token ${jwt}`,
      meta: { detail: `body e2ee:v1:abcdef payload` },
    });

    expect(entry?.message).not.toContain(jwt);
    expect(entry?.message).toContain('[redacted]');
    expect(JSON.stringify(entry?.meta)).not.toContain('e2ee:v1:abcdef');
  });
});

describe('pino bridge', () => {
  it('maps a pino line onto the shared entry shape and strips internals', () => {
    const line = JSON.stringify({
      level: 50,
      time: 1_700_000_000_000,
      pid: 1,
      hostname: 'host',
      name: 'rest',
      msg: 'request completed',
      method: 'GET',
      path: '/api/v1/logs',
      status_code: 200,
      duration_ms: 12.7,
      user_id: 'user-1',
    });

    const input = pinoLineToInput('rest', line);
    expect(input).not.toBeNull();
    expect(input).toMatchObject({
      service: 'rest',
      level: 'error',
      message: 'request completed',
      method: 'GET',
      path: '/api/v1/logs',
      status_code: 200,
      user_id: 'user-1',
    });
    expect(input?.meta).toBeUndefined();
  });

  it('ignores non-JSON output', () => {
    expect(pinoLineToInput('rest', 'plain text line')).toBeNull();
  });
});

describe('log API', () => {
  it('returns recent entries with filters and never exposes expired ones', async () => {
    const base = Date.now();
    await store.append({ service: 'rest', level: 'info', message: 'fresh entry', ts: base });
    await store.append({
      service: 'rest',
      level: 'info',
      message: 'expired entry',
      ts: base - 3601 * 1000,
    });

    const response = await harness.app.inject({
      method: 'GET',
      url: '/api/v1/logs?service=rest&level=info&q=fresh&limit=10',
    });
    const body = response.json();

    expect(response.statusCode).toBe(200);
    expect(body.retention_seconds).toBe(3600);
    expect(body.logs).toHaveLength(1);
    expect(body.logs[0].message).toBe('fresh entry');
  });

  it('reports the retention window and entry count', async () => {
    await harness.app.inject({ method: 'GET', url: '/healthz' });
    const response = await harness.app.inject({ method: 'GET', url: '/api/v1/logs' });
    const body = response.json();

    expect(response.statusCode).toBe(200);
    expect(body.viewer.retention_seconds).toBe(3600);
    expect(Array.isArray(body.logs)).toBe(true);
    expect(typeof body.count).toBe('number');
  });

  it('accepts a mobile diagnostic entry tagged with the caller id', async () => {
    const alice = await registerUser(harness, 'Alice');

    const response = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/logs/client',
      headers: auth(alice),
      payload: { level: 'error', tag: 'ws', message: 'socket dropped', meta: { code: 1006 } },
    });

    expect(response.statusCode).toBe(202);
    const entries = (await store.query({ service: 'mobile' })).logs;
    expect(entries).toHaveLength(1);
    expect(entries[0]).toMatchObject({
      service: 'mobile',
      level: 'error',
      message: 'socket dropped',
      user_id: alice.id,
    });
    expect(entries[0]!.meta).toMatchObject({ tag: 'ws', code: 1006 });
  });

  it('requires authentication for client logs and rejects oversized entries', async () => {
    const anonymous = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/logs/client',
      payload: { level: 'info', message: 'hello' },
    });
    expect(anonymous.statusCode).toBe(401);

    const alice = await registerUser(harness, 'Alice');
    const oversized = await harness.app.inject({
      method: 'POST',
      url: '/api/v1/logs/client',
      headers: auth(alice),
      payload: { level: 'info', message: 'x'.repeat(3_000), meta: { blob: 'y'.repeat(3_000) } },
    });
    expect(oversized.statusCode).toBe(422);
    expect(oversized.json().error.code).toBe('validation_error');
  });

  it('clears the buffer', async () => {
    await store.append({ service: 'rest', level: 'info', message: 'to be deleted' });

    const cleared = await harness.app.inject({ method: 'DELETE', url: '/api/v1/logs' });
    expect(cleared.statusCode).toBe(204);
    expect(await harness.redis.zcard(LOG_KEY)).toBe(0);
  });

  it('serves a self-contained HTML dashboard', async () => {
    const response = await harness.app.inject({ method: 'GET', url: '/logs' });

    expect(response.statusCode).toBe(200);
    expect(response.headers['content-type']).toContain('text/html');
    const html = response.body;
    expect(html).toContain('Retention: 1 hour (auto-purge)');
    expect(html).toContain('EventSource');
    expect(html).toContain('/api/v1/logs/stream');
    expect(html).not.toContain('cdn.');
  });

  it('publishes new entries to the live channel', async () => {
    const subscriber = harness.redis.duplicate();
    const received: string[] = [];
    await subscriber.subscribe(LOG_CHANNEL);
    subscriber.on('message', (_channel, raw) => received.push(raw));

    try {
      await store.append({ service: 'gateway', level: 'info', message: 'live frame' });
      await new Promise((resolve) => setTimeout(resolve, 200));

      expect(received.length).toBeGreaterThan(0);
      const entry = JSON.parse(received[0]!) as LogEntry;
      expect(entry.message).toBe('live frame');
      expect(entry.service).toBe('gateway');
    } finally {
      await subscriber.quit();
    }
  });
});

describe('LogStore when disabled', () => {
  it('writes nothing and reports an empty page', async () => {
    const disabled = new LogStore(harness.redis, {
      retentionSeconds: 3600,
      maxEntries: 100,
      enabled: false,
    });

    expect(await disabled.append({ service: 'rest', level: 'info', message: 'nope' })).toBeNull();
    expect(await disabled.query({})).toEqual({
      logs: [],
      count: 0,
      retention_seconds: 3600,
    });
    expect(await harness.redis.zcard(LOG_KEY)).toBe(0);
  });
});

describe('log viewer token', () => {
  it('requires the configured token for reads, live tail, clear, and the dashboard', async () => {
    const config = { ...TEST_CONFIG, LOG_VIEWER_TOKEN: 'viewer-secret' };
    const ctx = createContext(config, harness.db, harness.redis);
    const app = buildServer(ctx, createLogger(config, 'test'));
    await app.ready();

    try {
      const anonymous = await app.inject({ method: 'GET', url: '/api/v1/logs' });
      const wrong = await app.inject({
        method: 'GET',
        url: '/api/v1/logs',
        headers: { authorization: 'Bearer not-the-viewer' },
      });
      const header = await app.inject({
        method: 'GET',
        url: '/api/v1/logs',
        headers: { authorization: 'Bearer viewer-secret' },
      });
      const query = await app.inject({ method: 'GET', url: '/api/v1/logs?token=viewer-secret' });
      const dashboard = await app.inject({
        method: 'GET',
        url: '/logs',
        headers: { 'x-log-token': 'viewer-secret' },
      });
      const clear = await app.inject({ method: 'DELETE', url: '/api/v1/logs' });

      expect(anonymous.statusCode).toBe(401);
      expect(wrong.statusCode).toBe(401);
      expect(header.statusCode).toBe(200);
      expect(query.statusCode).toBe(200);
      expect(dashboard.statusCode).toBe(200);
      expect(clear.statusCode).toBe(401);
    } finally {
      await app.close();
    }
  });
});
