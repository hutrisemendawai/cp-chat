You are executing Phase 6 of PLAN.MD for CP Chat. Perform full end-to-end verification, update smoke tests and documentation, and ensure clean Docker + physical Android deployment readiness, then push to git main.

Tasks:
1. Update `backend/scripts/smoke.mjs`:
   - Extend the end-to-end smoke script to also verify:
     - User profile update (`PATCH /api/v1/users/me` with nickname, bio, and Discord statuses `idle`/`dnd`/`invisible`).
     - User search by name and email (`GET /api/v1/users/search`).
     - Adding/listing/removing friends (`POST/GET/DELETE /api/v1/friends`).
     - API-proxied media upload (`POST /api/v1/media/upload`) and streamed media download (`GET /api/v1/media/*`), including cross-user avatar access.
     - Log ingestion and retrieval (`GET /api/v1/logs`, `GET /logs`).

2. Docker Compose & Environment Polish (`docker-compose.yml`, `.env.example`, `Makefile`, `README.md`):
   - Ensure `docker-compose.yml` passes `LOG_BUFFER_ENABLED`, `LOG_RETENTION_SECONDS`, `LOG_MAX_ENTRIES`, `MEDIA_PROXY_DOWNLOAD` to `api` and `gateway`.
   - Ensure `Makefile` has clear targets for running all migrations (`000001` through `000007`) and building/restarting `api` + `gateway`.
   - Document in `README.md` (and `mobile/README.md`):
     - How to run/build Flutter APK for physical Android devices on LAN (`--dart-define=API_BASE_URL=... --dart-define=WS_BASE_URL=...`).
     - How to open the live 1-hour Log Dashboard at `http://<host>:<api-port>/logs`.

3. Full Verification Suite:
   - Run `cd backend && npm run typecheck && npm run build && npm test`.
   - Run `cd mobile && flutter analyze && flutter test`.
   - Verify no stale UUID prompts remain anywhere in `mobile/lib/` (grep for `"User id"` / `"user id"` in UI labels).
   - Verify all SQL migrations (`000001`..`000007`) have matching `.up.sql` and `.down.sql` pairs with valid SQL.
   - Commit all changes cleanly and push to `git main`.
