# Architecture

CP Chat is a monorepo containing the Flutter Android client, the backend
services, the database migrations, and the shared API/WebSocket contracts.

```
.
├── docker-compose.yml        # PostgreSQL 16, Redis 7, MinIO, API, gateway
├── backend/
│   ├── src/
│   │   ├── rest.ts           # REST entry point (:8080)
│   │   ├── gateway.ts        # WebSocket entry point (:8081)
│   │   ├── http/             # Fastify routes, auth guard, error mapping
│   │   ├── gateway/          # Chat gateway + Redis connection registry
│   │   ├── domain/           # Repositories (users, conversations, messages)
│   │   └── lib/              # DB, Redis, JWT, password, FCM helpers
│   ├── test/                 # Vitest unit + integration suites
│   ├── migrations/           # golang-migrate SQL migrations
│   └── scripts/              # Migration wrapper, live smoke test
├── docs/                     # OpenAPI + WebSocket contracts
└── mobile/                   # Flutter Android app
```

The REST API and the chat gateway are separate processes built from the same
TypeScript sources. They share the database, Redis, and configuration, and are
deployed and scaled independently: the REST API is stateless, while each gateway
node holds a subset of live sockets.

## Components

| Component | Responsibility | State |
| --- | --- | --- |
| API Gateway | TLS termination, routing, rate limiting | Stateless |
| Auth Service | Registration, login, access/refresh token issuance | Stateless |
| User/Group Service | Profiles, contacts, groups, membership | Stateless |
| Chat Gateway | WebSocket termination, per-user connection routing | Stateful |
| Message Service | Validation, `seq` allocation, persistence, fan-out | Stateless |
| Media Service | Pre-signed S3/MinIO URLs, MIME and size enforcement | Stateless |
| Notification Service | FCM pushes for offline recipients | Stateless |

## Data flow: sending a message

1. Flutter persists the message locally with `status = pending` and a generated
   `client_msg_id`, then writes a `send` frame to the Chat Gateway.
2. The gateway authenticates the connection, checks that the user is a member of
   the conversation (cached in Redis), and forwards the message to the Message
   Service.
3. The Message Service allocates the next per-conversation `seq` inside a
   transaction, inserts the row (deduplicating on `client_msg_id`), and returns
   it.
4. Fan-out uses Redis Pub/Sub: the destination gateway node (from
   `conn:{user_id}:{device_id}`) pushes a `message` event to the recipient's
   socket.
5. The sender receives a `status: sent` event with the assigned `seq`. If the
   recipient has no live connection, the Notification Service sends an FCM push
   and delivery resumes via sync on next connect.

## Redis keys

| Key | Type | Purpose |
| --- | --- | --- |
| `conn:{user_id}:{device_id}` | string + TTL | Gateway node holding that device's socket |
| `conns:{user_id}` | set + TTL | Device ids with a socket, for fan-out without `SCAN` |
| `presence:{user_id}` | string + TTL 45 s | Online status (refreshed by heartbeat) |
| `gw:{node_id}` | pub/sub channel | Fan-out to sockets owned by another gateway node |
| `members:{conversation_id}` | set | Reserved for Phase 2 group membership caching |
| `ratelimit:{user_id}` | counter | Reserved for Phase 4 rate limiting |

Both `conn:` keys carry a TTL refreshed by the heartbeat, so a crashed node
stops receiving fan-out within `CONNECTION_TTL_SECONDS` instead of black-holing
messages forever.

## Storage

- **PostgreSQL 16** is the source of truth. `messages` is uniquely keyed by
  `(conversation_id, seq)`; pagination always uses `seq`, never timestamps.
- **MinIO** (S3-compatible) stores uploaded media. Only URLs are stored in
  `messages.content`. The Compose stack pins a verified community mirror of
  MinIO `RELEASE.2025-09-07` by digest, because MinIO no longer publishes
  official images to Docker Hub; API, console, and `mc` are unchanged.
- **Drift/SQLite** on the device mirrors conversations and messages, plus an
  outbox table for unsent messages.

## Client structure

```
mobile/lib/
├── main.dart
├── core/
│   ├── config/         # Environment endpoints (10.0.2.2 for emulators)
│   ├── network/        # Dio REST client, WebSocket manager
│   ├── database/       # Drift tables and DAOs (messages, conversations, outbox)
│   ├── notifications/  # FCM handlers
│   └── storage/        # flutter_secure_storage token store
└── features/
    ├── auth/           # Login, register, token refresh
    ├── conversations/  # Chat list, unread badges
    ├── chat/           # Message stream, optimistic UI, outbox retry
    ├── groups/         # Group creation and membership
    └── presence/       # Online indicators
```

State management is Riverpod; providers live next to the feature they serve.

## Local development

```bash
cp .env.example .env
make up            # PostgreSQL, Redis, MinIO (bucket bootstrapped by minio-init)
make migrate-up    # create schema
make mobile-run    # launch on an Android emulator/device
```

The Android emulator reaches the host through `10.0.2.2`, so the client defaults
to `http://10.0.2.2:8080` (REST) and `ws://10.0.2.2:8081/ws` (gateway). On a
physical device over USB, run `adb reverse tcp:8080 tcp:8080` and
`adb reverse tcp:8081 tcp:8081`.

## Scaling path

Phases are designed so each shortcut has a documented upgrade: PostgreSQL →
Cassandra/ScyllaDB, Redis Pub/Sub → Kafka, single `user_id -> node` routing →
`user_id -> set(device, node)`, and fan-out-on-write → hybrid fan-out for very
large groups. Details and phase boundaries live in `AGENTS.MD`.
