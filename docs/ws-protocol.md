# WebSocket Protocol

The Chat Gateway exposes a single WebSocket endpoint:

```
wss://<host>/ws?token=<access_token>
```

The JWT access token may be passed as the `token` query parameter (Flutter's
`web_socket_channel` cannot set arbitrary headers reliably on Android) or as an
`Authorization: Bearer <token>` header. The gateway rejects the upgrade with
`401` when the token is missing, expired, or invalid.

All frames are UTF-8 JSON text frames. Binary frames are never used; media
travels through pre-signed object-storage URLs.

## Envelope

Every frame has a `type` field. Server responses may include an `error` object
instead of the expected payload:

```json
{ "type": "error", "code": "not_a_member", "message": "You are not a member of c1" }
```

Unknown `type` values are ignored by clients. Unknown server event types must be
ignored by clients as well, so fields can be added without breaking older app
versions.

## Connection lifecycle

1. Client opens the socket with a valid access token.
2. Gateway registers the connection: `conn:{user_id}:{device_id} -> node_id` in
   Redis, plus presence key `presence:{user_id}` with a 45 s TTL. Multiple
   devices of the same user get one `conn:` key each; routing therefore targets
   every live device, not just one.
3. Client flushes its local outbox (Phase 1) and calls the REST sync endpoint for
   each conversation where `server_seq > local_seq`.
4. Client sends `ping` every 25 s; the gateway replies with `pong`. Two missed
   pongs (or a failed heartbeat) triggers a reconnect with exponential backoff
   (1 s, 2 s, 4 s, ... capped at 30 s, with jitter).
5. On reconnect the client re-runs step 3 before accepting live messages.

A gateway replica may be drained for a rolling deploy or scale-in. It then
answers `/readyz` with `503`, refuses new upgrades, and closes live sockets with
`1001` (going away). The client treats this exactly like any other disconnect
and reconnects to a healthy replica; nothing beyond in-flight frames is lost,
because the outbox and `seq` sync recover them.

Messages delivered while a client is offline are not replayed on the socket;
they are recovered through `GET /api/v1/conversations/{id}/sync?after_seq=`.

## Client -> Server events

### `send` — publish a message

```json
{
  "type": "send",
  "conversation_id": "c1",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "msg_type": "text",
  "content": "Hello!"
}
```

- `client_msg_id` is a UUIDv4 generated on the device and persisted in the local
  outbox before the frame is written. Retries reuse the same value, so
  `UNIQUE (sender_id, client_msg_id)` makes delivery idempotent.
