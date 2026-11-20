# CP Chat — 1:1 & Group Chat Application (Flutter Android)

A scalable, low-latency 1:1 and group messaging application built with a **Flutter (Android)** mobile client and a distributed, WebSocket-driven backend architecture.

This repository serves as the complete foundation and phased development roadmap—taking the project from initial repository setup to a production-ready messaging platform.

---

## Table of Contents

1. [System Requirements](#1-system-requirements)
2. [High-Level Architecture](#2-high-level-architecture)
3. [Technology Stack](#3-technology-stack)
4. [Data Model & Messaging Protocol](#4-data-model--messaging-protocol)
5. [Repository Structure](#5-repository-structure)
6. [Getting Started (Local Development)](#6-getting-started-local-development)
7. [Phased Development Roadmap](#7-phased-development-roadmap)
8. [Architectural Trade-offs](#8-architectural-trade-offs)
9. [Reliability & Security Guidelines](#9-reliability--security-guidelines)

---

## 1. System Requirements

### Functional Requirements
- **1:1 & Group Messaging:** Send and receive text, images, and files in real time.
- **Message Delivery States:** Track message lifecycle (`sent`, `delivered`, `read`).
- **Chat History & Sync:** Persist chat history on the server and synchronize seamlessly on reconnect or new devices.
- **Offline Push Notifications:** Deliver instant Android push notifications via Firebase Cloud Messaging (FCM) when users are offline or backgrounded.
- **Presence System:** Display online status and "last seen" timestamps.
- **Group Management:** Create groups, add/remove members, and leave groups (supports up to 500 members per group).

### Non-Functional Requirements
- **Low Latency:** End-to-end message delivery under 200 ms for online users.
- **Zero Message Loss & Strict Ordering:** Messages must never be lost and must render in exact sequential order regardless of device clock skew.
- **High Availability & Horizontal Scalability:** Stateless APIs, horizontally scalable stateful WebSocket gateways, and fault-tolerant storage.

---

## 2. High-Level Architecture

```text
 ┌─────────────────┐   HTTPS (REST)    ┌──────────────┐
 │ Flutter Android │ ----------------> │ API Gateway  |---> Auth Service
 │     Client      │                   │ / Load Bal.  |---> User/Group Service
 └────────┬────────┘                   └──────────────┘---> Media Service ---> Object Storage (S3/MinIO)
          │ WebSocket (WSS)
          v
 ┌─────────────────┐    ┌────────────────┐    ┌───────────────────┐
 │  Chat Gateway   |<-->│ Message Broker │<-->│  Message Service  │
 │  (Stateful,     │    │ (Redis Pub/Sub │    │ (Validate, Store, │
 │   Multi-Node)   │    │   -> Kafka)    │    │     Fan-out)      │
 └────────┬────────┘    └────────────────┘    └─────────┬─────────┘
          │                                             │
          v                                             v
 ┌─────────────────┐                    ┌────────────────────────────┐
 │      Redis      │                    │ DB: Users, Groups, Messages│
 │   (Presence,    │                    │ (PostgreSQL -> Cassandra)  │
 │  Conn Routing)  │                    └────────────────────────────┘
 └─────────────────┘                                    │
                                                        v
                                          Notification Service ---> FCM (Android)
```

### Core Backend Components
- **Chat Gateway:** Maintains persistent WebSocket connections. Each stateful node holds active user sockets, while Redis stores the `user_id -> gateway_node` routing map so incoming messages reach the exact node holding the recipient's connection.
- **Message Service:** Validates sender permissions, assigns monotonic per-conversation sequence numbers (`seq`), persists messages to the database, and routes payloads to recipients.
- **Message Broker:** Decouples message ingestion from delivery so traffic spikes do not overwhelm gateway nodes.
- **User/Group Service:** Manages user profiles, contacts, group creation, and membership roles.
- **Media Service:** Generates pre-signed URLs so the Flutter Android client uploads images/files directly to Object Storage (S3/MinIO). Messages only store the resulting media URL/ID.
- **Notification Service:** Triggers FCM push notifications for offline recipients.
- **Redis:** Powers presence tracking (TTL + heartbeats), WebSocket routing maps, and group membership caching.

---

## 3. Technology Stack

### Mobile Client (Flutter Android)
- **Framework:** Flutter (Dart) targeting Android (Min SDK 24 / Android 7.0+)
- **State Management:** Riverpod or BLoC
- **Networking:** `dio` (REST + JWT interceptors) & `web_socket_channel` (WebSocket with exponential backoff reconnect)
- **Local Persistence (Offline-First):** `drift` (SQLite) for local message caching, pending outbox queue, and `seq`-based sync
- **Secure Storage:** `flutter_secure_storage` (Android Keystore for JWT access/refresh tokens)
- **Push Notifications:** `firebase_core` & `firebase_messaging` (FCM)
- **Media Handling:** `image_picker`, `file_picker`, `cached_network_image`, `flutter_image_compress`

### Backend & Infrastructure
- **Services:** Go (recommended for high-concurrency WebSocket gateways) or Node.js (TypeScript)
- **Primary Database:** PostgreSQL (MVP -> Growth), with a migration path to Cassandra/ScyllaDB for massive scale
- **Cache & Pub/Sub:** Redis (MVP), migrating broker to Apache Kafka at scale
- **Object Storage:** MinIO (local dev) / AWS S3 or GCS (production)
- **Local Orchestration:** Docker & Docker Compose

---

## 4. Data Model & Messaging Protocol

### Unified Database Schema
Both 1:1 and group chats share the exact same schema—a 1:1 chat is simply a `conversation` of type `direct` with 2 members.

```sql
users (
    id UUID PRIMARY KEY,
    phone_or_email VARCHAR UNIQUE NOT NULL,
    name VARCHAR NOT NULL,
    avatar_url TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

conversations (
    id UUID PRIMARY KEY,
    type VARCHAR(10) NOT NULL CHECK (type IN ('direct', 'group')),
    name VARCHAR,
    created_by UUID REFERENCES users(id),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

conversation_members (
    conversation_id UUID REFERENCES conversations(id),
    user_id UUID REFERENCES users(id),
    role VARCHAR(10) NOT NULL CHECK (role IN ('admin', 'member')),
    last_read_seq BIGINT DEFAULT 0,
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (conversation_id, user_id)
);

messages (
    id UUID PRIMARY KEY,
    conversation_id UUID REFERENCES conversations(id),
    seq BIGINT NOT NULL,
    sender_id UUID REFERENCES users(id),
    client_msg_id UUID NOT NULL,
    type VARCHAR(10) NOT NULL CHECK (type IN ('text', 'image', 'file')),
    content TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (conversation_id, seq),
    UNIQUE (sender_id, client_msg_id)
);

message_receipts (
    message_id UUID REFERENCES messages(id),
    user_id UUID REFERENCES users(id),
    status VARCHAR(10) NOT NULL CHECK (status IN ('delivered', 'read')),
    ts TIMESTAMPTZ DEFAULT NOW(),
    PRIMARY KEY (message_id, user_id)
);
```

#### Key Design Decisions
- **Ordering via `seq`:** Sequence numbers are generated per conversation (instead of relying on client timestamps), guaranteeing consistent ordering even if device clocks differ.
- **Idempotency via `client_msg_id`:** Generated as a UUIDv4 on the Flutter client before sending. If a network drop triggers a retry, the unique constraint `(sender_id, client_msg_id)` prevents duplicate messages.
- **Efficient Group Receipts:** Tracking `last_read_seq` per member in `conversation_members` avoids writing millions of individual `message_receipts` rows in large groups.

### Client-Server Protocol

#### REST API Endpoints
- `POST /api/v1/auth/register` & `POST /api/v1/auth/login`
- `POST /api/v1/devices/fcm-token` (Register Android FCM token)
- `GET /api/v1/conversations` (Fetch chat list with unread counts)
- `POST /api/v1/conversations` (Create 1:1 or group conversation)
- `POST /api/v1/conversations/{id}/members` & `DELETE /api/v1/conversations/{id}/members/{userId}`
- `GET /api/v1/conversations/{id}/messages?before_seq={seq}&limit=50` (Pagination)
- `GET /api/v1/conversations/{id}/sync?after_seq={last_seq}` (Offline catch-up sync)
- `POST /api/v1/media/presign` (Get pre-signed S3 upload URL)

#### WebSocket Events (JSON)

```json
// Client -> Server: Send a new message
{
  "type": "send",
  "conversation_id": "c1",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "msg_type": "text",
  "content": "Hello!"
}

// Client -> Server: Acknowledge delivery or read cursor
{
  "type": "ack",
  "conversation_id": "c1",
  "seq": 42,
  "status": "delivered"
}

// Server -> Client: Deliver incoming message
{
  "type": "message",
  "conversation_id": "c1",
  "seq": 42,
  "sender_id": "u1",
  "msg_type": "text",
  "content": "Hello!",
  "created_at": "2026-11-20T08:00:00Z"
}

// Server -> Client: Update message status (sent / delivered / read)
{
  "type": "status",
  "conversation_id": "c1",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "seq": 42,
  "status": "read"
}
```

---

## 5. Repository Structure

A monorepo structure keeps the Flutter Android client, backend services, database migrations, and shared contracts synchronized.

```text
cp-chat/
├── README.md
├── docker-compose.yml              # Local PostgreSQL, Redis, MinIO
├── .github/
│   └── workflows/                  # CI pipelines (Flutter test/build APK, Backend lint/test)
├── docs/
│   ├── architecture.md
│   ├── api-spec.yaml               # OpenAPI 3.0 specification
│   └── ws-protocol.md              # WebSocket event contracts
├── backend/
│   ├── migrations/                 # SQL migrations (golang-migrate / prisma / goose)
│   ├── services/
│   │   ├── api-gateway/
│   │   ├── auth-service/
│   │   ├── user-group-service/
│   │   ├── chat-gateway/           # Stateful WebSocket server
│   │   ├── message-service/        # Seq generator, persistence, fan-out
│   │   ├── media-service/          # Pre-signed URL generator
│   │   └── notification-service/   # Firebase Admin SDK (FCM)
│   └── shared/                     # Common DTOs, JWT middleware, Redis helpers
└── mobile/                         # Flutter Android Application
    ├── pubspec.yaml
    ├── android/
    │   ├── app/
    │   │   ├── build.gradle        # Min SDK 24+, Firebase plugin config
    │   │   ├── google-services.json # (Git-ignored in prod; template provided)
    │   │   └── src/main/AndroidManifest.xml
    └── lib/
        ├── main.dart
        ├── core/
        │   ├── network/            # Dio REST client & WebSocket manager
        │   ├── database/           # Drift (SQLite) local tables & DAOs
        │   ├── notifications/      # FCM foreground/background handlers
        │   └── storage/            # Secure JWT storage
        └── features/
            ├── auth/               # Login, Register, Token refresh
            ├── conversations/      # Chat list, Unread badges, Search
            ├── chat/               # 1:1 & Group message stream, Outbox retry, Media bubbles
            ├── groups/             # Create group, Add/remove members
            └── presence/           # Online indicator & last seen
```

---

## 6. Getting Started (Local Development)

### Prerequisites
- **Git**
- **Docker & Docker Compose** (for PostgreSQL, Redis, MinIO)
- **Flutter SDK** (3.x stable channel)
- **Android Studio** with Android SDK & Emulator (or a physical Android device with USB Debugging enabled)
- **Firebase Project** (for Android FCM testing)

### Step 1: Initialize the Repository

```bash
mkdir cp-chat && cd cp-chat
git init
mkdir -p backend/migrations backend/services docs
```

### Step 2: Bootstrap the Flutter Android Client

```bash
flutter create --org com.cpchat --platforms=android mobile
cd mobile
flutter pub add dio web_socket_channel drift sqlite3_flutter_libs path_provider \
  flutter_riverpod flutter_secure_storage uuid firebase_core firebase_messaging \
  image_picker file_picker cached_network_image
flutter pub add --dev drift_dev build_runner
```

### Step 3: Configure Android Specifics
1. **Permissions (`mobile/android/app/src/main/AndroidManifest.xml`):**
   - Add `android.permission.INTERNET`
   - Add `android.permission.POST_NOTIFICATIONS` (required for Android 13+ / API 33+)
2. **Firebase (FCM):**
   - Register your Android package name (`com.cpchat.mobile`) in the Firebase Console.
   - Download `google-services.json` and place it in `mobile/android/app/`.
   - Enable the Google Services Gradle plugin in `android/settings.gradle` and `android/app/build.gradle`.
3. **Localhost Networking on Android Emulator:**
   - Use `10.0.2.2` instead of `localhost` when connecting from the Android Emulator to your local backend (e.g., `http://10.0.2.2:8080` and `ws://10.0.2.2:8081/ws`), or run `adb reverse tcp:8080 tcp:8080` when testing on a physical device via USB.

### Step 4: Start Local Infrastructure

Create a `docker-compose.yml` in the root directory with PostgreSQL 16, Redis 7, and MinIO, then start the stack:

```bash
docker compose up -d
```

### Step 5: Run the Flutter Android App

```bash
cd mobile
flutter run -d android
```

---

## 7. Phased Development Roadmap

Follow these phases sequentially. **By the end of Phase 1, you will have a working, usable 1:1 Android chat app.**

### Phase 0: Repository Setup & Foundations (Week 1)
**Goal:** Establish a clean development environment, CI checks, and shared contracts.
- [x] Initialize monorepo structure (`mobile/`, `backend/`, `docs/`).
- [x] Configure `docker-compose.yml` (PostgreSQL, Redis, MinIO).
- [x] Set up initial SQL migration runner and create core tables (`users`, `conversations`, `conversation_members`, `messages`).
- [x] Scaffold Flutter Android project with Riverpod, Drift local DB, and Android Studio emulator workflow.
- [x] Define OpenAPI & WebSocket JSON contract docs in `/docs`.

---

### Phase 1: MVP — Working 1:1 Chat & Push Notifications (Weeks 2–4)
**Goal:** End-to-end usable 1:1 text messaging on Android with offline sync and push notifications.

#### Backend Tasks
- [x] **Auth Service:** Implement user registration, login, and JWT issuance (access + refresh tokens).
- [x] **Chat Gateway (WebSocket):** Authenticate WebSocket upgrades via JWT; register `user_id -> gateway_node` in Redis upon connect and remove on disconnect.
- [x] **Message Service:**
  - Validate conversation membership.
  - Generate per-conversation `seq` atomically (e.g., PostgreSQL transaction/counter or Redis `INCR` backed by DB).
  - Persist message with `client_msg_id` deduplication.
  - Return `sent` ACK to sender.
  - Route message via Redis Pub/Sub to the recipient's Chat Gateway node.
- [x] **Offline Sync API:** Implement `GET /conversations/{id}/sync?after_seq=...`.
- [x] **Notification Service:** Integrate Firebase Admin SDK to push FCM alerts when recipient has no active gateway mapping in Redis.

#### Flutter Android Tasks
- [x] Build Login/Register screens and persist JWT in `flutter_secure_storage`.
- [x] Set up Drift (SQLite) local tables mirroring `conversations` and `messages` (including local `pending`/`failed` status for outbox retries).
- [x] Implement resilient WebSocket client with auto-reconnect (exponential backoff) and automatic `sync` call on reconnect.
- [x] Build Chat List screen and 1:1 Chat screen with optimistic UI (show message immediately with clock icon -> single check on `sent` ACK -> double check on `delivered`).
- [x] Integrate `firebase_messaging` for Android background/terminated notification handling and deep-linking into the specific chat screen.

> **Implementation notes:** the backend is TypeScript (`backend/`, Fastify REST on
> `:8080` + `ws` gateway on `:8081`). 1:1 conversations are canonicalised by a
> `direct_key` unique index so creating the same chat twice returns the existing
> row. `seq` is allocated from `conversations.last_seq` inside the insert
> transaction, which keeps it gap-free even when a retried `client_msg_id`
> dedupes. Refresh tokens are opaque, hashed at rest, and rotated with reuse
> detection. `mobile/test` covers the Drift outbox and cursor logic; backend
> tests are in `backend/test`.

> **Milestone 1 (Usable App):** Two Android devices can register, start a 1:1 chat, exchange messages in real time (< 200 ms), receive FCM push notifications when offline, and sync missed messages upon reopening the app.

---

### Phase 2: Group Chat, Read Receipts & Media Sharing (Weeks 5–7)
**Goal:** Upgrade from MVP to a full-featured daily-driver messenger supporting groups up to 500 members and rich media.

#### Backend Tasks
- [ ] **Group Management APIs:** Create group, update name/avatar, add/remove members (enforce max 500 member limit), leave group, admin role validation.
- [ ] **Fan-out on Write:** Cache group member lists in Redis. When a message hits a group conversation, store the message once, then fan-out to all online members via their respective gateways and dispatch FCM to offline members.
- [ ] **Read Receipts:** Update `last_read_seq` in `conversation_members` on `read` events; broadcast read status updates (individual status for 1:1, aggregated read count for groups).
- [ ] **Media Service:** Implement `POST /media/presign` returning short-lived S3/MinIO PUT URLs and public/signed GET URLs. Enforce MIME type and file size limits.

#### Flutter Android Tasks
- [ ] Build Create Group & Group Info/Member Management screens.
- [ ] Implement read receipt triggers when the user scrolls to the bottom of an open chat (`last_read_seq`).
- [ ] Display "Read by N" counter in group chats and colored double-ticks in 1:1 chats.
- [ ] Integrate `image_picker`, `file_picker`, and `flutter_image_compress`:
  1. Compress image locally on Android.
  2. Request pre-signed URL from Media Service.
  3. Upload binary directly to S3/MinIO with progress bar.
  4. Send WebSocket message with `msg_type: "image" | "file"` and media URL.
- [ ] Render image thumbnails (`cached_network_image`) and downloadable file attachments.

> **Milestone 2 (Feature Complete):** Users can chat in groups (up to 500 members), share images/files reliably, and see accurate read receipts.

---

### Phase 3: Presence, Message Search & Multi-Device Sync (Weeks 8–10)
**Goal:** Polish user experience and support seamless synchronization across multiple devices.

#### Backend Tasks
- [ ] **Presence Service:** Implement WebSocket heartbeat ping every 20–30s refreshing a Redis key `presence:{user_id}` with a 45s TTL; persist `last_seen_at` to DB on expiry/disconnect.
- [ ] **Message Search:** Add PostgreSQL full-text search (`tsvector` + GIN index) or integrate Meilisearch/Elasticsearch for fast conversation history search.
- [ ] **Multi-Device Support:** Update Redis routing map from `user_id -> single_node` to `user_id -> Set<(device_id, gateway_node)>` so messages and read cursors sync across all logged-in devices simultaneously.

#### Flutter Android Tasks
- [ ] Display live "Online" badge and formatted "Last seen..." subtitle in chat headers.
- [ ] Add in-chat and global search bars.
- [ ] Handle self-sent message events arriving over WebSocket (sent from another device) and sync `last_read_seq` across devices to clear unread badges automatically.

---

### Phase 4: High Scale, Reliability & Security Hardening (Weeks 11+)
**Goal:** Prepare the architecture for high concurrency, strict privacy, and Google Play Store production deployment.

- [ ] **Broker Upgrade:** Migrate inter-service messaging from Redis Pub/Sub to **Apache Kafka** (partitioned by `conversation_id`) for durable event streaming and consumer group scaling.
- [ ] **Storage Migration:** Migrate high-volume `messages` table from PostgreSQL to **Cassandra or ScyllaDB** using `conversation_id` as the partition key and `seq DESC` as the clustering key for ultra-fast recent message reads.
- [ ] **Gateway Scaling:** Deploy multiple Chat Gateway replicas behind a load balancer configured with consistent hashing / sticky sessions and graceful WebSocket draining during deployments.
- [ ] **End-to-End Encryption (E2EE):** Implement Signal Protocol / Letter Sealing style key exchange (identity keys, pre-keys) on the Flutter client so the server only relays ciphertext.
- [ ] **Android Production Release:**
  - Configure ProGuard/R8 shrinking and obfuscation (`minifyEnabled true`).
  - Set up Android App Bundle (`.aab`) signing and Play Store internal testing track.
  - Add Crashlytics/Sentry monitoring and OpenTelemetry backend tracing.

---

## 8. Architectural Trade-offs

| Decision Area | Simple Choice (Phase 1–2) | Large-Scale Choice (Phase 4+) |
| :--- | :--- | :--- |
| **Message Storage** | PostgreSQL | Cassandra / ScyllaDB (`PK: conversation_id`) |
| **Message Broker** | Redis Pub/Sub | Apache Kafka |
| **Group Fan-out** | Fan-out on write (up to 500 members) | Hybrid (Fan-out on read for huge channels) |
| **Group Read Receipts** | Aggregated read count (`last_read_seq`) | Detailed per-member receipt log (opt-in) |

---

## 9. Reliability & Security Guidelines

- **Delivery Guarantee:** At-least-once delivery combined with strict client-generated `client_msg_id` deduplication. The Flutter client stores unsent messages in a local SQLite outbox and retries with exponential backoff until a server `sent` ACK arrives.
- **Transport & Auth Security:** Enforce TLS (`HTTPS` / `WSS`) on all endpoints, short-lived JWT access tokens with refresh token rotation, and certificate pinning on Android for production builds.
- **Abuse Prevention:** Apply Redis-backed token-bucket rate limiting at the API Gateway and Chat Gateway (e.g., max messages per second per user).
- **Data Protection:** Encrypt database volumes and S3 buckets at rest; never log raw message contents in server logs.