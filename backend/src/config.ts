import { z } from 'zod';

const booleanEnv = (defaultValue: boolean) =>
  z
    .enum(['true', 'false', '1', '0'])
    .default(defaultValue ? 'true' : 'false')
    .transform((value) => value === 'true' || value === '1');

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  DATABASE_URL: z
    .string()
    .default('postgres://cpchat:cpchat@localhost:5432/cpchat?sslmode=disable'),
  REDIS_URL: z.string().default('redis://localhost:6379/0'),
  JWT_SECRET: z.string().min(16).default('dev-only-secret-change-me-please'),
  ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  REFRESH_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().default(60 * 60 * 24 * 30),
  REST_HOST: z.string().default('0.0.0.0'),
  REST_PORT: z.coerce.number().int().positive().default(8080),
  GATEWAY_HOST: z.string().default('0.0.0.0'),
  GATEWAY_PORT: z.coerce.number().int().positive().default(8081),
  GATEWAY_NODE_ID: z.string().optional(),
  PRESENCE_TTL_SECONDS: z.coerce.number().int().positive().default(45),
  // Kept short so a socket whose app was killed (no clean close frame) stops
  // counting as "online" fast, letting the very next message fall through to
  // FCM instead of being suppressed by a stale routing entry.
  CONNECTION_TTL_SECONDS: z.coerce.number().int().positive().default(45),
  MEMBERS_CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(60),
  FCM_CREDENTIALS_FILE: z.string().optional(),
  FCM_PROJECT_ID: z.string().optional(),
  // Inline service-account credentials, used when no credentials file is
  // mounted (e.g. Docker/CI). `FIREBASE_PRIVATE_KEY` may carry literal `\n`
  // escapes; the loader converts them to real newlines.
  FIREBASE_PROJECT_ID: z.string().optional(),
  FIREBASE_CLIENT_EMAIL: z.string().optional(),
  FIREBASE_PRIVATE_KEY: z.string().optional(),
  MAX_GROUP_MEMBERS: z.coerce.number().int().positive().max(500).default(500),
  S3_ENDPOINT: z.string().default('http://localhost:9000'),
  // Host reachable by the mobile client. Presigned URLs are signed against this
  // endpoint while the server itself talks to S3_ENDPOINT (e.g. `minio` inside
  // Docker, `10.0.2.2` from the Android emulator).
  S3_PUBLIC_ENDPOINT: z.string().optional(),
  S3_REGION: z.string().default('us-east-1'),
  S3_BUCKET: z.string().default('cp-chat-media'),
  S3_ACCESS_KEY_ID: z.string().default('cpchat'),
  S3_SECRET_ACCESS_KEY: z.string().default('cpchat-secret'),
  S3_FORCE_PATH_STYLE: booleanEnv(true),
  // `s3` talks to a real bucket; `memory` keeps objects in-process so media
  // tests run without MinIO (the object key and auth paths are unchanged).
  S3_DRIVER: z.enum(['s3', 'memory']).default('s3'),
  MEDIA_PRESIGN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  MEDIA_MAX_BYTES: z.coerce.number().int().positive().default(26_214_400),
  // Serve `GET /media/*` by streaming the object through the API instead of
  // redirecting to a presigned URL. A phone often cannot reach the storage host
  // directly, so streaming is the default; `?proxy=0` opts back into a redirect.
  MEDIA_PROXY_DOWNLOAD: booleanEnv(true),
  MEDIA_ALLOWED_TYPES: z
    .string()
    .default(
      'image/jpeg,image/png,image/webp,image/gif,application/pdf,text/plain,' +
        'application/zip,application/octet-stream,video/mp4,audio/mpeg',
    ),

  // ---- Phase 2: realtime log buffer ----
  // Mirrors rest + gateway + mobile diagnostics into one Redis-backed timeline
  // with a hard 1-hour retention. The buffer is in-memory-sized, never
  // persisted, and pruned on a background interval and on every write.
  LOG_BUFFER_ENABLED: booleanEnv(true),
  LOG_RETENTION_SECONDS: z.coerce.number().int().positive().max(3600).default(3600),
  LOG_MAX_ENTRIES: z.coerce.number().int().positive().max(100_000).default(5000),
  // Optional shared secret for the /logs dashboard and the log API. Empty means
  // the LAN/dev default: open access, but a bearer JWT is still honoured.
  LOG_VIEWER_TOKEN: z.string().trim().max(200).optional(),

  // ---- Phase 4: broker ----
  // `redis` keeps the Phase 1-3 Pub/Sub transport; `kafka` switches realtime
  // fan-out to a durable, partitioned log (see lib/broker.ts).
  BROKER: z.enum(['redis', 'kafka']).default('redis'),
  KAFKA_BROKERS: z.string().default('localhost:9092'),
  KAFKA_CLIENT_ID: z.string().default('cp-chat'),
  KAFKA_EVENTS_TOPIC: z.string().default('chat.events'),
  KAFKA_CONSUMER_PREFIX: z.string().default('gateway'),
  // When true the gateway also ingests `chat.inbound` and publishes accepted
  // sends to the event topic instead of processing them inline. Requires BROKER=kafka.
  GATEWAY_ASYNC_INGEST: booleanEnv(false),
  KAFKA_INBOUND_TOPIC: z.string().default('chat.inbound'),
  KAFKA_INBOUND_GROUP: z.string().default('message-service'),

  // ---- Phase 4: message storage ----
  // `postgres` keeps the transactional seq allocator; `scylla` moves the
  // high-volume message table to Cassandra/ScyllaDB with a Postgres mirror for
  // idempotency and full-text search (see domain/message-store.ts).
  MESSAGE_STORE: z.enum(['postgres', 'scylla']).default('postgres'),
  SCYLLA_CONTACT_POINTS: z.string().default('localhost:9042'),
  SCYLLA_KEYSPACE: z.string().default('cp_chat'),
  SCYLLA_LOCAL_DATACENTER: z.string().default('datacenter1'),
  SCYLLA_USERNAME: z.string().optional(),
  SCYLLA_PASSWORD: z.string().optional(),

  // ---- Phase 4: gateway scaling ----
  GATEWAY_DRAIN_TIMEOUT_MS: z.coerce.number().int().positive().default(30_000),
  // Set by an orchestrator on shutdown so /readyz reports draining immediately.
  GATEWAY_ADVERTISE_HOST: z.string().optional(),

  // ---- Phase 4: observability ----
  OTEL_ENABLED: booleanEnv(false),
  OTEL_SERVICE_NAME: z.string().default('cp-chat'),
  OTEL_EXPORTER_OTLP_ENDPOINT: z.string().default('http://localhost:4318'),
  OTEL_TRACES_SAMPLER_RATIO: z.coerce.number().min(0).max(1).default(0.1),

  // ---- Voice & Video Calls (Self-Hosted LiveKit SFU) ----
  LIVEKIT_API_KEY: z.string().optional(),
  LIVEKIT_API_SECRET: z.string().optional(),
  LIVEKIT_URL: z.string().default('http://127.0.0.1:7880'),
  LIVEKIT_PUBLIC_URL: z.string().default('ws://10.0.2.2:7880'),
  LIVEKIT_TOKEN_TTL_SECONDS: z.coerce.number().int().positive().max(3600).default(600),
  CALL_RING_TIMEOUT_SECONDS: z.coerce.number().int().positive().max(120).default(40),
  CALL_MAX_GROUP_PARTICIPANTS: z.coerce.number().int().positive().max(100).default(20),
});

export type Config = z.infer<typeof envSchema> & { gatewayNodeId: string };

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = envSchema.parse(env);
  return {
    ...parsed,
    gatewayNodeId: parsed.GATEWAY_NODE_ID ?? `node-${process.pid}-${Math.random().toString(36).slice(2, 8)}`,
  };
}
