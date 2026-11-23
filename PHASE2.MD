You are executing Phase 2 of PLAN.MD for CP Chat. Build a unified, lightweight real-time logging system with a strict 1-hour maximum retention (auto-pruned) and a live web monitoring page, then verify and push to git main.

Tasks:
1. Backend 1-Hour TTL Log Store (`backend/src/lib/log-store.ts`, `backend/src/lib/logger.ts`, `backend/src/config.ts`):
   - Add config options:
     - `LOG_BUFFER_ENABLED` (boolean, default `true`)
     - `LOG_RETENTION_SECONDS` (number, default `3600` — 1 hour max)
     - `LOG_MAX_ENTRIES` (number, default `5000`)
     - `LOG_VIEWER_TOKEN` (optional string; if set, protects `/logs` and `/api/v1/logs*`, if empty in dev/LAN mode allow access or accept Bearer JWT)
   - Implement `LogStore` backed by Redis Sorted Set (`cpchat:logs`, score = Unix timestamp in ms) + Redis Pub/Sub channel (`cpchat:logs:live`) so both the `rest` and `gateway` containers write into the exact same timeline:
     - Each entry JSON contains: `{ id, ts, service: 'rest' | 'gateway' | 'mobile', level: 'debug' | 'info' | 'warn' | 'error' | 'fatal', message, user_id?, req_id?, method?, path?, status_code?, duration_ms?, meta? }`.
     - Automatically prune entries older than `Date.now() - LOG_RETENTION_SECONDS * 1000` using `ZREMRANGEBYSCORE` and enforce `LOG_MAX_ENTRIES` using `ZREMRANGEBYRANK` on a 60-second background interval AND opportunistically on writes. Set a safety key TTL of `LOG_RETENTION_SECONDS + 300` seconds.
     - Preserve redaction: never log `authorization` headers, passwords, refresh tokens, JWTs, or E2EE/message plaintext content.
   - Hook Pino (`createLogger` in `backend/src/lib/logger.ts`) via a lightweight multistream / writable hook so `rest` and `gateway` logs are mirrored asynchronously to `LogStore` without blocking I/O or crashing if Redis is momentarily unavailable.
   - Add concise structured logs for key lifecycle events in REST & Gateway: HTTP request completion (method, path, status, duration, userId), WS upgrade/connect/disconnect, WS `send`/`ack` accepted & rejected (with error code), media upload/download, and unhandled errors.

2. Backend Log API & Live Web Page (`backend/src/http/log-routes.ts`, `backend/src/http/server.ts`):
   - `GET /api/v1/logs`: Query recent logs (within the last 1 hour) with optional filters: `service`, `level`, `q` (case-insensitive substring match), `since` (ISO or epoch ms), `limit` (default 200, max 1000). Always prunes expired entries (> 1 hour) before returning.
   - `GET /api/v1/logs/stream`: Server-Sent Events (`text/event-stream`) endpoint that streams new log entries in real time via Redis Pub/Sub `cpchat:logs:live` with periodic `:keepalive` comments.
   - `POST /api/v1/logs/client`: Authenticated endpoint (`requireAuth`) allowing the Flutter mobile app to submit client-side diagnostic logs (`level`, `tag`, `message`, `meta`) tagged with `service: 'mobile'` and `user_id: request.userId` (rate-limited / size-capped to 4 KB per entry).
   - `DELETE /api/v1/logs`: Clears all buffered logs immediately (useful between test runs).
   - `GET /logs`: Serve a self-contained, zero-build, dark-themed responsive HTML + vanilla JS monitoring dashboard (no external CDN dependencies so it works completely offline on LAN):
     - Connects to `/api/v1/logs` on load and `/api/v1/logs/stream` via `EventSource` for live tailing.
     - Filter chips by service (`All`, `rest`, `gateway`, `mobile`) and level (`ALL`, `INFO`, `WARN`, `ERROR`).
     - Live keyword search box, Pause/Resume auto-scroll toggle, Clear Logs button, and a header indicator showing `Retention: 1 hour (auto-purge)` + current entry count + SSE connection status.
     - Click any log row to expand formatted JSON metadata.

3. Flutter Client Error Forwarding (`mobile/lib/core/logging/app_logger.dart`, `mobile/lib/core/network/api_client.dart`, `mobile/lib/core/network/ws_client.dart`):
   - Add a lightweight `AppLogger` utility with an in-memory ring buffer (last 300 entries, max 1 hour) that logs WS connect/disconnect/errors, Dio network errors, media upload errors, and E2EE errors, and asynchronously forwards `warn`/`error` entries to `POST /api/v1/logs/client` (fire-and-forget, never recursive on failure).

4. Tests & Verification:
   - Add backend Vitest tests (`backend/test/logs.test.ts`) verifying 1-hour expiry pruning (`ZREMRANGEBYSCORE`), max-entry capping, filtering (`service`, `level`, `q`), redaction of sensitive fields, `POST /api/v1/logs/client`, `DELETE /api/v1/logs`, and `GET /logs` returning HTML 200.
   - Run `cd backend && npm run typecheck && npm test` and `cd mobile && flutter analyze && flutter test`.
   - Commit all changes cleanly and push to `git main`.
