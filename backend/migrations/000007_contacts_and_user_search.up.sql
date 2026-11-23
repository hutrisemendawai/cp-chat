BEGIN;

-- Phase 4: friends/contacts and directory search.
--
-- `user_friends` is a directed edge so a relationship can exist one-way (a
-- user may add someone who has not added them back). The pair is the primary
-- key, which makes adding a friend idempotent, and the check prevents a
-- self-edge.
CREATE TABLE user_friends (
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    friend_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (user_id, friend_id),
    CHECK (user_id <> friend_id)
);

CREATE INDEX user_friends_user_id_idx ON user_friends (user_id);
CREATE INDEX users_lower_name_idx ON users (lower(name));
CREATE INDEX users_lower_phone_or_email_idx ON users (lower(phone_or_email));

COMMIT;
