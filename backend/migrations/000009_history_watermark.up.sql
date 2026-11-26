-- Per-member sync/history watermark and identity key epoch tracking.
-- Allows a member to clear chat history without deleting shared message rows,
-- and lets an identity key rotation automatically advance direct-chat watermarks
-- so undecryptable pre-rotation ciphertexts are never re-served as stubs.

ALTER TABLE conversation_members
  ADD COLUMN cleared_seq BIGINT NOT NULL DEFAULT 0 CHECK (cleared_seq >= 0);

ALTER TABLE user_identity_keys
  ADD COLUMN key_epoch INT NOT NULL DEFAULT 1,
  ADD COLUMN rotated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();
