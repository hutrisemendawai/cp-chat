BEGIN;

-- Auth: users authenticate with a password. Phase 0 shipped no user rows, so the
-- default lets the column be added safely and is dropped immediately after.
ALTER TABLE users ADD COLUMN password_hash TEXT NOT NULL DEFAULT '';
ALTER TABLE users ALTER COLUMN password_hash DROP DEFAULT;

-- Opaque refresh tokens. Only the SHA-256 hash is stored, never the token.
CREATE TABLE refresh_tokens (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token_hash TEXT NOT NULL UNIQUE,
    device_id TEXT,
    expires_at TIMESTAMPTZ NOT NULL,
    revoked_at TIMESTAMPTZ,
    replaced_by UUID REFERENCES refresh_tokens(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX refresh_tokens_user_id_idx ON refresh_tokens (user_id);

-- Android FCM registration tokens, one row per device per user.
CREATE TABLE device_tokens (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL,
    fcm_token TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, device_id)
);

-- A physical device keeps the same FCM token across logins, so the token itself
-- is unique and reassigned to the newest user/device.
CREATE UNIQUE INDEX device_tokens_fcm_token_idx ON device_tokens (fcm_token);

-- Monotonic per-conversation sequence counter, allocated inside the insert
-- transaction so `seq` has no gaps and no duplicates.
ALTER TABLE conversations ADD COLUMN last_seq BIGINT NOT NULL DEFAULT 0
    CHECK (last_seq >= 0);

-- Canonical "smaller_id:larger_id" key for direct conversations so creating the
-- same 1:1 chat twice returns the existing row instead of duplicating it.
ALTER TABLE conversations ADD COLUMN direct_key TEXT;
CREATE UNIQUE INDEX conversations_direct_key_idx
    ON conversations (direct_key)
    WHERE direct_key IS NOT NULL;

ALTER TABLE conversations ADD CONSTRAINT conversations_direct_key_matches_type
    CHECK ((type = 'direct') = (direct_key IS NOT NULL));

COMMIT;
