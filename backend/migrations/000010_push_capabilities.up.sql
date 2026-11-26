-- Track client push capability version so upgraded clients can receive
-- high-priority data-only FCM payloads and decrypt E2EE messages locally in the
-- background isolate, while older installs keep receiving legacy notification
-- payloads.

ALTER TABLE device_tokens
  ADD COLUMN push_version SMALLINT NOT NULL DEFAULT 1 CHECK (push_version >= 1);
