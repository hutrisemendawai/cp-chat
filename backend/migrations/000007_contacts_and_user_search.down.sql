BEGIN;

DROP INDEX IF EXISTS users_lower_phone_or_email_idx;
DROP INDEX IF EXISTS users_lower_name_idx;
DROP TABLE IF EXISTS user_friends;

COMMIT;
