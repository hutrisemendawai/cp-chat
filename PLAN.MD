# CP Chat — Feature Expansion & Bugfix Plan (`PLAN.MD`)

## How to Use This Plan with an Agentic AI
Instruct your coding agent with:
> `Read AGENTS.MD and PLAN.MD. Start Phase <N>, complete every requirement and acceptance check, commit cleanly, and push to git main.`

### Global Rules for Every Phase
1. **Follow repository conventions** in `AGENTS.MD` (TypeScript strict mode, Fastify + Zod, PostgreSQL numbered migrations, Riverpod + Drift + GoRouter in Flutter).
2. **Clean code:** Do not add unnecessary inline comments. Keep code self-explanatory.
3. **Never break existing contracts or tests:** Run backend tests (`npm test` / `npm run typecheck`) and Flutter checks (`flutter analyze` / `flutter test`) before committing.
4. **Update documentation** (`docs/api-spec.yaml`, `docs/ws-protocol.md`, `.env.example`) whenever an endpoint, WebSocket frame, or env variable changes.
5. **Git discipline:** Commit all changes for the phase with a clear conventional commit message (e.g., `fix(mobile,media): phase 1 - resolve pending chat and media upload errors`) and push to `main` only after verification passes.

---

## Phase Overview

| Phase | Focus | Primary Scope |
| :--- | :--- | :--- |
| **Phase 1** | Fix Critical Messaging & Media Upload Bugs | Mobile WebSocket lifecycle, outbox reconciliation, API-proxied media upload/download, MinIO endpoint fix |
| **Phase 2** | Real-Time 1-Hour Logging System & Live Web Dashboard | Backend Redis-backed 1-hour TTL log collector, mobile error forwarding, live `/logs` HTML viewer (SSE) |
| **Phase 3** | User Profile System (Avatar, Nickname & Discord-Style Status) | DB migration `000006`, profile APIs, Discord presence engine (`online`/`idle`/`dnd`/`invisible`), Flutter Profile UI |
| **Phase 4** | Friends & User Search by Name/Email (Remove All UUID Inputs) | DB migration `000007`, user search & friends APIs, replace UUID flows in New Chat, Create Group, Group Info |
| **Phase 5** | Mobile People Directory, User Profile Viewer & One-Tap Direct Chat | Bottom navigation (`Chats`/`People`/`Profile`), `/people` directory, `/users/:id` profile screen with direct Chat CTA |
| **Phase 6** | End-to-End Verification, Sync Polish & Deployment Hardening | Drift migration validation, full test suite, OpenAPI/WS docs sync, physical-device smoke checklist |

---

## Phase 1: Fix Pending Chat Delivery & Image Upload Connection Refused

### Context & Diagnosed Root Causes
1. **Messages stay `pending` forever on physical mobile devices:**
   - In `mobile/lib/main.dart`, `_CpChatAppState._bootstrap()` calls `ref.listen<AuthSession?>(authControllerProvider, ...)` inside an async post-frame callback. Riverpod forbids `ref.listen` outside `build()` (must use `ref.listenManual` in lifecycle methods or `ref.listen` inside `build()`). Because `_bootstrap()` fails silently when unawaited, fresh logins never trigger `_startSessionRuntime()` and `ChatSocket.connect()` is never called.
   - In `mobile/lib/core/database/chat_dao.dart`, `applyStatus()` does not remove acknowledged rows from `outboxEntries` or persist server `seq`, and `_maxStatus()` permanently locks rows in `'failed'` state (`if (current == 'failed' && incoming != 'failed') return 'failed'`) even when a retry later succeeds.
   - `ChatSocket` does not expose connection state to the UI, does not automatically attempt `connect()` on `send()` if disconnected, and does not refresh an expired access token before WebSocket reconnects.
   - Logout in `AuthController.logout()` does not cleanly disconnect `ChatSocket` or reset `E2eeManager` session state.
2. **Image upload fails with `DioException [connection error]: Connection refused, errno = 111, address = localhost`:**
   - `S3_PUBLIC_ENDPOINT` defaults to `http://localhost:9000` in `docker-compose.yml` and `.env.example`. `StorageService` generates presigned PUT/GET URLs pointing to `localhost:9000`, which resolves to the phone itself instead of the backend host.
   - Additionally, `GET /api/v1/media/*` currently redirects (`302`) to that unreachable presigned URL.

