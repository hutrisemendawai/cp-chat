BEGIN;

-- Presence: the gateway keeps a short TTL key in Redis for "online", and this
-- column is the durable "last seen" timestamp written when the final device of
-- a user disconnects.
ALTER TABLE users ADD COLUMN last_seen_at TIMESTAMPTZ;

-- Message search. A generated column keeps the vector in sync with every
-- insert and retry without the application maintaining it by hand. The 'simple'
-- configuration is language-agnostic (no stemming/stopwords), which suits a
-- chat app whose conversations can mix languages.
ALTER TABLE messages
    ADD COLUMN search_vector tsvector
    GENERATED ALWAYS AS (to_tsvector('simple', content)) STORED;

CREATE INDEX messages_search_vector_idx ON messages USING GIN (search_vector);

COMMIT;
