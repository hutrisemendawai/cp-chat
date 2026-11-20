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
  CONNECTION_TTL_SECONDS: z.coerce.number().int().positive().default(120),
  MEMBERS_CACHE_TTL_SECONDS: z.coerce.number().int().positive().default(60),
  FCM_CREDENTIALS_FILE: z.string().optional(),
  FCM_PROJECT_ID: z.string().optional(),
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
  MEDIA_PRESIGN_TTL_SECONDS: z.coerce.number().int().positive().default(900),
  MEDIA_MAX_BYTES: z.coerce.number().int().positive().default(26_214_400),
  MEDIA_ALLOWED_TYPES: z
    .string()
    .default(
      'image/jpeg,image/png,image/webp,image/gif,application/pdf,text/plain,' +
        'application/zip,application/octet-stream,video/mp4,audio/mpeg',
    ),
});

export type Config = z.infer<typeof envSchema> & { gatewayNodeId: string };

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = envSchema.parse(env);
  return {
    ...parsed,
    gatewayNodeId: parsed.GATEWAY_NODE_ID ?? `node-${process.pid}-${Math.random().toString(36).slice(2, 8)}`,
  };
}
