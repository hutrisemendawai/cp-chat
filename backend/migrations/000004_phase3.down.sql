BEGIN;

DROP INDEX IF EXISTS messages_search_vector_idx;
ALTER TABLE messages DROP COLUMN IF EXISTS search_vector;
ALTER TABLE users DROP COLUMN IF EXISTS last_seen_at;

COMMIT;
