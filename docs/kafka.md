# Kafka transport

Phase 1–3 fanned realtime frames out over Redis Pub/Sub. Phase 4 can move the
same traffic onto Apache Kafka so the stream is durable, replayable, and
partitioned. Redis stays the default; Kafka is opt-in.

## When to use it

Pub/Sub is fire-and-forget: a gateway node that is briefly down misses every
frame published in that window. That is acceptable when a recipient's client
reconciles with `GET /sync` on reconnect. Kafka is worth the operational cost
when you want:

- delivery that survives a consumer restart;
- per-conversation ordering guaranteed by the partition key;
- an audit/replay path over realtime events;
- consumer-group scaling for inbound message processing.

## Enabling it

```bash
docker compose --profile kafka up -d kafka     # or: make up-scale
# .env
BROKER=kafka
KAFKA_BROKERS=kafka:9092
```

The gateway refuses to start with `GATEWAY_ASYNC_INGEST=true` unless
`BROKER=kafka`.

## Topics

| Topic | Key | Producers | Consumers |
| --- | --- | --- | --- |
| `chat.events` | `c:<conversation_id>` or `u:<user_id>` | any node (routed/broadcast frames) | every gateway replica |
| `chat.inbound` | `c:<conversation_id>` | gateway on an accepted send | `message-service` group |

`chat.events` carries two envelope kinds:

```jsonc
// addressed to one node (deliver to that node's local sockets)
{ "kind": "routed", "targetNode": "node-3", "userId": "u1", "frame": { ... } }

// fan-out to a set of users across all nodes
{ "kind": "broadcast", "user_ids": ["u1","u2"], "frame": { ... } }
```

## Consumer groups

Every gateway replica uses its **own** consumer group (`gateway-<node_id>`), so
each replica reads every partition and can deliver to the sockets it owns.

> A shared group would split partitions across replicas. A frame for a user
> connected to replica A would land on replica B, whose socket map does not
> contain that user, and the frame would be dropped. Do not switch to a shared
> group without a presence-aware router.

The cost is that each replica reads the whole stream. That is fine because the
events are small and fan-out is already the dominant cost; a presence-aware
router (map user → node, then produce only to that node's topic) is the
documented next optimisation.

## What each replica does with a frame

- `routed` addressed to another node: skip.
- `routed` to this node: write to the matching socket(s), honouring
  `excludeDevice` (never echo to the sender's device) and `onlyDevice` (targeted
  acks).
- `broadcast`: write to every local socket for the listed users.

## Ordering

The producer key is `c:<conversation_id>` for anything tied to a conversation, so
every message for that chat is written to one partition and consumed in order.
A `seq` allocated by the storage layer is the real ordering guarantee; the
partition key keeps a consumer from seeing `seq: 5` before `seq: 4`.

## Async ingestion

With `GATEWAY_ASYNC_INGEST=true`, `send` handling becomes:

1. validate (`conversation_id`, UUIDv4 `client_msg_id`, type, content, membership);
2. publish to `chat.inbound` keyed by conversation;
3. return.

A consumer in the `message-service` group allocates `seq`, persists, emits the
`sent` ack to the originating device (routed to whichever node holds it), and
fans out.

This decouples gateway latency from the storage transaction and lets you scale
message processing independently. Redelivery is safe because `append()` is
idempotent on `client_msg_id`.

## Operational notes

- **First-message latency after a deploy.** A consumer resolves its start offset
  (`fromBeginning: false`) at assignment time. A publish that races the join is
  delivered after the rebalance. Client retries (outbox) cover this; do not
  treat it as message loss.
- **Topic creation.** The producers use `allowAutoTopicCreation`, so topics
  appear on first publish. Pre-create them with an explicit partition count for
  production (`KAFKA_NUM_PARTITIONS`, default 12).
- **Retention.** Default broker retention applies. Realtime frames do not need a
  long window; `chat.inbound` should be at least as long as the longest consumer
  outage you want to survive.
- **TLS/SASL.** Not configured in the local Compose stack. In production set
  `KAFKA_BROKERS` to SASL endpoints and extend the `Kafka` client config in
  `backend/src/lib/broker.ts` with `ssl`/`sasl`.

## Tests

Kafka tests run against a real broker and are skipped when `KAFKA_BROKERS` is
unset:

```bash
KAFKA_BROKERS=localhost:9092 npm test -- kafka inbound
```
