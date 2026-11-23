import { randomUUID } from 'node:crypto';

import type { Cache } from './redis.js';

/**
 * A unified, in-Redis timeline of backend and mobile diagnostics.
 *
 * `rest` and `gateway` run as separate processes (and may run as several
 * replicas), so a per-process ring buffer would show only a slice of what
 * happened. Every entry therefore lands in one Redis sorted set scored by
 * timestamp, and new entries are mirrored to a Pub/Sub channel for live tailing.
 *
 * Retention is deliberately short: this is a debugging window, not an audit log.
 * Entries older than `retentionSeconds` are removed on a background interval and
 * opportunistically whenever the buffer is written or read.
 */

export const LOG_KEY = 'cpchat:logs';
export const LOG_CHANNEL = 'cpchat:logs:live';

export const LOG_SERVICES = ['rest', 'gateway', 'mobile'] as const;
export const LOG_LEVELS = ['debug', 'info', 'warn', 'error', 'fatal'] as const;

export type LogService = (typeof LOG_SERVICES)[number];
export type LogLevel = (typeof LOG_LEVELS)[number];

export type LogEntry = {
  id: string;
  ts: number;
  service: LogService;
  level: LogLevel;
  message: string;
  user_id?: string;
  req_id?: string;
  method?: string;
  path?: string;
  status_code?: number;
  duration_ms?: number;
  meta?: Record<string, unknown>;
};

export type LogInput = {
  service: LogService;
  level: LogLevel;
  message: string;
  ts?: number;
  id?: string;
  user_id?: string;
  req_id?: string;
  method?: string;
  path?: string;
  status_code?: number;
  duration_ms?: number;
  meta?: Record<string, unknown>;
};

export type LogQuery = {
  service?: string;
  level?: string;
  q?: string;
  since?: number;
  limit?: number;
};

export type LogQueryResult = {
  logs: LogEntry[];
  count: number;
  retention_seconds: number;
};

export type LogStoreOptions = {
  retentionSeconds: number;
  maxEntries: number;
  enabled?: boolean;
};

const LEVEL_WEIGHT: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
  fatal: 50,
};

/** How long a whole write is allowed to take before it is dropped. */
const WRITE_TIMEOUT_MS = 2_000;
/** Pruning is cheap but not free; don't run it on every single write. */
const OPPORTUNISTIC_PRUNE_INTERVAL_MS = 5_000;
/** Extra TTL on the key so a stalled process cannot leave data forever. */
const KEY_TTL_MARGIN_SECONDS = 300;

// Matched against the whole key. Suffix forms (`jwt_token`, `api_secret`,
// `password_hash`) are covered by the `(token|secret|password)` alternation so
// a new field name does not silently start leaking credentials.
const SENSITIVE_KEY =
  /^(authorization|proxy-authorization|cookie|set-cookie|content|plaintext|private_key|identity_key|one_time_prekeys?|signed_prekey|api_key)$|(^|[_-])(token|secret|password)([_-]|_hash)?$/i;

const JWT_PATTERN = /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g;
const E2EE_PATTERN = /e2ee:v1:\S+/g;

export class LogStore {
  private readonly retentionMs: number;
  private readonly maxEntries: number;
  private readonly enabled: boolean;
  private readonly subscribers = new Set<(entry: LogEntry) => void>();
  private pruneTimer: NodeJS.Timeout | null = null;
  private lastPruneAt = 0;
  private subscriber: Cache | null = null;
  private subscribing: Promise<void> | null = null;

  constructor(
    private readonly redis: Cache,
    options: LogStoreOptions,
  ) {
    this.retentionMs = options.retentionSeconds * 1000;
    this.maxEntries = options.maxEntries;
    this.enabled = options.enabled ?? true;
  }

  get isEnabled(): boolean {
    return this.enabled;
  }

  get retentionSeconds(): number {
    return Math.round(this.retentionMs / 1000);
  }

  get maxEntryCount(): number {
    return this.maxEntries;
  }

  /**
   * Starts periodic pruning and the shared live-tail subscription.
   *
   * A store that is disabled stays completely inert, including the timer, so
   * turning the buffer off really means off.
   */
  start(): void {
    if (!this.enabled) return;
    if (this.pruneTimer) return;

    this.pruneTimer = setInterval(() => {
      void this.prune();
    }, 60_000);
    this.pruneTimer.unref?.();
  }

