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
make migrate-up
make backend-install
cd backend && npm run dev:rest      # REST on :8080
cd backend && npm run dev:gateway   # WebSocket gateway on :8081
```

`make smoke` drives a full REST + WebSocket flow (register, chat, ack, sync)
against a running stack. `make help` lists every target.

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
```

Backend integration tests need a reachable PostgreSQL and Redis; CI provisions
both as service containers and applies migrations first. Kafka and Scylla suites
skip themselves unless their endpoint is configured:

```bash
KAFKA_BROKERS=localhost:9092 SCYLLA_TEST=1 make backend-test
```

## Status

- [x] **Phase 0** — monorepo, Docker stack, core schema, Flutter foundation, API/WS contracts, CI
- [x] **Phase 1** — 1:1 chat MVP with offline sync and push notifications
- [x] **Phase 2** — groups, read receipts, media sharing
- [x] **Phase 3** — presence, message search, multi-device sync
- [x] **Phase 4** — Kafka transport, ScyllaDB message store, gateway draining, E2EE, Android release hardening
