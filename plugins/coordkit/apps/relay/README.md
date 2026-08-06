# CoordKit relay server

The bundled relay is a dependency-free Node 20+ HTTP service. It provides
authenticated room isolation, durable fsynced append, `eid` deduplication,
conflicting-content rejection for reused `eid` values, validated server
acknowledgements, cursor replay, pagination, and optional long polling.

Run one process per data directory behind an HTTPS reverse proxy:

```bash
COORDKIT_RELAY_TOKEN='replace-me' \
COORDKIT_RELAY_DATA=/var/lib/coordkit-relay \
node server.mjs
```

For room-specific authorization, set `COORDKIT_RELAY_TOKENS` to a JSON map:

```json
{"token-for-team-a":["team-a"],"operator-token":["*"]}
```

Clients point `relay_url` at `https://your-host/v1/events`, set `room_id`, and
supply the token only through `COORDKIT_RELAY_TOKEN`. The service deliberately
does not terminate TLS; put Caddy, nginx, a cloud load balancer, or an ingress
in front of it. `/healthz` is unauthenticated. Do not run multiple relay
processes against the same data directory.

From the project repository that should join the room:

```bash
cobus init-relay https://your-host/v1/events team-a
export COORDKIT_RELAY_TOKEN='token-for-team-a'
cobus trust
cobus relay-sync
```

`init-relay` writes only the secret-free endpoint and room pointer. Review and
commit `.claude/coord/coord.toml`; arrange the token through your shell,
keychain, or secret manager. The separate `trust` step is intentionally local
to each machine.

For local-only development, bind to loopback and set
`COORDKIT_RELAY_INSECURE=1` on the server. The client must separately set
`COORDKIT_RELAY_ALLOW_INSECURE_HTTP=1`; it permits plaintext only for
`localhost`, `127.0.0.1`, or `[::1]`. Never expose insecure mode to a network.