- `msg_type` is one of `text`, `image`, `file`. For media, `content` is the
  object key returned by `POST /api/v1/media/presign` (see [Media](#media)). The
  client uploads the bytes to the presigned PUT URL *before* sending this frame,
  so recipients can resolve the object immediately.
- **Direct-chat `text` is end-to-end encrypted.** `content` is then
  `e2ee:v1:<json>` rather than plaintext; the gateway relays it untouched and
  validates only its shape. See [End-to-end encryption](#end-to-end-encryption).
- The gateway acknowledges with a `status` event carrying `status: "sent"` and
  the assigned `seq`. If no ACK arrives before the client timeout, the outbox
  entry is retried with backoff.

### End-to-end encryption

A direct-chat text body is an envelope the server cannot read:

```
e2ee:v1:{"v":1,"ik":"...","ek":"...","spk":42,"opk":43,"i":0,"ct":"...","n":"...","m":"..."}
```

| Field | Meaning |
| --- | --- |
| `ik` | Sender's identity public key (X25519, base64) |
| `ek` | Sender's ephemeral public key — present only on the session-opening message |
| `spk` / `opk` | Signed-prekey and one-time-prekey ids consumed from the recipient's bundle |
| `i` | Position in the sender's ratchet chain |
| `ct`, `n`, `m` | AES-256-GCM ciphertext, nonce, and authentication tag |

The gateway:

- relays a valid envelope unchanged and stores it as the message `content`;
- **rejects** (`validation_error`) a body with the `e2ee:v1:` prefix that is not
  a well-formed envelope, so a corrupt encrypted body is never delivered as
  text;
- never logs or inspects `ct` (content is redacted from logs).

The recipient decrypts on arrival and persists plaintext locally; a body it
cannot decrypt is stored as-is and rendered as a placeholder. Group and media
messages are not encrypted in this phase. Full protocol: [e2ee.md](./e2ee.md).


### Fan-out

A message is stored once. The gateway then fans out on write:

- **Direct conversations** deliver the `message` frame to the other member.
- **Groups** deliver the same frame to every other member in one pass. Member
  ids come from a Redis cache (`members:{conversation_id}`) that is invalidated
  on any membership change, so a removed member stops receiving immediately.
- Members with no live gateway connection receive an FCM push instead.

Fan-out is best-effort per recipient: a member whose node is unreachable is
still caught up by the `sync` endpoint on their next connect.

### Multi-device

A user may hold several sockets (one per logged-in device). The gateway keeps a
`conn:{user_id}:{device_id}` key per device and routes to all of them:

- A `send` from one device is echoed as a `message` frame to the sender's *other*
  devices, so their history stays in sync without a REST call. The originating
  device only receives the `sent` ack. A retried `client_msg_id` is idempotent.
- A `read` ack from one device sends a [`read_state`](#read_state--cross-device-read-cursor)
  frame to the sender's other devices.
- Presence is per user, not per device: a user goes offline only once their last
  device disconnects.

### `ack` — update a delivery/read cursor

```json
{
  "type": "ack",
  "conversation_id": "c1",
  "seq": 42,
  "status": "delivered"
}
```

- `status` is `delivered` or `read`.
- `read` updates `conversation_members.last_read_seq` to the largest acknowledged
  `seq` (never moves backwards).
- `delivered` is sent automatically by the client when a `message` event is
  persisted locally, including for messages received while the chat is closed.

### `ping` — heartbeat

```json
{ "type": "ping" }
```

The server replies with `{ "type": "pong" }`.

## Server -> Client events

### `message` — incoming message

```json
{
  "type": "message",
  "conversation_id": "c1",
  "message_id": "9f5a...",
  "seq": 42,
  "sender_id": "u1",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "msg_type": "text",
  "content": "Hello!",
  "created_at": "2026-11-20T08:00:00Z"
}
```

- Ordering is guaranteed by `seq`, never by `created_at`. If a gap is detected
  (`seq > local_latest_seq + 1`) the client calls the REST sync endpoint before
  appending further messages.
- A message echoed to its own sender carries the same `client_msg_id`, which the
  client reconciles with the optimistic local row instead of duplicating it.

### `status` — message lifecycle update

```json
{
  "type": "status",
  "conversation_id": "c1",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "seq": 42,
  "status": "delivered"
}
```

- `status` is one of `sent`, `delivered`, `read`.
- `sent` is sent only to the originating socket, `delivered` once the recipient
  device persists the message, `read` when the recipient acknowledges it.
- In groups, `read` is aggregated: the sender receives a [`read_receipt`](#read_receipt--aggregated-group-receipt)
  frame with a member count instead of one `status` event per reader.

### `read_receipt` — aggregated group receipt

```json
{
  "type": "read_receipt",
  "conversation_id": "c1",
  "reader_id": "u2",
  "seq": 42,
  "sender_id": "u1",
  "client_msg_id": "550e8400-e29b-41d4-a716-446655440000",
  "read_count": 7,
  "member_count": 12
}
```

- Sent to the original sender when any member of a group reads up to `seq`.
- `read_count` is the number of members other than the sender whose
  `last_read_seq >= seq`; `member_count` excludes the sender.
- Only emitted for `group` conversations. Direct chats keep per-message
  `status: read`.

### `conversation_updated` — membership or metadata changed

```json
{
  "type": "conversation_updated",
  "conversation_id": "c1"
}
```

- Emitted when a group is created, renamed, its avatar changes, or members are
  added/removed. It carries no payload; the client refetches the conversation.
- A removed member receives it too, so their client can drop the conversation
  locally. A refetch returns `403`/`404`, which the client treats as "delete".
- Clients must ignore it for conversations they do not have locally.

### Media

1. Client compresses the image (if any) and uploads the bytes with
   `POST /api/v1/media/upload` (raw body, `Content-Type` and `x-filename`
   headers), which receives `object_key`. This path only needs the API host, so
   it works from a physical phone that cannot reach the storage host directly.
   `POST /api/v1/media/presign` remains available for clients that can `PUT`
   straight to object storage.
2. Client sends a `send` frame with `msg_type: "image" | "file"` and
   `content` set to `object_key`.
3. Recipients render via `GET /api/v1/media/{object_key}`, which authorizes the
   caller and streams the bytes through the API. `?proxy=0` redirects to a
   short-lived presigned GET instead. The bucket is private.

Sending a message while the socket is down is not an error: the row stays in
the local outbox and `ChatSocket.send()` starts a connect, so it flushes as soon
as the socket is up. A screen shows a reconnect banner while the socket is down.

### `read_state` — cross-device read cursor

```json
{
  "type": "read_state",
  "conversation_id": "c1",
  "seq": 42
}
```

- Sent to the reader's other devices when one device acks `read` up to `seq`.
- The receiving device advances its local read cursor and clears the unread
  badge, so reading a chat on a phone also clears it on a tablet.
- It carries no sender identity: it is only delivered to the same user.

### `presence` — online state change

```json
{
  "type": "presence",
  "user_id": "u1",
  "online": false,
  "last_seen_at": "2026-11-20T08:00:00Z"
}
```

- Delivered to every user who shares at least one conversation with `user_id`.
- `online: true` is broadcast when a user's *first* device connects;
  `online: false` when their *last* device disconnects. A second device coming or
  going does not change the state, so peers see no flapping.
- `last_seen_at` is present on an offline transition and is the durable
  `users.last_seen_at` value; it is `null` on the online transition.
- Not replayed to late subscribers: a client opening a chat should fetch the
  current snapshot from `GET /api/v1/presence/{id}` (see the REST spec) and then
  apply subsequent frames.

## Delivery guarantees

| Property | Mechanism |
| --- | --- |
| No loss | Client outbox + `client_msg_id` dedupe + REST sync on reconnect |
| No duplicates | `UNIQUE (sender_id, client_msg_id)` on the server, `client_msg_id` primary key locally |
| Strict ordering | Monotonic per-conversation `seq` assigned inside the storage transaction |
| At-least-once | Unacknowledged `send` frames are retried until a `sent` status arrives |

Per-conversation `seq` is authoritative. The server never trusts client clocks;
`created_at` is display-only metadata.
