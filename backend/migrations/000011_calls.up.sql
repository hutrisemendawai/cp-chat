CREATE TABLE calls (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    room_name       TEXT NOT NULL UNIQUE,
    type            VARCHAR(10) NOT NULL CHECK (type IN ('1on1', 'group')),
    media_type      VARCHAR(10) NOT NULL CHECK (media_type IN ('voice', 'video')),
    initiated_by    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    status          VARCHAR(16) NOT NULL CHECK (
                        status IN ('ringing', 'active', 'ended', 'missed', 'rejected', 'cancelled', 'busy', 'failed')
                    ),
    ring_expires_at TIMESTAMPTZ,
    started_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    answered_at     TIMESTAMPTZ,
    ended_at        TIMESTAMPTZ,
    end_reason      VARCHAR(32)
);

-- At most one live (ringing or active) call per conversation at any moment.
-- Prevents split LiveKit rooms on concurrent group taps or simultaneous 1:1 calls.
CREATE UNIQUE INDEX calls_one_live_per_conversation_idx
    ON calls (conversation_id)
    WHERE status IN ('ringing', 'active');

CREATE INDEX calls_ringing_expires_idx
    ON calls (ring_expires_at)
    WHERE status = 'ringing';

CREATE TABLE call_participants (
    call_id   UUID NOT NULL REFERENCES calls(id) ON DELETE CASCADE,
    user_id   UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    state     VARCHAR(16) NOT NULL CHECK (
                  state IN ('ringing', 'joining', 'joined', 'left', 'rejected', 'missed')
              ),
    joined_at TIMESTAMPTZ,
    left_at   TIMESTAMPTZ,
    PRIMARY KEY (call_id, user_id)
);

CREATE INDEX call_participants_user_active_idx
    ON call_participants (user_id)
    WHERE state IN ('ringing', 'joining', 'joined');
