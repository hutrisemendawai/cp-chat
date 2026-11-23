import { Writable } from 'node:stream';

import type { LoggerOptions } from 'pino';
import pino from 'pino';

import type { Config } from '../config.js';
import type { LogService, LogStore } from './log-store.js';

let mirror: { store: LogStore; service: LogService } | null = null;

/**
 * Installs the process-wide log mirror.
 *
 * `rest` and `gateway` are separate processes, so the service tag is fixed per
 * process rather than inferred from each pino logger's `name` (a gateway also
 * creates `broker`/`messages` loggers, all of which belong to `gateway`).
 */
export function configureLogMirror(store: LogStore | null, service: LogService): void {
  mirror = store ? { store, service } : null;
}

export function createLogger(config: Config, name: string) {
  const options: LoggerOptions = {
    name,
    level: config.LOG_LEVEL,
    redact: {
      paths: ['req.headers.authorization', '*.password', '*.refresh_token', '*.content'],
      censor: '[redacted]',
    },
  };

  const active = mirror;
  if (!active || !active.store.isEnabled) {
    return pino(options);
  }

  // Mirroring has to be non-blocking and incapable of taking the process down:
  // a log line is never allowed to fail a request. `appendPinoLine` swallows
  // Redis errors and this writable swallows sync throws.
  const mirrorStream = new Writable({
    write(chunk, _encoding, callback) {
      try {
        active.store.appendPinoLine(active.service, chunk.toString());
      } catch {
        // Never throw from the log path.
      }
      callback();
    },
  });

  return pino(
    options,
    pino.multistream([
      { stream: process.stdout },
      { stream: mirrorStream },
    ]),
  );
}

export type Logger = ReturnType<typeof createLogger>;
