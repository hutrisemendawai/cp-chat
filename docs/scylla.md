# ScyllaDB message store

PostgreSQL remains the default. `MESSAGE_STORE=scylla` moves the high-volume
message reads and writes to Cassandra/ScyllaDB, whose partition-by-conversation
model is what makes "newest 50 messages of this chat" a single-partition slice
instead of an index scan.

## Schema

`backend/migrations/cql/0001_messages.cql`:

```sql
CREATE TABLE messages_by_conversation (
    conversation_id uuid,
    seq bigint,
    message_id uuid,
    sender_id uuid,
    client_msg_id uuid,
    type text,
    content text,
    created_at timestamp,
    PRIMARY KEY (conversation_id, seq)
) WITH CLUSTERING ORDER BY (seq DESC);

CREATE TABLE messages_by_client_id (
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
```

- `conversation_id` is the partition key, `seq` the clustering key. Newest-first
  is the natural read direction; `ORDER BY seq ASC` serves sync.
- `messages_by_client_id` is the idempotency lookup that replaces Postgres's
  `UNIQUE (sender_id, client_msg_id)` on the read path.

## What still runs on PostgreSQL

The migration is partial by design. These stay in Postgres because Scylla cannot
provide them without losing a guarantee:

| Concern | Why Postgres |
| --- | --- |
| `conversations.last_seq` allocation | Needs a transactional, gap-free counter |
| Client-message idempotency on write | `ON CONFLICT` inside the same transaction as the seq bump |
| `message_receipts` / read cursors | Foreign keys and `GREATEST` updates |
| Full-text search | `tsvector` + GIN; Scylla has no equivalent |

New messages are written to Postgres first, then mirrored to Scylla after the
transaction commits. If the mirror fails it is logged, not fatal: the message is
already durable and readable from Postgres, and the backfill closes the gap.

## Enabling it

```bash
docker compose --profile scylla up -d scylla scylla-init   # or: make up-scale
# .env
MESSAGE_STORE=scylla
SCYLLA_CONTACT_POINTS=scylla:9042
```

`make up-scale` runs `scylla-init`, which applies every `backend/migrations/cql/*.cql`.

## Backfill

Existing messages live only in Postgres. Mirror them once:

```bash
make backfill-scylla                  # or: npm run ... / node scripts/backfill-scylla.mjs
make backfill-scylla args="--batch 1000"
```

The script pages Postgres by `(conversation_id, seq)` and writes both Scylla
tables in a batch. It is idempotent — re-running writes the same rows — so it is
safe to resume or re-run after a partial failure.

## Driver pitfalls (learned the hard way)

- **Prepare every statement.** An unprepared insert lets the driver infer a JS
  `number` as `double`; a `double` written into a `BIGINT` column stores the
  IEEE-754 bit pattern (`5` becomes `4617315517961601024`). `ScyllaMessageRepository.insert`
  passes `{ prepare: true }` for exactly this reason.
- **Unwrap driver types.** The driver returns `Uuid`/`Long` wrapper objects whose
  `toJSON()` adds quotes. Passing one to `pg` yields
  `invalid input syntax for type uuid: ""...""`. `mapRow` normalises every value
  to a plain string/number/Date.

## Consistency

The client uses `LOCAL_QUORUM`. On a single-node local cluster this resolves
trivially; on a multi-node ring it keeps a read-after-write consistent without a
cross-datacenter round trip.

## Compaction

`messages_by_conversation` uses `TimeWindowCompactionStrategy` (7-day windows),
which suits append-only chat history: old windows stop being rewritten once they
age out.

## Tests

```bash
SCYLLA_TEST=1 SCYLLA_CONTACT_POINTS=localhost:9042 npm test -- scylla
```

The suite asserts the Scylla read path returns byte-for-byte the same pages,
ordering, and `has_more` flags as the Postgres path for the same message stream,
and that receipt/read-cursor/search paths still work while history is served
from Scylla.

## Path to full migration

To retire the Postgres mirror, move the remaining concerns out:

1. **Seq allocation** → a per-conversation counter (Redis `INCR` or a
   `LWT`/`IF NOT EXISTS` guard in Scylla). This is the hard one; it must stay
   gap-free under retries.
2. **Idempotency** → `INSERT ... IF NOT EXISTS` on `messages_by_client_id`,
   returning the existing row on conflict.
3. **Search** → OpenSearch/Meilisearch fed from a CDC or application event.
4. **Receipts** → a separate Scylla table keyed by message.
