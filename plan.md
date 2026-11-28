# CP Chat — 1-on-1 & Group Voice/Video Calling Plan (Self-Hosted LiveKit)

Implementation blueprint for adding **1-on-1 and Group Voice/Video Calls** (with mid-call video toggle) to CP Chat using a **self-hosted LiveKit SFU** co-located on this server, backend orchestration inside `backend/`, and Android client integration inside `mobile/`.

> **Build Policy (`AGENTS.MD` Rule 0):** Never run `flutter build apk`, `flutter build appbundle`, `make mobile-apk`, or Gradle `assemble*`/`bundle*` in automated or agent verification. Verify via `make migrations-check`, `cd backend && npm run typecheck && npm test`, `cd mobile && flutter analyze && flutter test`, and live device runs via `flutter run -d android`.

---

## 1. Scope & Assumptions

### 1.1 Grounded Repository Baseline
- **Backend (`backend/`):** Node.js `>=22` (ESM TypeScript), Fastify 5 (`src/rest.ts`, `:8080`), `ws` gateway (`src/gateway.ts`, `:8081`), PostgreSQL 16 (`pg`), Redis 7 (`ioredis`), `firebase-admin` v14 (addressing Android installs by **Firebase Installation ID / FID** via `device_tokens.fcm_token` + `push_version >= 2` data-only payloads), `Broker` abstraction (`RedisBroker` default / `KafkaBroker` Phase 4). Migrations live in `backend/migrations/` (`000001`–`000010`).
- **Infrastructure (`docker-compose.yml`):** `postgres`, `redis`, `minio`, `minio-init`, `migrate` (`tools` profile), `api`, `gateway` (plus optional `kafka`/`scylla` profiles). No reverse proxy container or systemd unit is committed yet; `docs/gateway-scaling.md` documents Nginx as the reference reverse proxy.
- **Mobile (`mobile/`):** Flutter (Dart `^3.14.0`, Android-only), Riverpod 3 (`flutter_riverpod ^3.5.0`), GoRouter (`^18.1.4`), Dio (`^5.11.1`), `web_socket_channel` (`^3.0.3`), Drift v6 (`^2.35.4`), `firebase_messaging` (`^17.1.0`), `flutter_local_notifications` (`^23.0.4`), strict per-account isolation enforced by `accountScopeProvider` and `mobile/test/architecture_guard_test.dart`.
- **Android Config (`mobile/android/app/`):** `com.cpchat.mobile`, `minSdk = 24`, `compileSdk = maxOf(flutter.compileSdkVersion, 37)`, AGP `9.3.1`, Kotlin `2.4.20`, Java 17 + core library desugaring, release R8 (`isMinifyEnabled = true`, `isShrinkResources = true`), `cleartextTrafficPermitted="false"` in release (`network_security_config.xml`).

### 1.2 Behavior Differences: 1-on-1 Calls vs. Group Calls

| Dimension | 1-on-1 Call (`direct` conversation) | Group Call (`group` conversation) |
| :--- | :--- | :--- |
| **Initiation** | Caller creates a `ringing` call record (`media_type`: `voice` \| `video`), receives LiveKit token, joins room, and rings callee across all callee devices. | Caller creates (or atomically joins existing) `active` group call tied to `conversation_id`, receives LiveKit token, and joins room immediately. |
| **Ringing & Push** | Full-screen ringing UI + ringtone on callee (WS + high-priority data-only FCM). Caller hears ringback tone until accepted/rejected/timed out. | Lightweight ring/alert notification ("Alice started a group call in <Group>") + live **"Active Call — Join"** banner in `ChatScreen` and active-call badge in `ConversationsScreen`. No blocking ringback tone for initiator. |
| **Busy State** | If callee is already in any `ringing`/`connecting`/`connected` call, callee auto-rejects with `reason: "busy"` (and server also checks Redis `call:user:{calleeId}` before ringing to return `callee_busy` fast). | Incoming group call alert does **not** interrupt or auto-reject if recipient is on another call; it silently updates the group's active-call banner so they can join later. |
| **Multi-Device** | Rings all callee devices. When Device A accepts or rejects, server sends `call_answered_elsewhere` / `call_ended` (WS + silent FCM `call_cancel`) to callee's other devices to stop ringing immediately. | Joining from one device does not prevent other group members from joining; same user joining from a second device replaces/kicks the prior identity in LiveKit (standard LiveKit `identity = userId` policy, or scoped `userId:deviceId` — **decision: use `identity = userId`** so a user cannot appear twice in the same call). |
| **Late Join** | Not supported once rejected, cancelled, missed, or ended. | Supported for the entire lifetime of the call via `POST /api/v1/calls/:callId/join` from the chat banner or group header. |
| **Mid-Call Video Toggle** | Both voice and video calls allow enabling/disabling camera mid-call by publishing/unpublishing the local video track (no room reconnect required). | Same — any participant can toggle camera on/off mid-call; Simulcast + Dynacast adapt automatically. |
| **DND (`users.status == 'dnd'`)** | Suppresses FCM push and client ringtone/full-screen interrupt (matches existing `NotificationPolicy` / `ChatGateway.maybeNotify`); call still times out as `missed` after 40 s if unanswered. | Suppresses FCM push for DND members; active-call banner still appears when they open the group chat. |
| **Termination Rules** | Ends immediately on: (a) callee reject/busy, (b) caller cancel before answer, (c) **40 s missed timeout** while still `ringing`, (d) either participant hangs up (`POST /leave` deletes LiveKit room), or (e) LiveKit `room_finished` webhook. | One user leaving does **not** end the call. Call stays `active` while `>= 1` participant remains, and ends **only** when the room empties and LiveKit fires `room_finished` (backed by `empty_timeout` / `departure_timeout` and server reconciliation). |
| **Participant Cap** | Strictly 2 members of the `direct` conversation. | Default soft cap of **20 concurrent participants** (configurable via `CALL_MAX_GROUP_PARTICIPANTS=20` in `backend/src/config.ts`, validated at join time) to match single-server SFU CPU/bandwidth capacity; groups up to 500 chat members can still start calls up to this active participant limit. |

