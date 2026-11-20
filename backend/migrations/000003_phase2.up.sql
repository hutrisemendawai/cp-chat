BEGIN;

-- Group avatars reuse the same media pipeline as chat attachments: the column
-- stores the object key returned by the media service.
ALTER TABLE conversations ADD COLUMN avatar_url TEXT;

-- Every uploaded object is tracked server-side so a presigned PUT can only be
-- used for a row the caller legitimately created, and so content-type/size are
-- bound to the key rather than trusted from the message body.
CREATE TABLE media_objects (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    owner_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    object_key TEXT NOT NULL UNIQUE,
    content_type VARCHAR(255) NOT NULL,
    size_bytes BIGINT NOT NULL CHECK (size_bytes > 0),
    original_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX media_objects_owner_id_idx ON media_objects (owner_id);

COMMIT;
