# CP Chat

**CP Chat** — A scalable, low-latency 1:1 & group messaging application built with Flutter (Android) and a distributed WebSocket-driven backend architecture.

A complete foundation and phased development roadmap for building a production-ready messaging platform with real-time message delivery, offline sync, push notifications, and group management.

For detailed architecture, technology stack, and development phases, see [AGENTS.MD](./AGENTS.MD).

## Repository layout

| Path | Contents |
| --- | --- |
| `mobile/` | Flutter Android client (Riverpod, Drift, secure storage, WebSocket client) |
| `backend/src/` | TypeScript REST API and realtime WebSocket gateway |
| `backend/test/` | Backend unit and integration tests (Vitest) |
| `backend/migrations/` | SQL schema managed with golang-migrate |
| `backend/scripts/` | Migration wrapper and live end-to-end smoke test |
| `docs/` | [OpenAPI spec](./docs/api-spec.yaml), [WebSocket protocol](./docs/ws-protocol.md), [architecture](./docs/architecture.md) |
| `docker-compose.yml` | PostgreSQL 16, Redis 7, MinIO, API, chat gateway, migration runner |
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

## Testing

```bash
make backend-test    # Vitest: auth, conversations, seq allocation, gateway
make mobile-test     # Drift outbox/cursors, models, auth widgets
make mobile-analyze
```

Backend integration tests need a reachable PostgreSQL and Redis; CI provisions
both as service containers and applies migrations first.

## Status

- [x] **Phase 0** — monorepo, Docker stack, core schema, Flutter foundation, API/WS contracts, CI
- [x] **Phase 1** — 1:1 chat MVP with offline sync and push notifications
- [ ] **Phase 2** — groups, read receipts, media sharing
- [ ] **Phase 3** — presence, search, multi-device sync
- [ ] **Phase 4** — scale, reliability, security hardening