  async stop(): Promise<void> {
    if (this.pruneTimer) clearInterval(this.pruneTimer);
    this.pruneTimer = null;
    this.subscribers.clear();
    await this.subscribing?.catch(() => undefined);
    const subscriber = this.subscriber;
    this.subscriber = null;
    if (subscriber) {
      try {
        await subscriber.quit();
      } catch {
        subscriber.disconnect();
      }
    }
  }

  /** Appends an entry. Resolves even when Redis is unavailable. */
  async append(input: LogInput): Promise<LogEntry | null> {
    if (!this.enabled) return null;

    const entry = normalizeEntry(input);
    try {
      await this.withTimeout(
        this.redis
          .multi()
          .zadd(LOG_KEY, entry.ts, JSON.stringify(entry))
          .expire(LOG_KEY, this.retentionSeconds + KEY_TTL_MARGIN_SECONDS)
          .exec(),
      );
    } catch {
      // The log buffer must never take the request path down with it.
      return null;
    }

    this.publishLive(entry);
    void this.pruneIfDue();
    return entry;
  }

  /**
   * Appends a raw Pino JSON line, if it can be attributed to the service.
   *
   * Pino is configured with `multistream`, so this runs for every log line the
   * process emits. Anything unparseable is silently dropped rather than
   * producing log-about-logs noise.
   */
  appendPinoLine(service: LogService, line: string): void {
    if (!this.enabled) return;
    const input = pinoLineToInput(service, line);
    if (!input) return;
    void this.append(input);
  }

  /** Queries the retained window, always pruning expired entries first. */
  async query(params: LogQuery = {}): Promise<LogQueryResult> {
    if (!this.enabled) {
      return { logs: [], count: 0, retention_seconds: this.retentionSeconds };
    }

    await this.prune();

    const now = Date.now();
    const since = clampSince(params.since, now - this.retentionMs, now);
    const limit = clampLimit(params.limit);
    const level = normalizeLevel(params.level);
    const service = normalizeService(params.service);
    const needle = params.q?.trim().toLowerCase() ?? '';

    let raw: string[];
    try {
      // Pull a generous window from the newest end, then filter in memory; the
      // service/level/substring predicates are not expressible in Redis.
      raw = await this.redis.zrevrangebyscore(
        LOG_KEY,
        '+inf',
        since,
        'LIMIT',
        0,
        Math.max(limit * 8, 500),
      );
    } catch {
      return { logs: [], count: 0, retention_seconds: this.retentionSeconds };
    }

    const entries = raw
      .map(parseEntry)
      .filter((entry): entry is LogEntry => entry !== null)
      .filter((entry) => (service ? entry.service === service : true))
      .filter((entry) =>
        level ? LEVEL_WEIGHT[entry.level] >= LEVEL_WEIGHT[level] : true,
      )
      .filter((entry) => (needle ? matchesQuery(entry, needle) : true))
      // The window came back newest-first; the UI reads oldest-first.
      .reverse()
      .slice(-limit);

    let count = entries.length;
    try {
      count = await this.redis.zcard(LOG_KEY);
    } catch {
      // The filtered count is a reasonable fallback.
    }

    return { logs: entries, count, retention_seconds: this.retentionSeconds };
  }

  /** Removes every buffered entry. Used between test runs. */
  async clear(): Promise<void> {
    if (!this.enabled) return;
    try {
      await this.redis.del(LOG_KEY);
    } catch {
      // Clearing is best effort; a retained entry is not a correctness problem.
    }
  }

  /**
   * Streams new entries to a listener. Returns an unsubscribe function.
   *
   * A single duplicated Redis connection serves every SSE client: subscription
   * count is per browser tab, and opening one connection per tab would exhaust
   * the server's client budget.
   */
  async subscribeLive(listener: (entry: LogEntry) => void): Promise<() => void> {
    this.subscribers.add(listener);
    await this.ensureSubscriber();

    return () => {
      this.subscribers.delete(listener);
    };
  }

