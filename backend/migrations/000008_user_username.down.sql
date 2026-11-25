BEGIN;

DROP INDEX IF EXISTS users_phone_or_email_trgm_idx;
DROP INDEX IF EXISTS users_username_trgm_idx;
DROP INDEX IF EXISTS users_username_lower_key;
ALTER TABLE users DROP COLUMN IF EXISTS username;

COMMIT;
