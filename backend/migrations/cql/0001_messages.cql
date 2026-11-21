-- Phase 4: wide-column message store (Cassandra / ScyllaDB).
--
-- The access patterns drove this design:
--   1. read the newest N messages of one conversation  -> `messages_by_conversation`
--   2. catch up everything after a seq (offline sync)   -> same table, ASC slice
--   3. find a message by seq (receipts, read cursors)   -> same table, exact row
--   4. dedupe a retried client_msg_id                   -> `messages_by_client_id`
--
-- A message is written to both tables in one batch, so a retried send is
-- idempotent and the "newest first" read is a single-partition slice ordered by
-- the clustering key, which is the whole point of moving off Postgres here.
--
-- Postgres remains the source of truth for `seq` allocation, membership, and
-- full-text search (see domain/message-store.ts for how the two are kept in
-- sync). Partitioning by conversation_id keeps a conversation on one token
-- range, so seq-ordered reads never cross nodes.

CREATE KEYSPACE IF NOT EXISTS cp_chat
  WITH replication = {'class': 'SimpleStrategy', 'replication_factor': 1}
  AND durable_writes = true;

USE cp_chat;

CREATE TABLE IF NOT EXISTS messages_by_conversation (
    conversation_id uuid,
    seq bigint,
    message_id uuid,
    sender_id uuid,
    client_msg_id uuid,
    type text,
    content text,
    created_at timestamp,
    PRIMARY KEY (conversation_id, seq)
) WITH CLUSTERING ORDER BY (seq DESC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy', 'compaction_window_unit': 'DAYS', 'compaction_window_size': 7};

-- Idempotency: UNIQUE (sender_id, client_msg_id) in the Postgres sense.
CREATE TABLE IF NOT EXISTS messages_by_client_id (
    sender_id uuid,
    client_msg_id uuid,
    conversation_id uuid,
    seq bigint,
    message_id uuid,
    type text,
    content text,
    created_at timestamp,
    PRIMARY KEY ((sender_id, client_msg_id))
);
