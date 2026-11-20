import { loadConfig } from './config.js';
import { createDb } from './lib/db.js';
import { createLogger } from './lib/logger.js';
import { createRedis } from './lib/redis.js';
import { createContext } from './http/context.js';
import { buildServer } from './http/server.js';

async function main() {
  const config = loadConfig();
  const logger = createLogger(config, 'rest');

  const db = createDb(config.DATABASE_URL);
  const redis = createRedis(config.REDIS_URL);
  const ctx = createContext(config, db, redis);
  const app = buildServer(ctx, logger);

  await app.listen({ host: config.REST_HOST, port: config.REST_PORT });

  const shutdown = async (signal: string) => {
    logger.info({ signal }, 'shutting down');
    await app.close();
    await db.end();
    redis.disconnect();
    process.exit(0);
  };

  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
}

main().catch((error) => {
  console.error('REST server failed to start', error);
  process.exit(1);
});
