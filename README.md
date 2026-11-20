# CP Chat

**CP Chat** — A scalable, low-latency 1:1 & group messaging application built with Flutter (Android) and a distributed WebSocket-driven backend architecture.

A complete foundation and phased development roadmap for building a production-ready messaging platform with real-time message delivery, offline sync, push notifications, and group management.

For detailed architecture, technology stack, and development phases, see [AGENTS.MD](./AGENTS.MD).

## Repository layout

| Path | Contents |
| --- | --- |
| `mobile/` | Flutter Android client (Riverpod, Drift, secure storage, WebSocket client) |
| `backend/migrations/` | SQL schema managed with golang-migrate |
| `backend/scripts/` | Migration wrapper used by Compose |
| `docs/` | [OpenAPI spec](./docs/api-spec.yaml), [WebSocket protocol](./docs/ws-protocol.md), [architecture](./docs/architecture.md) |
| `docker-compose.yml` | PostgreSQL 16, Redis 7, MinIO, migration runner |
| `.github/workflows/ci.yml` | Migration, contract, and Flutter checks |

## Quick start

```bash
cp .env.example .env
make up            # start PostgreSQL, Redis, MinIO
make migrate-up    # create the schema
cd mobile
flutter pub get
dart run build_runner build
flutter run -d android
```

`make help` lists every target. Backend services are added in Phase 1; the
contracts they implement are already frozen in `docs/`.

## Status

- [x] **Phase 0** — monorepo, Docker stack, core schema, Flutter foundation, API/WS contracts, CI
- [ ] **Phase 1** — 1:1 chat MVP with offline sync and push notifications
- [ ] **Phase 2** — groups, read receipts, media sharing
- [ ] **Phase 3** — presence, search, multi-device sync
- [ ] **Phase 4** — scale, reliability, security hardening
