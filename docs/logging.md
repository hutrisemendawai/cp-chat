# Realtime Logs

`rest`, `gateway`, and the Flutter app all write diagnostics into **one**
timeline that is visible live on `GET /logs`. The buffer is deliberately
short-lived: it is a debugging window with a hard **1-hour** retention, not an
audit log.

```
 Pino (rest)     ─┐
 Pino (gateway)  ─┼─▶ LogStore ─▶ Redis ZSET  cpchat:logs      (1 h retention)
 POST /logs/client┘                 │
                                    └─▶ PUBLISH cpchat:logs:live ─▶ SSE /api/v1/logs/stream
```

## Why a shared store

`rest` and `gateway` are separate containers, and either can run as several
replicas. A per-process ring buffer would show only the slice served by whichever
container answered the request, which is exactly the wrong thing when debugging a
WebSocket problem that the gateway saw but the API did not.

One Redis sorted set (`cpchat:logs`) keyed by the entry timestamp is the source of
truth; Pub/Sub (`cpchat:logs:live`) carries new entries to live-tail clients. Both
processes write into it, and the store survives a single process restart.

## Entry shape

```json
{
  "id": "b25b2f4c-8f9f-4b55-a5a0-6a1f6a2a1f31",
  "ts": 1763836800000,
  "service": "rest",
  "level": "info",
  "message": "request completed",
  "user_id": "…",
  "method": "GET",
  "path": "/api/v1/conversations",
  "status_code": 200,
  "duration_ms": 12,
  "meta": { "…": "…" }
}
```

`service` is `rest`, `gateway`, or `mobile`; `level` is one of `debug`, `info`,
`warn`, `error`, `fatal`.

## Retention and bounds

- **Time:** entries older than `LOG_RETENTION_SECONDS` (default **3600**, capped
  at 3600) are removed with `ZREMRANGEBYSCORE`.
- **Count:** beyond `LOG_MAX_ENTRIES` (default **5000**) the oldest are removed
  with `ZREMRANGEBYRANK`.
- Both run on a 60-second interval and opportunistically on writes (throttled to
  once every 5 seconds) and before every read, so a query never returns an
  expired entry.
- The key itself carries a TTL of `LOG_RETENTION_SECONDS + 300`, so a crashed
  deployment cannot leave data behind indefinitely.

## Redaction

Nothing sensitive is meant to leave the process. At write time the store:

- redacts by key — `authorization`, `cookie`, `password*`, `*token*`, `*secret*`,
  `content`, `plaintext`, `private_key`, prekeys — replacing the value with
  `[redacted]`;
- scrubs JWT-shaped strings and `e2ee:v1:` envelopes anywhere in a message or
  meta value, because a secret can appear inside an error string.

The mobile `AppLogger` applies the same rules before a `warn`/`error` entry leaves
the device.

## Pino bridge

`createLogger()` attaches a `pino.multistream` writable that forwards each line to
`LogStore.appendPinoLine()`. The write is fire-and-forget with a 2-second timeout
and a swallowed failure: a Redis hiccup can never fail a request or crash the
process. Fastify's own per-request line is replaced by an explicit
`request completed` entry carrying `method`, `path`, `status_code`, `duration_ms`,
and `user_id`.

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | `/api/v1/logs` | Query with `service`, `level`, `q`, `since`, `limit` |
| `GET` | `/api/v1/logs/stream` | SSE live tail (15 s `:keepalive`) |
| `POST` | `/api/v1/logs/client` | Mobile diagnostics (auth, 4 KB cap, rate-limited) |
| `DELETE` | `/api/v1/logs` | Clear the buffer |
| `GET` | `/logs` | Self-contained HTML dashboard |

`level` is a **minimum**: `?level=warn` returns `warn`, `error`, and `fatal`.

## Access control

When `LOG_VIEWER_TOKEN` is set, it is the only accepted credential for `/logs`,
`/api/v1/logs`, `/api/v1/logs/stream`, and `DELETE /api/v1/logs`, supplied as a
bearer token, `x-log-token` header, or `?token=`. When it is empty — the local
and LAN default — the viewer is open, and a bearer access token is decoded when
present so entries can be attributed. `POST /api/v1/logs/client` always requires
a signed-in user.

## Dashboard

`GET /logs` returns a single HTML document with inline CSS and JavaScript: no CDN,
no build step, so it works on a LAN with no internet access. It offers:

- service chips (`All`, `rest`, `gateway`, `mobile`) and level chips (`ALL`,
  `INFO`, `WARN`, `ERROR`);
- a live keyword search box;
- Pause/Resume auto-scroll and a Clear Logs button;
- a header with `Retention: 1 hour (auto-purge)`, the current entry count, and
  the SSE connection state;
- click-to-expand formatted JSON for any row.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `LOG_BUFFER_ENABLED` | `true` | Turns the store and its Pino bridge off entirely |
| `LOG_RETENTION_SECONDS` | `3600` | Maximum age (capped at 3600) |
| `LOG_MAX_ENTRIES` | `5000` | Maximum entries retained across the cluster |
| `LOG_VIEWER_TOKEN` | _(empty)_ | Optional shared secret for the viewer and log API |
