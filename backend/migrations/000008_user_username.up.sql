BEGIN;

-- Phase 7: mandatory unique usernames with email-or-username login.
--
-- `username` is the public handle users share to be found. It can never collide
-- with an email address (the `@` symbol is not allowed) and is stored lowercase
-- behind a case-insensitive unique index. Existing rows are backfilled from the
-- email local-part before the NOT NULL constraint and the unique index are
-- applied, so this migration is safe to run on a populated database.
ALTER TABLE users ADD COLUMN username VARCHAR(30);

-- Deterministic, valid, unique backfill for rows created before usernames:
-- the sanitized email local-part, plus a short id-derived suffix only when that
-- base is already taken. Rows are processed in a stable order so the result is
-- reproducible.
DO $$
DECLARE
  rec RECORD;
  base TEXT;
  hash TEXT;
  candidate TEXT;
  attempt INT;
BEGIN
  FOR rec IN SELECT id, phone_or_email FROM users WHERE username IS NULL ORDER BY created_at, id LOOP
    base := lower(split_part(rec.phone_or_email, '@', 1));
    base := regexp_replace(base, '[^a-z0-9_.]', '', 'g');  -- drop disallowed characters
    base := regexp_replace(base, '\.{2,}', '.', 'g');      -- collapse runs of dots
    base := trim(both '.' from base);                      -- no leading/trailing dot
    IF length(base) < 3 THEN
      base := 'user';
    END IF;
    base := left(base, 30);

    hash := replace(rec.id::text, '-', '');
    candidate := base;
    attempt := 0;
    WHILE EXISTS (SELECT 1 FROM users WHERE username = candidate AND id <> rec.id) LOOP
      attempt := attempt + 1;
      candidate := left(base, 20) || '.' || substr(hash, attempt, 9);
    END LOOP;

    UPDATE users SET username = candidate WHERE id = rec.id;
  END LOOP;
END $$;

ALTER TABLE users ALTER COLUMN username SET NOT NULL;

-- Case-insensitive uniqueness, which also serves exact and prefix lookups.
CREATE UNIQUE INDEX users_username_lower_key ON users (lower(username));

-- Trigram indexes keep the substring live search over username and email fast.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX users_username_trgm_idx ON users USING gin (lower(username) gin_trgm_ops);
CREATE INDEX users_phone_or_email_trgm_idx ON users USING gin (lower(phone_or_email) gin_trgm_ops);

COMMIT;
