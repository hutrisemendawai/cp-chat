BEGIN;

-- Phase 4: end-to-end encryption key registry (X3DH / Signal-style).
--
-- The server stores only PUBLIC keys and never sees a private key or a message
-- plaintext. A client publishes:
--   * a long-term identity DH key (X25519) and a signing key (Ed25519);
--   * one signed prekey (X25519) whose signature binds it to the identity key;
--   * a batch of one-time prekeys (X25519) that are handed out once.
--
-- The private halves live on the device in Android Keystore-backed secure
-- storage. See docs/e2ee.md.

CREATE TABLE user_identity_keys (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    identity_public_key TEXT NOT NULL,
    signing_public_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Exactly one active signed prekey per user. Rotation replaces the row.
CREATE TABLE user_signed_prekeys (
    user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    key_id INTEGER NOT NULL,
    public_key TEXT NOT NULL,
    signature TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One-time prekeys are consumed (deleted) when a bundle is fetched, so a key
-- is never handed out twice. Remaining count drives client replenishment.
CREATE TABLE user_one_time_prekeys (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    key_id INTEGER NOT NULL,
    public_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, key_id)
);

CREATE INDEX user_one_time_prekeys_user_id_idx ON user_one_time_prekeys (user_id);

COMMIT;