### 1.3 Open Questions & Assumptions
1. **LiveKit Domain & TLS:** Assumes a dedicated subdomain `livekit.<domain>` (for HTTPS/WSS signaling on `:443`) and optionally `turn.<domain>` (or reusing `livekit.<domain>` on `:5349/tcp`) with valid CA-signed TLS certificates (e.g., Let's Encrypt via Certbot or Caddy). Android release builds enforce `cleartextTrafficPermitted="false"`, so `wss://` is mandatory outside debug/LAN dev.
2. **Reverse Proxy Location:** Because no reverse proxy exists in `docker-compose.yml` today, this plan assumes Nginx (matching `docs/gateway-scaling.md`) or Caddy runs on the host and already terminates TLS for `api` (`:8080`) and `gateway` (`:8081`).
3. **Server Networking & Firewall:** Assumes this server has a routable public IPv4 (or 1:1 NAT with public IP discoverable via STUN when `rtc.use_external_ip: true`) and root/sudo access to open TCP/UDP firewall ports (`443`, `7881`, `5349`, `3478`, `50000-60000`). If hosted behind a cloud security group (AWS/GCP/Hetzner/DO), those rules must mirror UFW.
4. **Server Hardware Capacity:** Assumes at least 2–4 vCPU and 4 GB RAM shared with Postgres/Redis/MinIO/API/Gateway; Simulcast + Dynacast + `CALL_MAX_GROUP_PARTICIPANTS=20` keeps SFU load bounded on a single host.
5. **LAN / Emulator Dev Mode:** For local development without public TLS, `livekit-server` supports `--dev` / unencrypted `ws://<lan-ip>:7880` with `mobile/android/app/src/debug/AndroidManifest.xml` (`usesCleartextTraffic="true"`).
6. **Call History Messages:** This plan stores full call records in PostgreSQL (`calls` / `call_participants`). Persisting synthetic chat timeline entries ("Missed voice call", "Video call · 4m 12s") is optional and deferred from v1 so it does not perturb `messages.seq` or E2EE ratchet ordering.
7. **LiveKit Media E2EE:** Deferred to a follow-up phase (see Section 7.5). Transport is DTLS-SRTP encrypted to the self-hosted SFU.

---

## 2. Self-Hosted LiveKit Infrastructure Plan

### 2.1 Deployment Topology
Add `livekit` to `docker-compose.yml` alongside the existing services using **`network_mode: host`** (Linux host deployment):
- **Why `network_mode: host`:** Mapping 10,001 UDP ports (`50000-60000/udp`) through Docker's default bridge spawns massive `docker-proxy` / conntrack overhead and breaks ICE candidate IP advertisement. `network_mode: host` gives LiveKit direct kernel UDP socket performance and clean external IP discovery.
- **Redis reuse:** LiveKit connects to the existing `redis` container published at `127.0.0.1:${REDIS_PORT:-6379}` on **DB index `1`** (isolating LiveKit keys from CP Chat's DB `0`).
- **Backend webhook loopback:** Because `api` is published on `127.0.0.1:${API_PORT:-8080}` (change Compose port binding in production to `127.0.0.1:${API_PORT:-8080}:8080` behind the reverse proxy), LiveKit posts webhooks over loopback to `http://127.0.0.1:8080/api/v1/webhooks/livekit` with zero external internet hops.

**`docker-compose.yml` service addition (root):**
```yaml
  livekit:
    image: livekit/livekit-server:v1.9.11
    restart: unless-stopped
    network_mode: host
    depends_on:
      redis:
        condition: service_healthy
    environment:
      # Injects key/secret from .env without storing secrets in livekit.yaml
      LIVEKIT_KEYS: "${LIVEKIT_API_KEY}: ${LIVEKIT_API_SECRET}"
    command: ["--config", "/etc/livekit.yaml"]
    volumes:
      - ./infra/livekit/livekit.yaml:/etc/livekit.yaml:ro
      - ${LIVEKIT_TLS_CERT_DIR:-/etc/letsencrypt}:/etc/letsencrypt:ro
```
*(For local LAN/emulator testing where no certs exist, provide a `docker-compose.override.yml` or `livekit.dev.yaml` with `turn.enabled: false` and `rtc.use_external_ip: false` / `node_ip: <LAN_IP>`.)*

### 2.2 `infra/livekit/livekit.yaml` Configuration
Secrets are injected solely via `LIVEKIT_KEYS` from `.env` (`LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`), never hardcoded in YAML:

```yaml
port: 7880
bind_addresses:
  - "127.0.0.1" # Exposed externally only via reverse proxy on :443

rtc:
  port_range_start: 50000
  port_range_end: 60000
  tcp_port: 7881
  use_external_ip: true
  enable_loopback_candidate: false

redis:
  address: 127.0.0.1:6379
  db: 1

room:
  auto_create: false       # Only backend-minted tokens/RoomService can open rooms
  empty_timeout: 45        # Auto-close unanswered 1:1 / empty rooms after 45s
  departure_timeout: 20    # Close room 20s after last participant leaves

turn:
  enabled: true
  domain: turn.cpchat.example.com   # Or livekit.cpchat.example.com
  tls_port: 5349
  udp_port: 3478
  cert_file: /etc/letsencrypt/live/turn.cpchat.example.com/fullchain.pem
  key_file: /etc/letsencrypt/live/turn.cpchat.example.com/privkey.pem
  external_tls: false

webhook:
  api_key: ""              # Inherited from LIVEKIT_KEYS first key; or explicit key ID
  urls:
    - http://127.0.0.1:8080/api/v1/webhooks/livekit

logging:
  level: info
  pion_level: warn
```

> **Note on `room.auto_create: false`:** Requires the backend to create the room via `RoomServiceClient.createRoom(...)` (or allow creation via `roomCreate: true` grant only on verified start endpoints). Using `RoomServiceClient.createRoom` before minting join tokens prevents any stale/leaked token from resurrecting a finished room.

### 2.3 Environment Variables (`.env.example` & `docker-compose.yml`)
Add to `.env.example`, `backend/src/config.ts`, and `docker-compose.yml` (`api` and `livekit` services):
- `LIVEKIT_API_KEY` — LiveKit API key ID (never exposed to clients)
- `LIVEKIT_API_SECRET` — LiveKit API secret `>=32` chars (never exposed to clients)
- `LIVEKIT_URL` — Internal server-to-LiveKit HTTP URL for `RoomServiceClient` (e.g., `http://127.0.0.1:7880` or `http://host.docker.internal:7880` with `extra_hosts: ["host.docker.internal:host-gateway"]` on `api`)
- `LIVEKIT_PUBLIC_URL` — Client-reachable WSS URL returned in join responses (e.g., `wss://livekit.cpchat.example.com`, or `ws://10.0.2.2:7880` in emulator dev)
- `LIVEKIT_TOKEN_TTL_SECONDS` — Default `600` (10 minutes)
- `CALL_RING_TIMEOUT_SECONDS` — Default `40`
- `CALL_MAX_GROUP_PARTICIPANTS` — Default `20`
- **FCM on `api`:** Mirror existing `FCM_CREDENTIALS_FILE`, `FCM_PROJECT_ID`, `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, `FIREBASE_PRIVATE_KEY` onto the `api` service in `docker-compose.yml` (currently only passed to `gateway`), because call initiation/cancellation REST handlers run in `api`.

> **Docker Bridge -> Host LiveKit connectivity:** Because `api` runs on Compose's default bridge network while `livekit` uses `network_mode: host` (bound to `127.0.0.1:7880` + Docker bridge IP or `0.0.0.0:7880` firewalled externally), add `extra_hosts: ["host.docker.internal:host-gateway"]` to `api` and bind LiveKit port `7880` to `127.0.0.1` + Docker bridge subnet (or `0.0.0.0` with UFW blocking external `:7880`), then set `LIVEKIT_URL=http://host.docker.internal:7880`.

### 2.4 Reverse Proxy & Firewall Rules
**Nginx config (co-located with `docs/gateway-scaling.md`):**
```nginx
server {
    listen 443 ssl http2;
    server_name livekit.cpchat.example.com;

    ssl_certificate     /etc/letsencrypt/live/livekit.cpchat.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/livekit.cpchat.example.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:7880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
    }
}
```
On the main API Nginx server block (`api.cpchat.example.com`), explicitly deny external access to the internal webhook path:
```nginx
location = /api/v1/webhooks/livekit {
    allow 127.0.0.1;
    allow ::1;
    deny all;
    proxy_pass http://127.0.0.1:8080;
}
```

**Firewall (UFW / iptables):**

| Port / Proto | Direction | Purpose | Publicly Open? |
| :--- | :--- | :--- | :--- |
| `443/tcp` | Inbound | HTTPS/WSS signaling (`api`, `gateway`, `livekit.<domain>`) | Yes |
| `7880/tcp` | Inbound | LiveKit HTTP/WS internal signaling | **No** (loopback/Docker bridge only; open on LAN only in dev) |
| `7881/tcp` | Inbound | LiveKit WebRTC-over-TCP fallback | Yes |
| `50000:60000/udp` | Inbound | LiveKit SFU WebRTC media (ICE/DTLS/SRTP) | Yes |
| `3478/udp` | Inbound | Built-in TURN/UDP relay | Yes |
| `5349/tcp` | Inbound | Built-in TURN/TLS relay (corporate/strict mobile NAT fallback) | Yes |

```bash
sudo ufw allow 443/tcp
sudo ufw allow 7881/tcp
sudo ufw allow 5349/tcp
sudo ufw allow 3478/udp
sudo ufw allow 50000:60000/udp
sudo ufw deny 7880/tcp   # Enforce proxy-only access in prod
```

---

## 3. End-to-End Architecture & Signaling Flows

### 3.1 Plane Separation
- **Signaling Plane (`backend/` + `ChatGateway` + FCM):** Call authorization, state persistence (`calls` / `call_participants`), ringing, busy/cancel/reject/timeout transitions, active group call discovery, LiveKit room creation, and short-lived LiveKit token minting.
- **Media Plane (LiveKit SFU):** ICE/STUN/TURN negotiation, DTLS-SRTP media transport, audio/video pub/sub, Simulcast layer selection, Dynacast pause/resume, active speaker detection, connection quality metrics, and authoritative room lifecycle webhooks (`room_started`, `participant_joined`, `participant_left`, `room_finished`).

```text
Flutter Client A                         backend/ (api :8080 + gateway :8081)               LiveKit SFU (:7880/:7881/:50000-60000)
   |                                                      |                                                 |
   |--- POST /conversations/:id/calls (REST + JWT) ------>|--- RoomService.createRoom() ------------------->|
   |<-- { call, livekit_url, token } ---------------------|                                                 |
   |                                                      |--- Broker WS (call_incoming) ---> Client B (FG) |
   |                                                      |--- FCM high-prio data ----------> Client B (BG) |
   |=== WSS connect + WebRTC media (DTLS-SRTP) ============================================================>|
   |                                                      |<-- POST /webhooks/livekit (participant_joined) -|
```

### 3.2 1-on-1 Call Flows

1. **Outgoing Invite (Caller A -> Callee B):**
   - Caller taps Voice or Video in `ChatScreen` -> checks runtime mic (+ camera if video) permissions -> calls `POST /api/v1/conversations/:id/calls` with `{ media_type }`.
   - `api` verifies JWT, verifies `direct` conversation membership, checks callee is not already in an active/ringing call (Redis `call:user:{calleeId}`), checks caller is not busy, inserts `calls` row (`status = 'ringing'`, `ring_expires_at = NOW() + 40s`) and `call_participants` rows (`caller: 'joining'`, `callee: 'ringing'`), calls `RoomService.createRoom(roomName)`, and mints Caller A's LiveKit JWT.
   - `api` publishes WS `call_incoming` via `ctx.broker.publishBroadcast([calleeId], ...)` AND dispatches high-priority data-only FCM (`type: 'call_invite'`, `ttl: 45s`) to callee's devices that have no live WS socket (and when `callee.status !== 'dnd'`).
   - Caller A transitions to `calling`, starts ringback tone, connects to LiveKit room (publishing mic / optional camera), and waits for `call_accepted` or peer `ParticipantConnectedEvent`.

2. **Incoming Delivery Across Android App States (Callee B):**
   - **Foreground:** `ChatSocket` receives `call_incoming` -> `CallController` deduplicates by `call_id` -> transitions `idle -> ringing` -> pushes `/call/incoming` route + starts ringtone/vibration.
   - **Background (app paused, process alive):** `SessionLifecycle` disconnects WS after 4 s in background, so `api` delivers high-priority FCM `call_invite` -> `firebaseMessagingBackgroundHandler` delegates via `IsolateNameServer` (`kMainIsolateFcmPortName`) to main isolate -> `CallController` raises full-screen incoming call notification/UI (`cpchat_calls` channel with `fullScreenIntent: true` + `Accept`/`Decline` actions) and transitions to `ringing`.
   - **Terminated (process killed / Doze):** High-priority data-only FCM `call_invite` wakes headless background isolate -> verifies active session & account ownership via `TokenStore.forBackground()` (`shouldHandleFcmForAccount`, **zero SQLite access** for sub-second wake-up) -> verifies `now < expires_at` -> displays Android full-screen incoming call notification (`cpchat_calls` channel) with Accept/Decline actions. Tapping Accept or body launches `MainActivity` (`showWhenLocked` + `turnScreenOn`) with cold-start call payload -> `CpChatApp` routes directly to `/call/incoming` (or auto-accepts if Accept action was tapped).

3. **Accept / Reject / Cancel / Timeout / Busy / Hangup:**
   - **Accept:** Callee taps Accept -> requests mic (+ camera if video) permission -> calls `POST /api/v1/calls/:callId/accept`. Server atomically transitions `calls.status` `ringing -> active` (fails `409 call_already_ended` if caller already cancelled or timed out — resolving the accept-vs-cancel race cleanly!), returns `{ call, livekit_url, token }`, emits `call_accepted` to caller and `call_answered_elsewhere` (WS + silent FCM `call_cancel`) to callee's other devices.
   - **Reject:** Callee taps Decline -> `POST /api/v1/calls/:callId/reject` (`{ reason: 'declined' | 'busy' }`) -> server marks `calls.status = 'rejected'` (or `'busy'`), deletes LiveKit room, broadcasts `call_rejected` to caller and `call_ended` (WS + FCM `call_cancel`) to callee's other devices.
   - **Caller Cancel:** Caller hangs up while `calling` -> `POST /api/v1/calls/:callId/cancel` -> server transitions `ringing -> cancelled` (only if still `ringing`), deletes LiveKit room, emits `call_cancelled` (WS + silent FCM `call_cancel` so terminated callee dismisses the ringing notification immediately).
   - **Missed Timeout (40 s):** Server sweep updates `calls` where `type = '1on1' AND status = 'ringing' AND ring_expires_at <= NOW()` -> sets `status = 'missed'`, deletes LiveKit room, broadcasts `call_ended` (`reason: 'missed'`) to caller + callee (WS + FCM `call_cancel`). Client also runs a local 42 s safety timer.
   - **Callee Busy:** If callee is already in a call, server rejects `POST /conversations/:id/calls` with `409 callee_busy` (or client auto-calls `/reject` with `reason: 'busy'` if a local race occurred).
   - **Hangup:** Either user taps Hang Up -> client disconnects/disposes LiveKit room and calls `POST /api/v1/calls/:callId/leave` -> for `1on1`, server transitions `active -> ended`, deletes LiveKit room, clears `call:user:*` keys, and emits `call_ended` to peer.

### 3.3 Group Call Flows
1. **Start or Concurrent Start (Race-Safe):**
   - User taps Voice or Video in group `ChatScreen` -> `POST /api/v1/conversations/:id/calls` (`{ media_type }`).
   - Backend locks `SELECT id, type FROM conversations WHERE id = $1 FOR UPDATE` and checks for an existing `calls` row where `conversation_id = $1 AND status IN ('ringing', 'active')` (enforced by a partial unique index `calls_one_live_per_conversation_idx`).
   - **If none exists:** inserts `calls` (`type = 'group'`, `status = 'active'`), creates LiveKit room `call_<call_id>`, mints token, broadcasts `group_call_started` via `ctx.broker.publishBroadcast(memberIds, ...)` and sends high-priority FCM (`type: 'group_call_started'`, `ttl: 45s`) to offline non-DND members.
   - **If one already exists (including simultaneous taps by two members):** reuses the exact same `call_id` and `room_name`, checks participant cap, upserts `call_participants`, and returns `{ call, livekit_url, token, joined_existing: true }` — both members seamlessly land in the same LiveKit room.
2. **Active Call Banner & Late Join:**
   - Opening a group chat triggers `GET /api/v1/conversations/:id/active-call` (and `GET /api/v1/calls/active` runs on WS connect/reconnect) to hydrate live banners even if the WS event was missed while offline.
   - Live WS events `group_call_started`, `group_call_updated` (with `participant_count` and active participant preview IDs), and `group_call_ended` keep the **"Active Call (N) — Join"** banner in `ChatScreen` and active-call chip in `ConversationsScreen` synchronized in real time.
   - Late joiners tap **Join** -> `POST /api/v1/calls/:callId/join` -> server verifies current group membership (blocks removed members!) + participant cap -> returns fresh LiveKit token -> client joins room.
3. **Leave & Termination:**
   - A member tapping Leave disconnects LiveKit and calls `POST /api/v1/calls/:callId/leave` -> marks only their `call_participants` row `left_at = NOW()`. The group call **continues** for remaining members.
   - When the final participant leaves (or disconnects/crashes), LiveKit fires `participant_left` and then `room_finished` after `departure_timeout` (20 s). The webhook handler sets `calls.status = 'ended'`, `ended_at = NOW()`, clears Redis active-call state, and broadcasts `group_call_ended` to all group members to remove the banner.

---

## 4. Backend Implementation Blueprint (`backend/`)

### 4.1 Database & Redis State Schema

**New Migration:** `backend/migrations/000011_calls.up.sql` (and matching `000011_calls.down.sql`):
- **`calls` table:**
  - `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
  - `conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE`
  - `room_name TEXT NOT NULL UNIQUE` (format `call_<uuid>`)
  - `type VARCHAR(10) NOT NULL CHECK (type IN ('1on1', 'group'))`
  - `media_type VARCHAR(10) NOT NULL CHECK (media_type IN ('voice', 'video'))`
  - `initiated_by UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`
  - `status VARCHAR(16) NOT NULL CHECK (status IN ('ringing', 'active', 'ended', 'missed', 'rejected', 'cancelled', 'busy', 'failed'))`
  - `ring_expires_at TIMESTAMPTZ` (set for `1on1` ringing calls; `NULL` for `group`)
  - `started_at TIMESTAMPTZ NOT NULL DEFAULT NOW()`
  - `answered_at TIMESTAMPTZ`
  - `ended_at TIMESTAMPTZ`
  - `end_reason VARCHAR(32)`
  - **Partial unique index (critical race guard):** `CREATE UNIQUE INDEX calls_one_live_per_conversation_idx ON calls (conversation_id) WHERE status IN ('ringing', 'active');`
  - **Sweep index:** `CREATE INDEX calls_ringing_expires_idx ON calls (ring_expires_at) WHERE status = 'ringing';`
- **`call_participants` table:**
  - `call_id UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE`
  - `user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE`
  - `state VARCHAR(16) NOT NULL CHECK (state IN ('ringing', 'joining', 'joined', 'left', 'rejected', 'missed'))`
  - `joined_at TIMESTAMPTZ`
  - `left_at TIMESTAMPTZ`
  - `PRIMARY KEY (call_id, user_id)`
  - Index `call_participants_user_active_idx ON call_participants (user_id) WHERE state IN ('ringing', 'joining', 'joined')`

**Redis Keys (added to `backend/src/lib/redis.ts` `redisKeys`):**
- `call:user:{userId}` -> `callId` (TTL `3600s`, refreshed on join/token-refresh, deleted on `leave`/`participant_left`/`room_finished`) — fast O(1) busy check.
- `call:active:{conversationId}` -> JSON `{ call_id, type, media_type, status, participant_count }` (TTL `3600s`) — fast banner lookup cache, invalidated on state change.

### 4.2 LiveKit Server SDK Integration
- **Dependency:** Add `livekit-server-sdk` to `backend/package.json`.
- **New module `backend/src/lib/livekit.ts`:**
  - `LiveKitService(config, logger)`:
    - Disabled gracefully (returns `503` / `calls_unavailable`) if `LIVEKIT_API_KEY` or `LIVEKIT_API_SECRET` is unset, keeping existing CI and messaging tests green without LiveKit.
    - `createRoom(roomName, { maxParticipants, emptyTimeout, departureTimeout })` via `RoomServiceClient`.
    - `deleteRoom(roomName)` via `RoomServiceClient` (swallows `404` idempotently).
    - `mintToken({ roomName, userId, displayName, metadata })` via `AccessToken`: TTL `config.LIVEKIT_TOKEN_TTL_SECONDS` (600 s), `identity: userId`, `name: displayName`, grants `{ roomJoin: true, room: roomName, canPublish: true, canSubscribe: true, canPublishData: true, roomCreate: false }`.
    - `verifyWebhook(rawBody: string, authHeader: string)` via `WebhookReceiver` (verifies JWT signature + SHA-256 body hash).

### 4.3 REST Endpoints (`backend/src/http/call-routes.ts`)
All routes except the webhook use existing `requireAuth(request, config)` from `backend/src/http/context.ts` and validate conversation membership via `ctx.conversations.requireMemberConversation`:

| Method & Path | Purpose | Request / Response |
| :--- | :--- | :--- |
| `POST /api/v1/conversations/:id/calls` | Start 1:1 call or start/join group call | Body `{ media_type: 'voice' \| 'video' }` -> `201`/`200` `{ call, livekit_url, token, joined_existing }` |
| `POST /api/v1/calls/:callId/accept` | Accept ringing 1:1 call | -> `200` `{ call, livekit_url, token }` (`409` if already cancelled/missed/ended) |
| `POST /api/v1/calls/:callId/join` | Late-join active group call | -> `200` `{ call, livekit_url, token }` (`403` if not group member, `409` if ended or full) |
| `POST /api/v1/calls/:callId/token` | Refresh short-lived LiveKit token mid-call | -> `200` `{ livekit_url, token, expires_in }` |
| `POST /api/v1/calls/:callId/reject` | Decline 1:1 call | Body `{ reason?: 'declined' \| 'busy' }` -> `204` |
| `POST /api/v1/calls/:callId/cancel` | Caller cancels ringing 1:1 call | -> `204` |
| `POST /api/v1/calls/:callId/leave` | Leave active call (ends 1:1; keeps group alive) | -> `204` |
| `GET /api/v1/conversations/:id/active-call` | Fetch active call summary for a conversation | -> `200` `{ active_call: CallSummary \| null }` |
| `GET /api/v1/calls/active` | Fetch all active calls across caller's chats | -> `200` `{ calls: CallSummary[] }` |
| `POST /api/v1/webhooks/livekit` | LiveKit server webhook receiver (signature-verified) | Raw body + `Authorization` header -> `200` `{ ok: true }` |

### 4.4 Real-Time Signaling (WebSocket) & Push (FCM)

**WebSocket Server -> Client Frames** (published from `api` via `ctx.broker.publishBroadcast` / targeted `publishToNode` using `ConnectionRegistry` lookup, delivered unmodified by `ChatGateway`):
- `call_incoming`: `{ type: "call_incoming", call_id, conversation_id, call_type: "1on1", media_type, room_name, caller: { id, name, avatar_url }, expires_at }`
- `call_accepted`: `{ type: "call_accepted", call_id, conversation_id, accepted_by }`
- `call_answered_elsewhere`: `{ type: "call_answered_elsewhere", call_id, conversation_id, handled_by_device_id }` (sent via `excludeDevice` to callee's other devices)
- `call_rejected`: `{ type: "call_rejected", call_id, conversation_id, rejected_by, reason: "declined" | "busy" }`
- `call_cancelled`: `{ type: "call_cancelled", call_id, conversation_id, cancelled_by }`
- `call_ended`: `{ type: "call_ended", call_id, conversation_id, reason }`
- `group_call_started`: `{ type: "group_call_started", call_id, conversation_id, conversation_name, media_type, started_by: { id, name }, participant_count }`
- `group_call_updated`: `{ type: "group_call_updated", call_id, conversation_id, participant_count, participant_ids }`
- `group_call_ended`: `{ type: "group_call_ended", call_id, conversation_id, reason }`

**FCM High-Priority Data-Only Payloads** (new `notifyCallEvent` method in `backend/src/lib/fcm.ts`, using `fids` multicast, `android: { priority: 'high', ttl: 45_000 }`, **no** top-level `notification` block so the Flutter background isolate always wakes):
```json
{
  "push_schema": "2",
  "type": "call_invite",
  "call_id": "<uuid>",
  "conversation_id": "<uuid>",
  "conversation_type": "direct",
  "conversation_name": "",
  "call_type": "1on1",
  "media_type": "video",
  "caller_id": "<uuid>",
  "caller_name": "Alice",
  "recipient_user_id": "<uuid>",
  "expires_at": "1764348040000"
}
```
- Cancellation/end pushes send `type: "call_cancel"` (or `"call_ended"`) with `call_id`, `conversation_id`, `recipient_user_id` so background/terminated devices immediately dismiss the ringing notification.
- **Privacy:** Never includes LiveKit JWT tokens, room secrets, or chat content in FCM payloads; the client fetches the LiveKit token over authenticated HTTPS only after the user accepts/joins.

### 4.5 LiveKit Webhook Handler & Timeout Sweeper
- **Raw Body Parsing in Fastify:** Register `/api/v1/webhooks/livekit` inside an encapsulated Fastify plugin (`app.register(...)`) with `addContentTypeParser(['application/webhook+json', 'application/json'], { parseAs: 'string' }, ...)` so `WebhookReceiver.receive(rawBody, authHeader)` validates the exact bytes LiveKit signed.
- **Handled Events (all idempotent):**
  - `room_started`: Ensure `calls.status` is `active` (for group) and log room SID.
  - `participant_joined`: Upsert `call_participants` (`state = 'joined'`, `joined_at = NOW()`), set `call:user:{identity}`, recompute `participant_count`, emit `group_call_updated` for groups.
  - `participant_left`: Update `call_participants` (`state = 'left'`, `left_at = NOW()`), delete `call:user:{identity}`, recompute `participant_count`. For `1on1` active calls when a connected peer drops unexpectedly and leaves `0` or `1` after grace, LiveKit's `departure_timeout` / explicit `deleteRoom` cleans up; for groups, emit `group_call_updated`.
  - `room_finished`: Mark `calls.status = 'ended'` (if still `ringing`/`active`), `ended_at = NOW()`, mark remaining `joined` participants `left`, clear `call:active:{conversationId}` and `call:user:*`, emit `call_ended` or `group_call_ended` + FCM `call_cancel` if it was still ringing.
- **Missed-Call Sweeper (`backend/src/domain/call-sweeper.ts`):** Runs a lightweight `setInterval` (every 5 s) inside `rest.ts` executing `UPDATE calls SET status = 'missed', ended_at = NOW(), end_reason = 'timeout' WHERE type = '1on1' AND status = 'ringing' AND ring_expires_at <= NOW() RETURNING ...`. Using a single atomic `UPDATE ... RETURNING` is multi-replica safe without needing distributed locks.

### 4.6 Backend Files to Create / Modify
- **Create:**
  - `backend/migrations/000011_calls.up.sql` & `000011_calls.down.sql`
  - `backend/src/lib/livekit.ts` — LiveKit `AccessToken`, `RoomServiceClient`, `WebhookReceiver` wrapper
  - `backend/src/domain/calls.ts` — `CallRepository` (transactional start/join/accept/reject/cancel/leave, participant tracking, active-call queries, timeout sweep)
  - `backend/src/domain/call-signaling.ts` — `CallSignalingService` (coordinates DB transitions, LiveKit room/token calls, WS broker routing, FCM call pushes, Redis busy/active cache)
  - `backend/src/http/call-routes.ts` — REST endpoints + encapsulated raw-body LiveKit webhook route
  - `backend/test/calls.test.ts` — Vitest integration tests (1:1 lifecycle, busy, accept-vs-cancel race, concurrent group start convergence, late join, membership revocation, webhook signature & state reconciliation)
- **Modify:**
  - `backend/package.json` — add `livekit-server-sdk`
  - `backend/src/config.ts` — add `LIVEKIT_*` and `CALL_*` env vars
  - `backend/src/lib/errors.ts` — add `callee_busy` (`409`), `call_not_found` (`404`), `call_already_ended` (`409`), `call_full` (`409`), `calls_unavailable` (`503`)
  - `backend/src/lib/redis.ts` — add `callUser` and `activeCall` keys
  - `backend/src/lib/fcm.ts` — add `CallPushPayload` & `notifyCallEvent` (high-priority data-only with `ttl: 45_000`)
  - `backend/src/http/context.ts` — wire `notifications`, `livekit`, `calls`, `callSignaling` into `AppContext`
  - `backend/src/http/server.ts` — register `registerCallRoutes(app, ctx)`
  - `backend/src/rest.ts` — initialize `NotificationService` and start/stop the 5 s missed-call sweeper on boot/shutdown
  - `docker-compose.yml` & `.env.example` — add `livekit` service, `LIVEKIT_*` / `CALL_*` vars, `extra_hosts` + `FCM_*`/`FIREBASE_*` vars on `api`
  - `docs/api-spec.yaml` & `docs/ws-protocol.md` — document new REST & WS call contracts

---

## 5. Client Dependencies & Android Platform Configuration

### 5.1 Flutter Dependencies (`mobile/pubspec.yaml`)
Verified against Dart `^3.14.0`, `minSdk = 24`, `compileSdk = 37`, AGP `9.3.1`:
- **`livekit_client` (`^2.5.x` or latest compatible with Dart 3.14):** LiveKit SFU client + `flutter_webrtc` transitive dependency (provides `Room`, Simulcast/Dynacast, `VideoTrackRenderer`, `Hardware.instance` for speaker/earpiece/Bluetooth device enumeration & switching).
- **`permission_handler` (`^12.x`):** Runtime permission requests and permanently-denied (`openAppSettings()`) checks for microphone, camera, Bluetooth connect, and notifications.
- **`wakelock_plus` (`^1.3.x`):** Keeps screen awake during active video calls and prevents premature suspend.
- **`audio_session` (`^0.2.x`):** Requests Android `AUDIOFOCUS_GAIN_TRANSIENT` with `AndroidAudioUsage.voiceCommunication` so music/media pauses when a call starts and resumes cleanly when the call ends.
- **Incoming Call UI & Ongoing Call Foreground Service (AGP 9.3.1 / SDK 37 risk mitigation):**
  - Instead of pulling heavy third-party plugins that frequently lag behind AGP 9.x / Android SDK 37, implement **two small, zero-external-dependency native Kotlin components** in `mobile/android/app/src/main/kotlin/com/cpchat/mobile/` bridged via a typed `MethodChannel('com.cpchat.mobile/call_service')` (matching the repo's existing native plugin pattern in `packages/cpchat_storage_dirs`):
    1. `CallForegroundService.kt`: Android `Service` supporting `FOREGROUND_SERVICE_TYPE_MICROPHONE` (voice calls) and `FOREGROUND_SERVICE_TYPE_MICROPHONE | FOREGROUND_SERVICE_TYPE_CAMERA` (upgraded dynamically on Android 14+ when camera is enabled and `CAMERA` permission is granted), showing an ongoing silent call notification with a "Hang Up" action and tap-to-return `PendingIntent`.
    2. Full-screen incoming call notification via existing `flutter_local_notifications` (`fullScreenIntent: true`, `AndroidNotificationCategory.call`, `ongoing: true`, `autoCancel: false`, `Accept` + `Decline` notification actions, `cpchat_calls` channel with `RingtoneManager.TYPE_RINGTONE`) paired with `MainActivity` lock-screen wake flags (`setShowWhenLocked` / `setTurnScreenOn` toggled only while ringing/in-call).
  - *Alternative:* `flutter_callkit_incoming` can be evaluated in Phase 3 if native Telecom `ConnectionService` Bluetooth/headset button integration is desired, gated on a clean Gradle sync under AGP 9.3.1 / SDK 37.

### 5.2 Android Configuration Changes

1. **`mobile/android/app/src/main/AndroidManifest.xml`:**
   - Add permissions:
     - `android.permission.RECORD_AUDIO`
     - `android.permission.CAMERA`
     - `android.permission.MODIFY_AUDIO_SETTINGS`
     - `android.permission.BLUETOOTH` (`android:maxSdkVersion="30"`)
     - `android.permission.BLUETOOTH_CONNECT`
     - `android.permission.ACCESS_NETWORK_STATE`
     - `android.permission.FOREGROUND_SERVICE`
     - `android.permission.FOREGROUND_SERVICE_MICROPHONE`
     - `android.permission.FOREGROUND_SERVICE_CAMERA`
     - `android.permission.USE_FULL_SCREEN_INTENT`
     - *(Already present: `INTERNET`, `POST_NOTIFICATIONS`, `VIBRATE`, `WAKE_LOCK`)*
   - Add optional hardware features (so devices without autofocus/front camera remain supported):
     - `<uses-feature android:name="android.hardware.camera" android:required="false" />`
     - `<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />`
     - `<uses-feature android:name="android.hardware.microphone" android:required="false" />`
   - Declare foreground service inside `<application>`:
     ```xml
     <service
         android:name=".CallForegroundService"
         android:exported="false"
         android:foregroundServiceType="microphone|camera" />
     ```

2. **`mobile/android/app/src/main/kotlin/com/cpchat/mobile/MainActivity.kt`:**
   - Eagerly create two additional channels alongside `cpchat_messages`:
     - `cpchat_calls`: `IMPORTANCE_HIGH`, `AudioAttributes.USAGE_NOTIFICATION_RINGTONE`, ringtone sound, vibration, lock-screen visibility `VISIBILITY_PUBLIC`.
     - `cpchat_ongoing_call`: `IMPORTANCE_LOW`, silent, no vibration (for the ongoing foreground service notification).
   - Register `MethodChannel('com.cpchat.mobile/call_service')` to start/update/stop `CallForegroundService`, toggle `setShowWhenLocked`/`setTurnScreenOn`, and manage `AudioManager` communication mode / proximity sensor wake lock (screen-off near ear during voice-only earpiece calls).

3. **`mobile/android/app/build.gradle.kts`:**
   - `minSdk = 24` already meets LiveKit/WebRTC's `>= 23` requirement.
   - `compileSdk = maxOf(flutter.compileSdkVersion, 37)` and Java 17 + `isCoreLibraryDesugaringEnabled = true` already satisfy all Android 14/15/16 FGS APIs. No Gradle SDK bump required.

4. **`mobile/android/app/proguard-rules.pro`:**
   Append WebRTC / LiveKit / native call service keep rules (mandatory because release has `isMinifyEnabled = true`):
   ```proguard
   # WebRTC & LiveKit (JNI + reflection callbacks)
   -keep class org.webrtc.** { *; }
   -dontwarn org.webrtc.**
   -keep class com.cloudwebrtc.webrtc.** { *; }
   -keep class io.livekit.** { *; }
   -keep class com.cpchat.mobile.CallForegroundService { *; }
   ```

5. **`mobile/android/app/src/main/res/xml/network_security_config.xml`:**
   - Keep `cleartextTrafficPermitted="false"` for release; LiveKit signaling MUST use `wss://` in release builds (debug builds already opt into cleartext via `src/debug/AndroidManifest.xml`). If certificate pinning is enabled later, add a `<domain-config>` for `livekit.<domain>`.

---

## 6. Client State Management & File-by-File Blueprint

### 6.1 Call State Machine
```text
idle ──(start 1:1)────────► calling ──(accepted / peer joined)──► connecting ──(LiveKit connected)──► connected
  │                            │                                      │                                  │  ▲
  ├──(start/join group)────────┼──────────────────────────────────────┘                                  │  │
  │                            ├──(cancel / rejected / busy / timeout)──► ended ──► idle                 ▼  │
  └──(incoming 1:1)──► ringing ──(accept)───────────────────────────► connecting                  reconnecting
                         │                                                │                              │
                         ├──(decline / cancel / timeout / elsewhere)──► ended ◄──(hangup / room_finished)┘
                         └────────────────────────────────────────────────┴──(fatal error)──► failed ──► idle
```
States: `idle`, `calling`, `ringing`, `connecting`, `connected`, `reconnecting`, `ended`, `failed`.
- `ended` and `failed` display brief feedback (e.g. "Busy", "No answer", "Call ended", or error reason) for 1.5–2 s before resetting to `idle` and popping the call route.
- **Account Isolation Rule (`architecture_guard_test.dart`):** `callControllerProvider`, `activeGroupCallsProvider`, and `livekitMediaServiceProvider` MUST all `ref.watch(accountScopeProvider)`. On `SessionLifecycle.stop()` (logout/account switch), immediately hang up and dispose any active call.
- **Background Socket Guard (`mobile/lib/core/providers.dart`):** In `SessionLifecycle.onAppLifecycleChanged`, skip the 4-second `_bgDisconnectTimer` while `callControllerProvider.state.status != CallStatus.idle` so minimizing the app or locking the screen during an active call keeps WebSocket signaling alive alongside the Android Foreground Service.

### 6.2 File-by-File Blueprint

#### New Files (`mobile/lib/core/` & `mobile/lib/features/calls/`)
- **`mobile/lib/core/models/call_models.dart`**
  - Contracts: `CallType` (`oneOnOne`, `group`), `CallMediaType` (`voice`, `video`), `CallStatus` (`idle`, `calling`, `ringing`, `connecting`, `connected`, `reconnecting`, `ended`, `failed`), `AudioRoute` (`earpiece`, `speaker`, `bluetooth`), `ActiveCallSummary` (`callId`, `conversationId`, `type`, `mediaType`, `participantCount`, `participantIds`, `startedAt`), `CallJoinGrant` (`call`, `livekitUrl`, `token`), `CallParticipantView` (`userId`, `displayName`, `avatarUrl`, `videoTrack`, `audioMuted`, `videoEnabled`, `isSpeaking`, `connectionQuality`, `isLocal`).
- **`mobile/lib/features/calls/call_permissions.dart`**
  - Contract: `CallPermissionService` wrapping `permission_handler` (`ensureForVoice()`, `ensureForVideo()`, `ensureCameraForUpgrade()`, `ensureBluetoothConnect()`). Returns typed outcome (`granted`, `denied`, `permanentlyDenied`) so UI shows a clear dialog with an "Open Settings" action when permanently denied.
- **`mobile/lib/features/calls/call_foreground_service.dart`**
  - Contract: `CallForegroundServiceBridge` wrapping `MethodChannel('com.cpchat.mobile/call_service')` with `start({callId, title, withCamera})`, `update({title, withCamera})`, `stop()`, `setLockScreenVisible(bool)`, `setProximityWakeLock(bool)`. No-ops cleanly in unit tests / non-Android hosts.
- **`mobile/lib/features/calls/livekit_media_service.dart`**
  - Contract: Owns LiveKit `Room` lifecycle and media controls:
    - Configures `RoomOptions(adaptiveStream: true, dynacast: true, defaultAudioPublishOptions: AudioPublishOptions(dtx: true, red: true), defaultVideoPublishOptions: VideoPublishOptions(simulcast: true, videoCodec: 'vp8', videoEncoding: VideoParametersPresets.h540_169.encoding), defaultCameraCaptureOptions: CameraCaptureOptions(cameraPosition: CameraPosition.front, params: VideoParametersPresets.h540_169))`.
    - Methods: `connect(url, token, {enableVideo})`, `disconnectAndDispose()`, `setMicEnabled(bool)`, `setCameraEnabled(bool)`, `switchCamera()`, `setAudioRoute(AudioRoute)`, `availableAudioRoutes()`, `setSubscribedVideoParticipants(Set<String> visibleUserIds)` (disables off-screen remote video subscriptions in large group calls to protect Android decoder/bandwidth budgets).
    - Emits reactive state: `participants`, `activeSpeakerIds`, `connectionState` (`connected`/`reconnecting`/`disconnected`), `localAudioMuted`, `localVideoEnabled`, `currentAudioRoute`, `cameraPosition`, `connectionQuality`.
- **`mobile/lib/features/calls/call_controller.dart`**
  - Contract: Account-scoped Riverpod `Notifier<CallState>` + `activeGroupCallsProvider` (`Map<String, ActiveCallSummary>` keyed by `conversationId`).
  - Responsibilities:
    - Drives the 8-state machine and coordinates `ApiClient`, `ChatSocket.callEvents`, `LiveKitMediaService`, `CallForegroundServiceBridge`, `AudioSession`, `WakelockPlus`, and `LocalNotificationService`.
    - Deduplicates `call_incoming` / FCM `call_invite` via `RecentIdSet` keyed by `callId`.
    - Resolves cancel-vs-accept race: if `POST /accept` returns `409 call_already_ended`, cancels ringing notification and transitions cleanly to `ended`.
    - Handles incoming 1:1 while already busy: auto-calls `POST /calls/:id/reject` (`reason: 'busy'`) without interrupting current call.
    - Refreshes active group calls on WS reconnect (`GET /api/v1/calls/active`) and per-chat open (`GET /api/v1/conversations/:id/active-call`).
    - Manages 42 s client-side ringing fallback timer and call duration ticker.
    - Tracks `isMinimized` so user can collapse an active call into a top return-to-call bar and keep chatting.
- **`mobile/lib/features/calls/incoming_call_screen.dart`**
  - Route `/call/incoming`: Full-screen dark-surface incoming call UI with caller `MediaAvatar` / `UserAvatarWithStatus`, caller name, "Incoming voice/video call" label, pulsing ring indicator, and emerald Accept / red Decline buttons.
- **`mobile/lib/features/calls/active_call_screen.dart`**
  - Route `/call/active`: Renders:
    - **Outgoing ringing state (`calling`):** Peer avatar, name, "Calling..." / "Ringing...", cancel button.
    - **1:1 Voice:** Centered avatar, name, call duration timer, connection quality chip, controls bar.
    - **1:1 Video:** Remote `VideoTrackRenderer` full-screen + draggable local preview PiP (`Positioned` rounded card) + auto-hiding top bar (minimize, timer, quality) and bottom `CallControlsBar`.
    - **Group Call:** Delegates main canvas to `GroupCallGrid` + top bar with group name, participant count pill (opens `CallParticipantsSheet`), minimize button, and `CallControlsBar`.
    - Displays persistent inline reconnecting banner when `status == CallStatus.reconnecting`.
- **`mobile/lib/features/calls/widgets/group_call_grid.dart`**
  - Adaptive layout: 1 remote -> full screen; 2 -> split vertical; 3–4 -> 2×2 grid; 5–6 -> 2×3 grid; 7+ -> paged 2×3 grid (`PageView`) or pinned-speaker stage + bottom thumbnail strip.
  - Active speaker highlight border (`AppColors.whatsappEmerald`), tap tile to pin/unpin, avatar fallback when remote video is off, mute badge.
  - Calls `livekitMediaService.setSubscribedVideoParticipants(...)` with only the currently visible page + pinned speaker IDs so Android never decodes >6 simultaneous video streams.
- **`mobile/lib/features/calls/widgets/call_controls_bar.dart`**
  - Controls: Mute/Unmute mic, Audio Output selector (cycles or opens bottom sheet for Earpiece / Speaker / Bluetooth), Toggle Camera mid-call (triggers camera permission check + FGS camera type upgrade), Flip Camera (visible when camera on), Participants button (groups), Red Hang Up button.
- **`mobile/lib/features/calls/widgets/call_participants_sheet.dart`**
  - Modal bottom sheet listing all connected participants, speaking indicator, mic/camera icons, connection quality dots.
- **`mobile/lib/features/calls/widgets/active_call_banner.dart`**
  - Two compact banners:
    1. `GroupActiveCallBanner`: Shown inside `ChatScreen` (right below `ConnectionBanner`) when a group has an ongoing call that the user is not currently in — displays emerald pulse dot, `"Ongoing voice/video call · N in call"`, and `"Join"` button.
    2. `OngoingCallReturnBar`: Shown globally at the top of the app shell when the user minimizes their own active call — shows elapsed timer + `"Tap to return to call"`.

#### Existing Files to Modify (`mobile/`)
- **`mobile/android/app/src/main/kotlin/com/cpchat/mobile/CallForegroundService.kt`** *(new)* & **`MainActivity.kt`** *(modify)* — channels, `MethodChannel`, FGS lifecycle, lock-screen flags.
- **`mobile/android/app/src/main/AndroidManifest.xml`**, **`mobile/android/app/proguard-rules.pro`**, **`mobile/pubspec.yaml`** — permissions, `<service>`, R8 keep rules, packages.
- **`mobile/lib/core/network/api_client.dart`** — add `startCall`, `acceptCall`, `joinCall`, `refreshCallToken`, `rejectCall`, `cancelCall`, `leaveCall`, `activeCallForConversation`, `activeCalls`.
- **`mobile/lib/core/network/ws_client.dart`** — add `StreamController<Map<String, dynamic>> _callEventController` (`callEvents` stream) and dispatch `call_*` / `group_call_*` frames in `_onData` without touching message handling.
- **`mobile/lib/core/notifications/local_notification_service.dart`** — add `cpchat_calls` channel, `showIncomingCallNotification(...)` (`fullScreenIntent: true`, Accept/Decline actions, account-tagged payload with `kind: 'call'`), and `cancelCallNotification(callId)`.
- **`mobile/lib/core/notifications/background_push_handler.dart`** — branch on `data['type']` (`call_invite`, `call_cancel`, `call_ended`, `group_call_started`) **before** `ParsedFcmMessage` / SQLite lock: delegate to main isolate if alive; if terminated, validate session + account ownership (`shouldHandleFcmForAccount`) + `expires_at`, then show/cancel full-screen call notification directly without opening Drift.
- **`mobile/lib/core/providers.dart`** — register `callControllerProvider`, `activeGroupCallsProvider`, `livekitMediaServiceProvider` (all watching `accountScopeProvider`), guard `_bgDisconnectTimer` while in a call, and hang up/dispose in `SessionLifecycle.stop()`.
- **`mobile/lib/main.dart`** — add `/call/incoming` and `/call/active` routes to `routerProvider`, wire foreground/background call FCM handoff & cold-start call action routing, mount `OngoingCallReturnBar` overlay.
- **`mobile/lib/features/chat/chat_screen.dart`** — add Voice (`Icons.call`) and Video (`Icons.videocam`) `IconButton`s to `AppBar.actions` (disabled/showing "Return to call" if already in a call for this chat), and render `GroupActiveCallBanner` below `ConnectionBanner`.
- **`mobile/lib/features/conversations/conversations_screen.dart`** — display subtle emerald `"In call"` pill on group rows present in `activeGroupCallsProvider`.
- **`mobile/test/architecture_guard_test.dart`** — add `callControllerProvider` & `livekitMediaServiceProvider` to the account-switch isolation test.

---

## 7. Edge Cases, Resource Cleanup & Security

### 7.1 Runtime Permission Handling
- **Voice Call:** Requires `RECORD_AUDIO` (+ `POST_NOTIFICATIONS` on Android 13+ for foreground service notification; `BLUETOOTH_CONNECT` on Android 12+ requested lazily when Bluetooth headset detected, optional).
- **Video Call / Mid-Call Video Upgrade:** Requires `RECORD_AUDIO` + `CAMERA`. If `CAMERA` is denied when starting a video call, offer "Join with audio only" fallback; if denied during a mid-call upgrade, keep audio uninterrupted and show snackbar/dialog.
- **Permanently Denied:** Detect `PermissionStatus.isPermanentlyDenied` and display an `AlertDialog` linking directly to `openAppSettings()`.
- **Android 14+ Foreground Service Crash Prevention:** Never pass `FOREGROUND_SERVICE_TYPE_CAMERA` to `startForeground()` unless `CAMERA` permission is currently granted AND the app is in a valid foreground state; start with `microphone` only and upgrade to `microphone|camera` only when camera publishing succeeds.

### 7.2 Busy State & Call Collisions
- **User already in a 1:1 or group call receives a 1:1 invite:** Backend checks `call:user:{calleeId}` and returns `409 callee_busy` immediately to caller; if a race still delivers `call_incoming`, client auto-calls `POST /calls/:id/reject` (`reason: 'busy'`) and ignores UI transition.
- **User in a call receives a group call start:** Does not interrupt active call; updates `activeGroupCallsProvider` so the banner is visible if they navigate to that group.
- **Simultaneous 1:1 calls (A calls B while B calls A):** The partial unique index `calls_one_live_per_conversation_idx` on `calls (conversation_id)` guarantees only one `ringing` row exists; the second caller's `POST /conversations/:id/calls` detects the existing incoming `ringing` call from the peer and auto-accepts it (converging both into the same call!).

### 7.3 Network Handoff, Reconnect & Ghost-Room Cleanup
- **Wi-Fi <-> Cellular Handoff:** LiveKit SDK performs automatic ICE restart (`RoomReconnectingEvent` -> `RoomReconnectedEvent`). UI shows `reconnecting` banner while keeping call controls mounted. If LiveKit triggers full disconnect (`RoomDisconnectedEvent`) while `calls.status == 'active'`, client calls `POST /api/v1/calls/:callId/token` to fetch a fresh JWT and attempts one reconnect before transitioning to `failed`.
- **Ghost-Room Cleanup:** Three-layer safety net:
  1. LiveKit `room.empty_timeout: 45` and `room.departure_timeout: 20` automatically close abandoned rooms and fire `room_finished`.
  2. Webhook handler marks `calls.status = 'ended'` and clears Redis `call:user:*` and `call:active:*`.
  3. Backend periodic sweeper (every 5 s for ringing timeouts, every 60 s for active calls older than 2 minutes whose LiveKit room no longer exists via `RoomServiceClient.listRooms`) reconciles any missed webhook during an API restart.

### 7.4 Strict Resource Disposal Checklist
Every terminal transition (`ended`, `failed`, logout/account switch, or `CallController` dispose) MUST execute an idempotent `_cleanup()` in a `try/finally` chain:
1. Cancel ringing timeout timer, call duration ticker, and all `StreamSubscription`s (`EventsListener<RoomEvent>.dispose()`, WS/audio focus subscriptions).
2. Unpublish and explicitly `stop()` + `dispose()` local audio and video tracks (`LocalAudioTrack`, `LocalVideoTrack`).
3. Call `await room.disconnect()` followed by `await room.dispose()`.
4. Stop ringtone/ringback audio player and vibration; release `AudioSession` focus (`setActive(false)`).
5. Call `CallForegroundServiceBridge.stop()`, `setLockScreenVisible(false)`, and `setProximityWakeLock(false)`.
6. Call `WakelockPlus.disable()`.
7. Dismiss any incoming call notification (`LocalNotificationService.cancelCallNotification(callId)`).
8. Clear local `CallState` back to `idle` and pop `/call/*` route if mounted.

### 7.5 Security & Privacy
- **Authorization:** Every call endpoint verifies JWT (`requireAuth`) and live membership in `conversation_members`. Removed group members immediately lose ability to join or refresh tokens.
- **Short-Lived Scoped Tokens:** LiveKit JWTs expire in 10 minutes (`LIVEKIT_TOKEN_TTL_SECONDS=600`), pinned to a single `room_name` and `identity = userId`, with `roomCreate: false`. `LIVEKIT_API_SECRET` stays strictly on the server.
- **Webhook Integrity:** `/api/v1/webhooks/livekit` verifies LiveKit's signed `Authorization` JWT and body SHA-256 hash on the raw request string AND is blocked from external internet access in Nginx.
- **FCM Privacy:** Push payloads carry only IDs, call/media type, and display name — never LiveKit tokens, room credentials, or chat contents. Account ownership is verified before displaying notifications so multi-account isolation (`§3.3`) holds.
- **Media E2EE Scope:** All media is DTLS-SRTP encrypted in transit between Android devices and this self-hosted LiveKit SFU. True end-to-end LiveKit frame encryption (`KeyProvider` / per-call key distribution via X3DH for 1:1 and MLS/Sender Keys for groups) is **explicitly deferred to a follow-up phase**, aligning with `docs/e2ee.md` where group and media E2EE are documented as follow-ups.

---

## 8. Phased Implementation Roadmap

### Phase 1: Self-Hosted LiveKit Server, Reverse Proxy & Firewall Setup
- **Deliverables:** `infra/livekit/livekit.yaml`, `livekit` service in `docker-compose.yml`, `.env.example` updates, Nginx config for `livekit.<domain>` + internal webhook block, UFW rules (`443`, `7881`, `5349/tcp`, `3478/udp`, `50000-60000/udp`).
- **Verification:** `docker compose config -q`, `docker compose up -d livekit`, LiveKit readiness check on `http://127.0.0.1:7880`, WSS handshake test against `wss://livekit.<domain>`, and LiveKit Connection Tester verifying UDP + TURN/TLS fallback.

### Phase 2: `backend/` Schema, LiveKit Token Endpoint, Signaling & Webhooks
- **Deliverables:** `000011_calls.{up,down}.sql`, `livekit-server-sdk`, `src/lib/livekit.ts`, `src/domain/calls.ts`, `src/domain/call-signaling.ts`, `src/http/call-routes.ts`, `NotificationService` wired into `rest.ts` + `api` Compose env, missed-call sweeper, `backend/test/calls.test.ts`, updated `docs/api-spec.yaml` & `docs/ws-protocol.md`.
- **Verification:** `make migrations-check`, `make migrate-up`, `cd backend && npm run typecheck && npm run build && npm test`.

### Phase 3: Client Dependencies & Android Platform Configuration
- **Deliverables:** Add `livekit_client`, `permission_handler`, `wakelock_plus`, `audio_session` to `mobile/pubspec.yaml`; update `AndroidManifest.xml`, `proguard-rules.pro`, `MainActivity.kt`; add `CallForegroundService.kt`, `call_permissions.dart`, `call_foreground_service.dart`.
- **Verification:** `cd mobile && flutter pub get && flutter analyze && flutter test` (Rule 0: do not build APK/AAB; test native channel & FGS on a connected device with `flutter run -d android`).

### Phase 4: Client Core LiveKit Service & 1-on-1 Calling
- **Deliverables:** `call_models.dart`, `livekit_media_service.dart`, `call_controller.dart` (1:1 paths), `api_client.dart` & `ws_client.dart` call hooks, `incoming_call_screen.dart`, `active_call_screen.dart` (1:1 voice + video with draggable PiP), `call_controls_bar.dart`, `ChatScreen` header voice/video call buttons, `SessionLifecycle` background-socket guard & logout teardown, unit tests for state machine & `architecture_guard_test.dart` updates.
- **Verification:** `cd mobile && flutter analyze && flutter test`; live 2-device 1:1 voice/video call via `flutter run -d android`.

### Phase 5: Group Calling (Active Banners, Adaptive Grid, Simulcast/Dynacast)
- **Deliverables:** Group start/join/late-join flows in `call_controller.dart`, `activeGroupCallsProvider`, `GroupActiveCallBanner` in `ChatScreen`, `"In call"` pill in `ConversationsScreen`, `OngoingCallReturnBar`, `group_call_grid.dart` (adaptive layout, active speaker highlight, pin, off-screen video subscription gating), `call_participants_sheet.dart`.
- **Verification:** `cd mobile && flutter analyze && flutter test`; live 3-device group call test (concurrent start, late join, individual leave, final leave -> `room_finished`).

### Phase 6: Background/Terminated Incoming Calls, Edge Cases & Cleanup
- **Deliverables:** `background_push_handler.dart` call push fast-path (`call_invite` / `call_cancel` / `call_ended`), `local_notification_service.dart` full-screen call notification + Accept/Decline actions, cold-start call intent handling in `main.dart`, multi-device `call_answered_elsewhere`, busy auto-reject, network handoff recovery, full resource disposal verification tests.
- **Verification:** `make verify` (`migrations-check`, `backend-typecheck`, `backend-build`, `backend-test`, `mobile-analyze`, `mobile-test`) + full physical-device matrix below.

---

## 9. Verification & Test Matrix

Execute manual verification across **2–3 physical Android devices** (Android 12–15+, launched via `flutter run -d android` or user-managed install) covering both Wi-Fi and cellular networks:

| Category | Test Scenario | Expected Result |
| :--- | :--- | :--- |
| **LiveKit / Network** | Device A on Wi-Fi, Device B on mobile cellular (4G/5G behind strict NAT) | ICE connects via UDP or falls back cleanly to TCP `:7881` / TURN-TLS `:5349`; bidirectional audio & video flow <300 ms latency. |
| **1-on-1 Foreground** | Voice call & Video call A -> B (both apps open) | B shows incoming screen immediately; A hears ringback; Accept connects both; video renders remote full-screen + draggable local PiP. |
| **1-on-1 Background** | B backgrounded (>10 s so WS disconnected), A calls B | High-priority FCM wakes B; full-screen incoming call notification appears; tapping Accept opens call and connects audio/video. |
| **1-on-1 Terminated** | B swiped away / force-stopped, screen locked; A calls B | Headless isolate wakes without opening SQLite, verifies account + expiry, shows lock-screen incoming call UI; Accept launches app directly into active call. |
| **1-on-1 Termination** | Reject, Caller Cancel (while B ringing), Missed Timeout (40 s), Callee Busy (B already in a call), Hangup | Both devices transition cleanly to `idle`; ringing notification on background/terminated B dismisses immediately on Cancel/Timeout; busy returns "Busy" to A without disrupting B's active call. |
| **Multi-Device** | User B logged in on Device B1 & B2; A calls B; B1 accepts | B2 stops ringing immediately (`call_answered_elsewhere` / FCM `call_cancel`). |
| **Mid-Call Controls** | Voice call -> tap Camera On -> Flip front/back -> Mute -> Audio route (Earpiece / Speaker / Bluetooth) | Video upgrades smoothly without dropping audio; FGS upgrades to `microphone\|camera`; audio switches cleanly across all 3 outputs; Bluetooth disconnect falls back to earpiece/speaker. |
| **Group Simultaneous Start** | Devices A & B tap Call in the same group at the exact same moment | Both converge into the **same** `call_id` and LiveKit room (partial unique index prevents split rooms). |
| **Group Late Join & Leave** | A & B in group call -> C opens chat and sees **"Active Call (2) — Join"** banner -> C joins -> A leaves -> B & C stay -> B & C leave | Banner updates count live; A leaving keeps call alive for B & C; after last member leaves, LiveKit `room_finished` ends call in DB and removes banner from all devices. |
| **Group Scale & Video** | 3+ devices toggle video on/off, speak in turn, pin a tile, minimize call to send a text | Active speaker highlights in emerald; pinning locks stage; minimizing shows return-to-call bar while FGS keeps audio alive; returning restores video grid. |
| **Permissions & Denied** | Deny camera on video call; permanently deny mic | Video call offers audio-only fallback; permanently denied mic shows Settings dialog without crashing FGS on Android 14+. |
| **Network Drop & Cleanup** | Toggle Wi-Fi -> 5G mid-call; kill app mid-call; logout mid-call | Wi-Fi->5G shows `reconnecting` then recovers; killed participant is cleaned up by `participant_left`/`room_finished` webhook; logout hangs up and disposes room, tracks, FGS, and wakelock cleanly. |
