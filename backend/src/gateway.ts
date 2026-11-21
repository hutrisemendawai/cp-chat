import { createServer } from 'node:http';

import { loadConfig } from './config.js';
import { createDb } from './lib/db.js';
import { NotificationService } from './lib/fcm.js';
import { createLogger } from './lib/logger.js';
import { createRedis } from './lib/redis.js';
import { createContext } from './http/context.js';
import { ChatGateway } from './gateway/chat-gateway.js';
import { startTracing, shutdownTracing } from './lib/tracing.js';

async function main() {
  const config = loadConfig();
  const logger = createLogger(config, 'gateway');
  const tracing = await startTracing(config, 'gateway');

  const db = createDb(config.DATABASE_URL);
  const redis = createRedis(config.REDIS_URL);
  const ctx = createContext(config, db, redis);

  const notifications = new NotificationService(config, logger);
  await notifications.initialize();

  const gateway = new ChatGateway(config, ctx, ctx.broker, notifications, logger);
  await gateway.start();

  const server = createServer((request, response) => {
    // Liveness: the process is up and the event loop is responsive.
    if (request.url === '/healthz') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ status: 'ok', node: config.gatewayNodeId }));
      return;
    }
    // Readiness: false while starting and during a drain, so the load
    // balancer stops sending upgrades to this replica before it closes.
    if (request.url === '/readyz') {
      const ready = gateway.isReady();
      response.writeHead(ready ? 200 : 503, { 'content-type': 'application/json' });
      response.end(
        JSON.stringify({
          status: ready ? 'ready' : 'draining',
          node: config.gatewayNodeId,
          broker: ctx.broker.kind,
        }),
      );
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

  server.listen(config.GATEWAY_PORT, config.GATEWAY_HOST);
  await new Promise<void>((resolve) => {
    if (server.listening) resolve();
    else server.once('listening', resolve);
  });
  logger.info(
    { port: config.GATEWAY_PORT, node: config.gatewayNodeId, broker: ctx.broker.kind },
    'gateway listening',
  );

  // Graceful shutdown for rolling deploys: stop accepting upgrades, ask every
  // client to reconnect elsewhere, then close the listener. `process.exit`
  // waits for the drain to finish rather than dropping sockets mid-frame.
  const shutdown = async (signal: string) => {
    logger.info({ signal }, 'shutting down gateway');
    await gateway.drain();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await gateway.stop();
    await ctx.broker.close();
    await ctx.scylla?.close();
    await tracing?.shutdown();
    await db.end();
    redis.disconnect();
    process.exit(0);
  };

  process.on('SIGINT', () => void shutdown('SIGINT'));
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  void shutdownTracing;
}

main().catch((error) => {
  console.error('Gateway failed to start', error);
  process.exit(1);
});
