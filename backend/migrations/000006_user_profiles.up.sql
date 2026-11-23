BEGIN;

-- Phase 5: user profiles.
--
-- `nickname` is an optional short handle rendered as "Name (nickname)".
-- `status` is the user's preferred Discord-style presence state; `invisible`
-- is a privacy setting and is never exposed to other users (they see offline).
-- `custom_status` is a free-text headline, `bio` a longer self-description.
-- Both are capped so a profile payload stays bounded.
ALTER TABLE users ADD COLUMN nickname VARCHAR(60);
ALTER TABLE users ADD COLUMN status VARCHAR(20) NOT NULL DEFAULT 'online'
    CHECK (status IN ('online', 'idle', 'dnd', 'invisible'));
ALTER TABLE users ADD COLUMN custom_status VARCHAR(120);
ALTER TABLE users ADD COLUMN bio TEXT;

COMMIT;
