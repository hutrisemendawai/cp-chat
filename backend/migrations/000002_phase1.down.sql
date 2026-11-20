BEGIN;

ALTER TABLE conversations DROP CONSTRAINT IF EXISTS conversations_direct_key_matches_type;
DROP INDEX IF EXISTS conversations_direct_key_idx;
ALTER TABLE conversations DROP COLUMN IF EXISTS direct_key;
ALTER TABLE conversations DROP COLUMN IF EXISTS last_seq;

DROP TABLE IF EXISTS device_tokens;
DROP TABLE IF EXISTS refresh_tokens;

ALTER TABLE users DROP COLUMN IF EXISTS password_hash;

COMMIT;
