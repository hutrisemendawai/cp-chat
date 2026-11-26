ALTER TABLE user_identity_keys
  DROP COLUMN IF EXISTS rotated_at,
  DROP COLUMN IF EXISTS key_epoch;

ALTER TABLE conversation_members
  DROP COLUMN IF EXISTS cleared_seq;
