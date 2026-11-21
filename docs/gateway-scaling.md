# Gateway scaling and rolling deploys

The Chat Gateway is the only stateful process: each replica holds its own live
WebSocket connections. Scaling it out is therefore about **routing** (which
replica terminates which socket) and **draining** (moving clients off a replica
before it stops), not about sharing state.

## Why sticky sessions

A WebSocket is a single long-lived TCP connection. Once upgraded, every frame
for that client must reach the replica that owns the socket. Spread an upgrade
round-robin and the connection still works — it just lives on whichever replica
accepted it. What breaks is *reconnection storms*: if the load balancer hashes by
source IP and a large office NATs to one address, every client lands on one
replica.

Configure the balancer to hash on a stable client identifier for the upgrade and
keep the connection there for its lifetime:

- **nginx** (below) — `hash $arg_token consistent` on the upgrade location. The
  gateway already takes `?token=<jwt>`; the JWT is stable across reconnects
  until it expires, which is exactly the affinity window you want.
- **HAProxy** — `balance source` or, better, a `stick-table` keyed on the JWT
  query parameter.
- **Cloud LB** (ALB/NLB) — enable stickiness (target-group cookie / source-IP)
  and raise the idle timeout above the 25 s heartbeat.

Consistent hashing is preferred over source-IP hashing because it re-balances
only the affected keys when a replica is added or removed, instead of
reshuffling every client.

## Graceful drain

On `SIGTERM` the gateway:

1. flips `/readyz` to `503` (the load balancer stops sending new upgrades);
2. refuses new upgrades itself with `503 Retry-After: 1`;
3. closes live sockets with WebSocket code `1001` (going away);
4. waits up to `GATEWAY_DRAIN_TIMEOUT_MS` for closes, then terminates stragglers;
5. awaits in-flight close handlers (presence removal, `last_seen_at`) before
   closing database pools.

The Flutter client treats `1001` like any disconnect and reconnects with
exponential backoff plus jitter, so a fleet-wide rollout does not reconnect every
client at the same instant.

Set the container's stop grace period above the drain budget — Compose defaults
to 10 s, which would `SIGKILL` the process before its 30 s drain finished
(`stop_grace_period: 60s` in `docker-compose.yml`).

## Health endpoints

| Path | Meaning |
| --- | --- |
| `/healthz` | Process is alive and the event loop responds |
| `/readyz` | Ready to accept upgrades (false while starting or draining) |

Use `/healthz` for liveness and `/readyz` for readiness / LB health checks.

## Example nginx config

```nginx
upstream chat_gateway {
    # Consistent hashing keeps a client on one replica; `$arg_token` is the JWT
    # query parameter the Flutter client sends on the upgrade.
    hash $arg_token consistent;
    server gateway-1:8081 max_fails=3 fail_timeout=10s;
    server gateway-2:8081 max_fails=3 fail_timeout=10s;
    server gateway-3:8081 max_fails=3 fail_timeout=10s;
}

map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name ws.cpchat.example.com;

    location /ws {
        proxy_pass http://chat_gateway;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;

        # Above the 25 s heartbeat so an idle connection is not cut.
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;

        # Re-resolve DNS so a replaced replica is picked up.
        resolver 127.0.0.11 valid=10s;
    }

    location = /readyz {
        proxy_pass http://chat_gateway/readyz;
    }
}
```

The REST API is stateless and needs no affinity; balance it round-robin.

## Removing a replica without dropping messages

The gateway's state is fully recoverable, so a hard stop only costs in-flight
frames:

- `conn:` and `presence:` keys in Redis have a TTL and expire;
- clients sync from their local `seq` cursor on reconnect;
- the client outbox retries any send that never received a `sent` ack.

That is why a drain is about smoothness (avoid a burst of simultaneous
reconnects) rather than correctness.

## Testing a rollout locally

```bash
docker compose up -d --scale gateway=3 gateway   # or run 3 `npm run dev:gateway`
docker kill -s TERM <gateway-container>           # drains instead of killing
```

`backend/test/broker.test.ts` covers cross-replica routing and the drain path
(503 on upgrade, `1001` to live sockets, routing-map cleanup).
