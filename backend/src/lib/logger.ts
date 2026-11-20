import pino from 'pino';

import type { Config } from '../config.js';

export function createLogger(config: Config, name: string) {
  return pino({
    name,
    level: config.LOG_LEVEL,
    redact: {
      paths: ['req.headers.authorization', '*.password', '*.refresh_token', '*.content'],
      censor: '[redacted]',
    },
  });
}

export type Logger = ReturnType<typeof createLogger>;
