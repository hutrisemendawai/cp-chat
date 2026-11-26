# CP Chat

**CP Chat** — A scalable, low-latency 1:1 & group messaging application built with Flutter (Android) and a distributed WebSocket-driven backend architecture.

A complete foundation and phased development roadmap for building a production-ready messaging platform with real-time message delivery, offline sync, push notifications, and group management.

For detailed architecture, technology stack, and development phases, see [AGENTS.MD](./AGENTS.MD).

## Repository layout

| Path | Contents |
| --- | --- |
| `mobile/` | Flutter Android client (Riverpod, Drift, secure storage, WebSocket client, E2EE) |
| `backend/src/` | TypeScript REST API and realtime WebSocket gateway |
| `backend/test/` | Backend unit and integration tests (Vitest) |
| `backend/migrations/` | PostgreSQL schema (golang-migrate) and CQL schema (ScyllaDB) |
| `backend/scripts/` | Migration wrapper, Scylla backfill, live end-to-end smoke test |
| `docs/` | [OpenAPI spec](./docs/api-spec.yaml), [WS protocol](./docs/ws-protocol.md), [architecture](./docs/architecture.md), [gateway scaling](./docs/gateway-scaling.md), [Kafka](./docs/kafka.md), [ScyllaDB](./docs/scylla.md), [E2EE](./docs/e2ee.md), [realtime logs](./docs/logging.md), [release](./docs/release.md) |
| `docker-compose.yml` | PostgreSQL 16, Redis 7, MinIO, Kafka, ScyllaDB, API, gateway, migration runner |
| `.github/workflows/ci.yml` | Migrations, backend tests, contract, and Flutter checks |

## Quick start

```bash
cp .env.example .env
make up-all         # infrastructure + migrations + API + gateway
```

Then, for the Android client:

```bash
make mobile-get
make mobile-gen
make mobile-run
```

To run the backend on the host instead of in Docker:

```bash
make up                  # PostgreSQL, Redis, MinIO only
make migrate-up          # applies 000001 .. 000007
make backend-install
cd backend && npm run dev:rest      # REST on :8080
cd backend && npm run dev:gateway   # WebSocket gateway on :8081
```

`make smoke` drives a full REST + WebSocket flow (register, chat, ack, sync,
profiles, friends, proxied media, log ingestion) against a running stack.
`make help` lists every target.

### Live log dashboard

`rest` and `gateway` feed one Redis buffer with a hard 1-hour retention. Open
**`http://<host>:<api-port>/logs`** to watch it live over SSE — with the default
compose stack that is [http://localhost:8080/logs](http://localhost:8080/logs)
(use the host's LAN IP when inspecting from another machine). Logs are also
readable as JSON at `GET /api/v1/logs?level=warn&q=socket`. See
[docs/logging.md](./docs/logging.md).

### Physical Android device on a LAN

The release network policy blocks cleartext HTTP, so a LAN build is a **debug**
APK built with the host's IP baked in:

```bash
# host LAN IP, e.g. 192.168.1.20
make mobile-apk \
  API_BASE_URL=http://192.168.1.20:8080 \
  WS_BASE_URL=ws://192.168.1.20:8081
# -> mobile/build/app/outputs/flutter-apk/app-debug.apk
```

Install it with `adb install -r mobile/build/app/outputs/flutter-apk/app-debug.apk`.
Uploads and downloads are proxied through the API, so only the API and gateway
ports need to be reachable — MinIO's port 9000 does not have to be exposed.
For a production `--release` build, use an HTTPS/WSS endpoint instead and
override `MODE=release`. Full details in [mobile/README.md](./mobile/README.md).

### Verification

```bash
make verify          # migrations, backend typecheck/build/test, Flutter analyze/test
make migrations-check
```

### Phase 4 infrastructure

Kafka and ScyllaDB are opt-in so the default stack stays lightweight:

```bash
make up-scale                 # adds Kafka and ScyllaDB (CQL schema applied)
make backfill-scylla          # mirror existing messages into ScyllaDB
```

Then set `BROKER=kafka` and/or `MESSAGE_STORE=scylla` in `.env` and restart the
backend. See [docs/kafka.md](./docs/kafka.md) and [docs/scylla.md](./docs/scylla.md).

## Testing

```bash
make backend-test    # Vitest: auth, conversations, seq allocation, gateway, E2EE, broker
make mobile-test     # Drift outbox/cursors, E2EE, models, auth widgets
make mobile-analyze
make verify          # everything above, plus migrations, backend build, and typecheck
```

Backend integration tests need a reachable PostgreSQL and Redis; CI provisions
both as service containers and applies migrations first. Local runs read
`DATABASE_URL` / `REDIS_URL`, so either export the values from `.env` or use the
`make` targets, which load them for you:

```bash
set -a && . ./.env && set +a
make backend-test
```

Kafka and Scylla suites skip themselves unless their endpoint is configured:

```bash
KAFKA_BROKERS=localhost:9092 SCYLLA_TEST=1 make backend-test
```

## Multi-account isolation & Clear Data

- **Account switching on one device:** Signing out retains your isolated local
  database (`no_backup/accounts/<accountId>/`) and per-account E2EE keys
  (`acct.<accountId>.*`) so signing back in restores your encrypted history and
  silently syncs missed messages. Signing in as a different account opens an
  isolated partition with zero cross-account visibility.
- **Clear chat / Clear all chats (Settings → Privacy & Storage):** Clears local
  messages and cached media and advances your server-side `cleared_seq`
  watermark so cleared history never re-syncs, while keeping your sign-in and
  E2EE keys intact.
- **Sign out & remove my data / Android Clear Storage:** Permanently wipes local
  history, media cache, and encryption keys. **Encrypted direct-chat history is
  intentionally not restored on a new or cleared device** — rotating your
  identity key on re-login automatically advances direct-chat watermarks on the
  server so old unreadable ciphertexts are never re-synced as stubs.

## Status

- [x] **Phase 0** — monorepo, Docker stack, core schema, Flutter foundation, API/WS contracts, CI
- [x] **Phase 1** — 1:1 chat MVP with offline sync and push notifications
- [x] **Phase 2** — groups, read receipts, media sharing
- [x] **Phase 3** — presence, message search, multi-device sync
- [x] **Phase 4** — Kafka transport, ScyllaDB message store, gateway draining, E2EE, Android release hardening
- [x] **Phase 5** — people directory, user profiles, bottom navigation
- [x] **Phase 6** — end-to-end smoke coverage (profiles, friends, proxied media, logs), deployment hardening, full verification suite
