import { createServer } from 'node:http';

import { loadConfig } from './config.js';
import { createDb } from './lib/db.js';
import { NotificationService } from './lib/fcm.js';
import { createLogger } from './lib/logger.js';
import { createRedis } from './lib/redis.js';
import { createContext } from './http/context.js';
import { ChatGateway } from './gateway/chat-gateway.js';

async function main() {
  const config = loadConfig();
  const logger = createLogger(config, 'gateway');

  const db = createDb(config.DATABASE_URL);
  const redis = createRedis(config.REDIS_URL);
  const ctx = createContext(config, db, redis);

  const notifications = new NotificationService(config, logger);
  await notifications.initialize();

  const gateway = new ChatGateway(config, ctx, notifications, logger);
  await gateway.start();

  const server = createServer((request, response) => {
    if (request.url === '/healthz') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ status: 'ok', node: config.gatewayNodeId }));
      return;
    }
    response.writeHead(404, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ error: 'not_found' }));
  });

  server.on('upgrade', (request, socket, head) => {
    const url = new URL(request.url ?? '/', 'http://gateway.local');
    if (url.pathname !== '/ws') {
      socket.write('HTTP/1.1 404 Not Found\r\n\r\n');
      socket.destroy();
      return;
    }
    gateway.handleUpgrade(request, socket, head);
  });

  await new Promise<void>((resolve) => {
    server.listen(config.GATEWAY_PORT, config.GATEWAY_HOST, resolve);
  });
  logger.info(
    { port: config.GATEWAY_PORT, node: config.gatewayNodeId },
    'gateway listening',
  );

  const shutdown = async (signal: string) => {
    logger.info({ signal }, 'shutting down gateway');
    await gateway.stop();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await db.end();
    redis.disconnect();
    process.exit(0);
  };

  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
}

main().catch((error) => {
  console.error('Gateway failed to start', error);
  process.exit(1);
});
