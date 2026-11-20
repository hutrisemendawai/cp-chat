import { z } from 'zod';

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
});

export type Config = z.infer<typeof envSchema> & { gatewayNodeId: string };

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = envSchema.parse(env);
  return {
    ...parsed,
    gatewayNodeId: parsed.GATEWAY_NODE_ID ?? `node-${process.pid}-${Math.random().toString(36).slice(2, 8)}`,
  };
}