### Agentic Prompt — Phase 1
```text
You are executing Phase 1 of PLAN.MD for CP Chat. Fix both the "messages stuck in pending" bug and the "image upload DioException connection refused to localhost" bug end-to-end across backend and Flutter mobile, then verify and push to git main.

Tasks:
1. Fix Flutter Auth-to-Socket Lifecycle (`mobile/lib/main.dart`, `mobile/lib/core/providers.dart`):
   - Replace the invalid `ref.listen` inside `_CpChatAppState._bootstrap()` with a proper `ProviderSubscription` via `ref.listenManual` (disposed cleanly in `dispose()`) OR handle session transitions inside `build()` / a dedicated session controller so `_startSessionRuntime()` is guaranteed to run both on cold-start restore AND immediately after manual login/register.
   - Ensure logout disconnects and resets `ChatSocket` (add a `disconnect()` method that stops timers/reconnects without permanently marking `_disposed = true`, or invalidate/rebuild `chatSocketProvider`) and resets `E2eeManager` in-memory state (`_bootstrapped`, `_keys`, `_peerIds`, `_plaintext`).

2. Fix Outbox & Message Status Reconciliation (`mobile/lib/core/network/ws_client.dart`, `mobile/lib/core/database/chat_dao.dart`):
   - Expose a reactive connection status stream/notifier (`connecting`, `connected`, `disconnected`, plus `lastError`) on `ChatSocket` and surface a subtle banner in `ConversationsScreen` / `ChatScreen` when disconnected (with a "Reconnect" button).
   - In `ChatSocket.send()`, if `!isConnected`, trigger `unawaited(connect())` so pending messages are flushed as soon as the socket comes up.
   - Before each WebSocket connect/reconnect attempt, ensure the access token is valid (if handshake fails with 401/403 or token is expired, trigger a single-flight refresh via `ApiClient` before retrying).
   - In `ChatSocket._handleStatus()`, pass `seq` (when present) into `ChatDao.applyStatus(clientMsgId, status, seq: seq)`.
   - In `ChatDao.applyStatus()`:
     - When `status` is `'sent'`, `'delivered'`, or `'read'`, update `seq` (if provided), delete the matching row from `outboxEntries`, and allow transitioning OUT of `'failed'` back to `'sent'`/`'delivered'`/`'read'`.
     - Fix `_maxStatus()` so server-confirmed states (`sent`, `delivered`, `read`) always override `pending` and `failed`.
   - When `ChatSocket` receives a server `error` frame with a `client_msg_id` (if applicable) or times out, mark failed cleanly while still allowing manual tap-to-retry to reset status to `pending` and resend.

3. Fix Media Upload & Download for Physical Devices (`backend/src/lib/storage.ts`, `backend/src/http/media-routes.ts`, `mobile/lib/core/network/api_client.dart`, `mobile/lib/core/media/media_service.dart`, `docker-compose.yml`, `.env.example`):
   - In `StorageService`, separate the internal S3 client (`config.S3_ENDPOINT`, e.g. `http://minio:9000` inside Docker) used for server-side `PutObject`/`GetObject`/`DeleteObject` from the public presign client (`config.S3_PUBLIC_ENDPOINT`).
   - Add an authenticated API-proxied upload endpoint `POST /api/v1/media/upload` (accepting raw binary body with `Content-Type` header and `x-filename` header, or `multipart/form-data`, respecting `MEDIA_MAX_BYTES` and `MEDIA_ALLOWED_TYPES`) that validates auth/size/MIME, uploads directly to MinIO using the internal `S3_ENDPOINT`, inserts the `media_objects` row, and returns `{ media_id, object_key, file_url, content_type, size_bytes }`.
   - Update `GET /api/v1/media/*` so that by default (or when `?proxy=1` / when `MEDIA_PROXY_DOWNLOAD=true`, default `true`), Fastify streams the object directly from MinIO via the internal S3 client (`GetObjectCommand`) with proper `Content-Type`, `Content-Length`, and `Cache-Control: private, max-age=300` headers—eliminating `302` redirects to `localhost:9000`. Keep `POST /api/v1/media/presign` backward-compatible for existing tests and clients, and allow deriving the public host from `S3_PUBLIC_ENDPOINT` when explicitly set.
   - Update Flutter `MediaService` and `ApiClient` to upload media via `POST /api/v1/media/upload` with upload progress callbacks (`onSendProgress`) so physical phones only ever need connectivity to `API_BASE_URL` (no direct port 9000 exposure required).
   - Increase Fastify body limit specifically on `/api/v1/media/upload` to match `config.MEDIA_MAX_BYTES` (25 MB default) while keeping the global JSON body limit at 1 MB.
   - Ensure `mobile/android/app/src/main/res/xml/network_security_config.xml` and debug config remain valid XML without double hyphens in comments, and document LAN testing setup in `.env.example`.

4. Tests & Verification:
   - Add/update backend Vitest tests in `backend/test/media.test.ts` covering `POST /api/v1/media/upload` and streamed `GET /api/v1/media/*` (keeping existing presign tests green).
   - Add/update Flutter unit tests in `mobile/test/chat_dao_test.dart` verifying that `applyStatus(..., 'sent', seq: 1)` deletes the outbox entry and recovers from `'failed'`, plus a test verifying WebSocket connects on login transition.
   - Run `cd backend && npm run typecheck && npm test` and `cd mobile && flutter analyze && flutter test`.
   - Commit all changes cleanly and push to `git main`.
