Implement a mandatory unique `username` system (with email-or-username login) and upgrade the Add Friend flow to a privacy-preserving, paginated live search across both `backend/` and `mobile/` (Android target only).

## 0. Inspect Existing Implementation First
Before making changes, inspect the relevant files to follow the codebase's existing conventions, error handling, validation patterns, and state management:
- Backend migrations: `backend/migrations/000001_init.up.sql`, `000006_user_profiles.up.sql`, `000007_contacts_and_user_search.up.sql`
- Backend domain & HTTP: `backend/src/domain/users.ts`, `backend/src/domain/friends.ts`, `backend/src/http/auth-routes.ts`, `backend/src/http/user-routes.ts`, `backend/src/http/friend-routes.ts`, `backend/src/http/search-routes.ts`
- API spec: `docs/api-spec.yaml`
- Mobile client: `mobile/lib/core/models/models.dart`, `mobile/lib/core/network/api_client.dart`, `mobile/lib/core/database/app_database.dart`, `mobile/lib/core/database/chat_dao.dart`, `mobile/lib/features/auth/auth_screen.dart`, `mobile/lib/features/people/people_screen.dart`, `mobile/lib/features/people/people_controller.dart`, `mobile/lib/shared/widgets/user_search_picker.dart`, `mobile/lib/features/profile/my_profile_screen.dart`, `mobile/lib/features/profile/user_profile_screen.dart`

---