  private async ensureSubscriber(): Promise<void> {
    if (this.subscriber || !this.enabled) return;
    // Two tabs opening at once must not each create a duplicate subscriber.
    if (this.subscribing) return this.subscribing;

    this.subscribing = (async () => {
      const subscriber = this.redis.duplicate();
      subscriber.on('message', (channel, raw) => {
        if (channel !== LOG_CHANNEL) return;
        const entry = parseEntry(raw);
        if (!entry) return;
        for (const listener of this.subscribers) {
          try {
            listener(entry);
          } catch {
            // One broken client must not stop the fan-out.
          }
        }
      });
      subscriber.on('error', () => undefined);

      try {
        await subscriber.subscribe(LOG_CHANNEL);
        this.subscriber = subscriber;
      } catch {
        subscriber.disconnect();
      }
    })().finally(() => {
      this.subscribing = null;
    });

    return this.subscribing;
  }

  /**
   * Drops expired entries (by score) and then anything beyond the newest
   * `maxEntries` (by rank).
   */
  async prune(): Promise<void> {
    if (!this.enabled) return;
    this.lastPruneAt = Date.now();
    const cutoff = Date.now() - this.retentionMs;
    try {
      await this.redis
        .multi()
        .zremrangebyscore(LOG_KEY, '-inf', cutoff)
        // Ranks are 0-based over ascending scores, so keeping the last N means
        // removing up to `-(N + 1)`.
        .zremrangebyrank(LOG_KEY, 0, -(this.maxEntries + 1))
        .exec();
    } catch {
      // Ignore: the next interval tries again.
    }
  }

  private async pruneIfDue(): Promise<void> {
    if (Date.now() - this.lastPruneAt < OPPORTUNISTIC_PRUNE_INTERVAL_MS) return;
    await this.prune();
  }

  private publishLive(entry: LogEntry): void {
    try {
      // Fire-and-forget: live tailing is best effort, the sorted set is the
      // source of truth for the initial load.
      void this.redis.publish(LOG_CHANNEL, JSON.stringify(entry)).catch(() => undefined);
    } catch {
      // A closed connection throws synchronously.
    }
  }

  private async withTimeout<T>(work: Promise<T>): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('log write timed out')), WRITE_TIMEOUT_MS);
      timer.unref?.();
      work.then(
        (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        (error) => {
          clearTimeout(timer);
          reject(error);
        },
      );
    });
  }
}

/** Maps a Pino-level record to a log entry, or null when it is not usable. */
export function pinoLineToInput(service: LogService, line: string): LogInput | null {
  const trimmed = line.trim();
  if (!trimmed.startsWith('{')) return null;

  let record: Record<string, unknown>;
  try {
    const decoded = JSON.parse(trimmed);
    if (typeof decoded !== 'object' || decoded === null) return null;
    record = decoded as Record<string, unknown>;
  } catch {
    return null;
  }

  const message = typeof record.msg === 'string' ? record.msg : '';
  // Fastify's own request lifecycle lines are replaced by an explicit
  // completion log in `server.ts`, so they would only duplicate entries.
  if (!message) return null;

  const level = pinoLevel(record.level);
  const meta = { ...record };
  for (const key of [
    'level',
    'time',
    'pid',
    'hostname',
    'name',
    'msg',
    'userId',
    'user_id',
    'reqId',
    'req_id',
    'method',
    'path',
    'url',
    'status_code',
    'statusCode',
    'duration_ms',
    'responseTime',
  ]) {
    delete meta[key];
  }

  return {
    service,
    level,
    message,
    ts: typeof record.time === 'number' ? record.time : undefined,
    user_id: stringField(record.user_id ?? record.userId),
    req_id: stringField(record.req_id ?? record.reqId),
    method: stringField(record.method),
    path: stringField(record.path ?? record.url),
    status_code: numberField(record.status_code ?? record.statusCode),
    duration_ms: numberField(record.duration_ms ?? record.responseTime),
    meta: Object.keys(meta).length > 0 ? (redactValue(meta) as Record<string, unknown>) : undefined,
  };
}

