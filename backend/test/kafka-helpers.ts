import { randomUUID } from 'node:crypto';

/** Polls `predicate` until it is true, or fails after `timeoutMs`. */
export async function waitFor(
  predicate: () => boolean,
  { timeoutMs = 20_000, intervalMs = 50 } = {},
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, intervalMs));
  }
  throw new Error('condition was not met before the timeout');
}

export function uniqueTopic(): string {
  return `chat.events.test.${randomUUID()}`;
}

/**
 * Publishes until the effect is observed.
 *
 * A Kafka consumer joins with `fromBeginning: false`, so its start offset is
 * resolved at assignment time; a record produced in that window can be skipped.
 * That is the correct production behaviour (a new gateway replica must not
 * replay history), so a test that asserts delivery must retry rather than
 * assume the very first publish lands. This mirrors the gateway's own
 * at-least-once outbox retry.
 */
export async function publishUntil(
  publish: () => Promise<void>,
  observed: () => boolean,
  { attempts = 10, intervalMs = 200, timeoutMs = 20_000 } = {},
): Promise<void> {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    await publish();
    try {
      await waitFor(observed, { timeoutMs: intervalMs * 2, intervalMs: 25 });
      return;
    } catch {
      // Not observed yet; publish again.
    }
  }
  await waitFor(observed, { timeoutMs });
}