## 1. Database Migration (`backend/migrations/`)
Create the next sequential paired migration (`000008_user_username.up.sql` and `000008_user_username.down.sql`):
- Add a `username` column (`TEXT` / `VARCHAR`) to the `users` table.
- **Backfill existing rows safely** before adding constraints: generate a deterministic, valid, unique lowercase username for any existing user without one (e.g., sanitized email local-part + short unique suffix if collisions occur).
- Set `username` to `NOT NULL`.
- Create a case-insensitive unique index on `LOWER(username)`.
- Add appropriate search indexes on `username` and `email` (reusing `pg_trgm` GIN indexes if already enabled in `000007_contacts_and_user_search.up.sql`, or matching the project's indexing strategy) to keep substring live search fast.
- Ensure `.down.sql` cleanly drops the indexes and column.

---

## 2. Backend Implementation (`backend/`)

### A. Username Rules & Registration
- Require `username` in the registration payload (`auth-routes.ts` / `domain/users.ts`).
- Normalize `username` by trimming and storing in lowercase (or enforce case-insensitive uniqueness via `LOWER(username)`).
- Validate `username`:
  - Required, 3–30 characters.
  - Allowed characters: `a-z`, `0-9`, `_`, `.` (no whitespace, no `@` symbol so usernames can never collide with email addresses, no leading/trailing `.` or consecutive `..`).
- Return a clean validation error (`400`) for invalid format and conflict error (`409`) when a username already exists (matching `backend/src/lib/errors.ts` conventions).

### B. Login via Email OR Username
- Update the login endpoint and user lookup logic so users can authenticate with **either their email or their username**:
  - Accept `identifier` in the login request body (also accept `email` as a fallback if `identifier` is omitted, for backward compatibility).
  - Resolve the user by matching `LOWER(email) = LOWER($1)` OR `LOWER(username) = LOWER($1)`.
  - Preserve generic invalid-credential error messages and existing token/refresh-token behavior.

### C. Expose `username` & Protect Email Privacy
- Include `username` in user/profile/contact/friend/member response payloads (auth responses, `GET /users/me`, public user profiles, friend lists, and conversation participants).
- **Email privacy**: Keep `email` on self endpoints (`auth`, `GET /users/me`), but do **not** expose other users' `email` in user search results (or public profile discovery payloads) so emails cannot be scraped via live search.

### D. Paginated Live Search for Adding Friends
- Update (or add to) the user search endpoint used by the Add Friend flow:
  - Query params:
    - `q` (string, trimmed): **minimum 3 characters** required. If `q.length < 3`, reject with `400` or return an empty paginated response consistently (document the contract clearly).
    - `limit` (integer): default `10`, clamped to max `10` (with mobile explicitly requesting `10`).
    - `offset` (integer): default `0`, must be `>= 0`.
  - Match users server-side where `username` OR `email` matches `q` (case-insensitive substring match, e.g., `ILIKE '%q%'`). Rank exact/prefix matches ahead of mid-string matches, with deterministic tie-breaking (e.g., `ORDER BY ..., username ASC, id ASC`) so pagination never duplicates or skips users across pages.
  - Exclude the currently authenticated user from results.
  - **Minimal search result fields**: Return only safe public summary fields needed for the search list and profile navigation (`id`, display name / nickname fields, avatar URL — omit `email`).
  - Fetch `limit + 1` rows to determine `has_more` accurately without an expensive full `COUNT(*)`, returning:
    - `users` (or existing list field name, max 10 items)
    - `limit`, `offset`, `has_more` (boolean), `next_offset` (nullable int)
  - Ensure the add-friend endpoint works cleanly by `user_id` when triggered from a user's profile screen.
- Update `docs/api-spec.yaml` to match all schema and endpoint changes.

---

## 3. Mobile Flutter Implementation (`mobile/`)

### A. Models, Local DB, and API Client
- Add `username` to the user/profile models in `mobile/lib/core/models/models.dart`, and make sure the user search result model does not rely on `email` being present.
- If user records are cached in Drift (`app_database.dart` / `chat_dao.dart`), add `username` cleanly with the proper schema version bump & migration and regenerate `app_database.g.dart`.
- Update `mobile/lib/core/network/api_client.dart`:
  - `register`: require and send `username`.
  - `login`: send `identifier` (email or username).
  - User search method: accept `query`, `limit` (default `10`), and `offset` (default `0`), returning the parsed page (`items`, `hasMore`, `nextOffset`).

### B. Auth Screen (`mobile/lib/features/auth/auth_screen.dart`)
- **Login form**:
  - Change the email input label/hint to `"Email or Username"`.
  - Update client-side validation so both valid emails and valid usernames are accepted (non-empty, trimmed).
- **Registration form**:
  - Add a required `"Username"` text field with client-side validation matching backend rules (3–30 chars, letters/numbers/`_`/`.`, no `@` or spaces).
  - Surface server-side errors clearly (e.g., `"Username is already taken"`).

### C. Add Friend Live Search (`people_screen.dart`, `people_controller.dart`, `user_search_picker.dart`)
- Upgrade the Add Friend search UI to perform live search as the user types a username or email:
  - **Minimum 3 characters**: Do not trigger a network search when `query.trim().length < 3`. Clear previous results and show a subtle helper prompt (e.g., `"Type at least 3 characters to search by username or email"`).
  - **Debounce & stale-request guard**: Debounce text input (~350ms) and discard/ignore stale out-of-order responses if the query has changed while a request was in flight.
  - **Pagination (10 at a time + Load More)**:
    - Fetch the first 10 matches (`offset = 0, limit = 10`).
    - When `hasMore` is `true`, render a **"Load more"** button at the bottom of the result list.
    - Tapping **"Load more"** fetches the next 10 (`offset = currentOffset`, `limit = 10`), shows an inline loading spinner on the button while loading, and appends the new items to the existing list (deduplicating by user ID). Repeat until `hasMore` is `false`.
    - Reset the list and pagination state (`offset = 0`) whenever the search query changes.
  - **Result item UX (strictly minimal & profile-first)**:
    - Display **ONLY the user's profile photo (avatar) and display name** in each search result row. Do **not** display email, `@username`, or an inline Add Friend button in the search list.
    - Tapping any search result item opens that user's profile screen (`user_profile_screen.dart`).
    - Handle loading, empty (`"No matching users found"`), and retryable error states cleanly.

### D. Profile Screens (`my_profile_screen.dart`, `user_profile_screen.dart`)
- On `user_profile_screen.dart`:
  - Display the user's profile details (avatar, display name, `@username`, bio/status, etc.) without exposing their email address.
  - Provide the **Add Friend** action directly on this profile screen (showing a loading state while submitting and updating to an `"Added"` / friend state once added, keeping the People list/state in sync when navigating back).
- On `my_profile_screen.dart`:
  - Display the signed-in user's `@username` cleanly alongside their profile info.

---

## 4. Tests & Verification
- **Backend**:
  - Update `backend/test/helpers.ts`, `backend/test/auth.test.ts`, `backend/test/friends-and-search.test.ts`, `backend/test/profile.test.ts`, and `backend/scripts/smoke.mjs`.
  - Add test cases for:
    - Registration rejecting missing/invalid/duplicate (case-insensitive) usernames.
    - Login succeeding with email, succeeding with username (including different casing), and failing with invalid credentials.
    - User live search enforcing min 3 characters, matching both `username` and `email` server-side, **omitting `email` from the search response payload**, excluding self, returning max 10 items per page, and paginating cleanly across multiple pages (e.g., 25 matching users -> 10, 10, 5 with accurate `has_more`).
- **Mobile**:
  - Update `mobile/test/support/factories.dart`, `mobile/test/models_test.dart`, and `mobile/test/people_and_profile_test.dart` (plus auth widget tests).
  - Test `< 3` char threshold (no API call), debounce behavior, 10-item pagination + "Load more" appending, search result rows rendering **only avatar + name** (no email or inline add button), tapping a result navigating to `UserProfileScreen`, adding a friend from `UserProfileScreen`, and login/register form validation.
- Run all backend unit/integration tests, TypeScript build/typecheck, `flutter analyze`, and `flutter test`, and fix any failures before finishing.