function normalizeEntry(input: LogInput): LogEntry {
  const meta = input.meta ? (redactValue(input.meta) as Record<string, unknown>) : undefined;
  const entry: LogEntry = {
    id: input.id ?? randomUUID(),
    ts: input.ts ?? Date.now(),
    service: input.service,
    level: input.level,
    message: redactText(input.message).slice(0, 4_000),
  };
  if (input.user_id) entry.user_id = input.user_id;
  if (input.req_id) entry.req_id = input.req_id;
  if (input.method) entry.method = input.method;
  if (input.path) entry.path = redactText(input.path).slice(0, 1_000);
  if (input.status_code !== undefined) entry.status_code = input.status_code;
  if (input.duration_ms !== undefined) entry.duration_ms = Math.round(input.duration_ms);
  if (meta && Object.keys(meta).length > 0) entry.meta = meta;
  return entry;
}

function parseEntry(raw: string): LogEntry | null {
  try {
    const decoded = JSON.parse(raw) as Partial<LogEntry>;
    if (
      typeof decoded.id !== 'string' ||
      typeof decoded.ts !== 'number' ||
      typeof decoded.message !== 'string' ||
      !isService(decoded.service) ||
      !isLevel(decoded.level)
    ) {
      return null;
    }
    return decoded as LogEntry;
  } catch {
    return null;
  }
}

/**
 * Removes secrets before anything reaches Redis or the dashboard.
 *
 * Message bodies are redacted by key (`content`, `plaintext`) and JWT-shaped
 * strings are scrubbed wherever they appear, because a token can be embedded in
 * an error message rather than a dedicated field.
 */
export function redactValue(value: unknown, depth = 0): unknown {
  if (depth > 6) return '[truncated]';
  if (typeof value === 'string') return redactText(value).slice(0, 4_000);
  if (Array.isArray(value)) return value.slice(0, 50).map((item) => redactValue(item, depth + 1));
  if (value && typeof value === 'object') {
    const result: Record<string, unknown> = {};
    for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
      if (SENSITIVE_KEY.test(key)) {
        result[key] = '[redacted]';
        continue;
      }
      result[key] = redactValue(child, depth + 1);
    }
    return result;
  }
  return value;
}

export function redactText(text: string): string {
  return text.replace(JWT_PATTERN, '[redacted]').replace(E2EE_PATTERN, '[redacted]');
}

function matchesQuery(entry: LogEntry, needle: string): boolean {
  if (entry.message.toLowerCase().includes(needle)) return true;
  if (entry.path?.toLowerCase().includes(needle)) return true;
  if (entry.user_id?.toLowerCase().includes(needle)) return true;
  if (entry.meta) {
    try {
      return JSON.stringify(entry.meta).toLowerCase().includes(needle);
    } catch {
      return false;
    }
  }
  return false;
}

function pinoLevel(value: unknown): LogLevel {
  if (typeof value !== 'number') return 'info';
  if (value >= 60) return 'fatal';
  if (value >= 50) return 'error';
  if (value >= 40) return 'warn';
  if (value >= 20) return 'info';
  return 'debug';
}

function clampSince(since: unknown, floor: number, ceiling: number): number {
  if (typeof since !== 'number' || !Number.isFinite(since)) return floor;
  return Math.min(Math.max(since, floor), ceiling);
}

function clampLimit(limit: unknown): number {
  if (typeof limit !== 'number' || !Number.isFinite(limit)) return 200;
  return Math.min(Math.max(Math.trunc(limit), 1), 1_000);
}

function normalizeLevel(value: unknown): LogLevel | null {
  if (typeof value !== 'string') return null;
  const lowered = value.trim().toLowerCase();
  if (lowered === 'all' || lowered === '') return null;
  return isLevel(lowered) ? lowered : null;
}

function normalizeService(value: unknown): LogService | null {
  if (typeof value !== 'string') return null;
  const lowered = value.trim().toLowerCase();
  if (lowered === 'all' || lowered === '') return null;
  return isService(lowered) ? lowered : null;
}

function stringField(value: unknown): string | undefined {
  return typeof value === 'string' && value ? value : undefined;
}

function numberField(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) ? value : undefined;
}

function isService(value: unknown): value is LogService {
  return typeof value === 'string' && (LOG_SERVICES as readonly string[]).includes(value);
}

function isLevel(value: unknown): value is LogLevel {
  return typeof value === 'string' && (LOG_LEVELS as readonly string[]).includes(value);
}
