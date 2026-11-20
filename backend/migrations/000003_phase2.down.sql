BEGIN;

DROP TABLE IF EXISTS media_objects;
ALTER TABLE conversations DROP COLUMN IF EXISTS avatar_url;

COMMIT;
