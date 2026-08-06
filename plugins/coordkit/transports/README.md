# coordkit transports — the shareable spectrum

One tiny `LogStore` interface, pluggable adapters. The coordination event log sits
behind four shell functions; an adapter selected by config services them. Because
**projections are always recomputed from the union of events**, the read path is
byte-for-byte identical in every mode — switching modes never changes what readers
see, only how events travel between machines.

```
ledger scripts ─► logstore_append / logstore_readall / logstore_tail / logstore_mode
                          │  (transports/lib.sh — dispatcher + shared helpers)
                          ▼
        ┌─────────────┬─────────────┬─────────────┐
        │   local     │     git     │    relay    │
        │  (default)  │ (team async)│ (real-time) │
        └─────────────┴─────────────┴─────────────┘
```

## The spectrum: local → git → relay

| mode  | sharing            | transport                     | deps        | source of truth |
|-------|--------------------|-------------------------------|-------------|-----------------|
| local | same machine only  | per-actor files on local disk | none        | local segments  |
| git   | team, asynchronous | committed segments + git push | git         | committed log   |
| relay | team, near-real-time | authenticated POST + cursor replay | curl + backing + relay server | local/git backing plus server replay log |

- **local** (default): exactly today's same-machine behaviour. Each actor appends to
  its own `.coordkit-bus/log/<actor>/seg.ndjson`; `readall` is the union of all those
  segments plus the legacy flat `ledger.jsonl`. Zero network, zero daemons, fast.
- **git**: each actor appends to its own `.claude/coord/log/<actor>/<epoch>-NNNN.ndjson`.
  That `log/` path is **gitignored on your branch** — replication happens entirely inside
  a **private, gitignored worktree** at `.claude/coord/.sync`, checked out to a dedicated
  branch (`coordkit/log`, override `COORDKIT_SYNC_BRANCH`) of the same remote. A
  **debounced, out-of-hook** timer (`bin/sync.sh` → `__git_sync`) copies grown local
  segments into that worktree, commits there, `fetch`+`rebase`es onto the remote log
  branch, `push`es, then copies peers' segments back down into `log/`. **Sync never
  touches your checkout, index, or branch** — no `git add`/commit/rebase/push ever runs
  against your working branch. Because writers only ever touch their own files there are
  no structural conflicts; `*.ndjson merge=union` (committed on the log branch) is a
  backstop only. Only the secret-free pointer (`coord.toml`, `.gitattributes`,
  `MANIFEST.json`) is committed on your branch.
- **relay**: an authenticated delivery accelerator on top of a durable local or
  git backing. Appends are staged in an on-disk outbox, POSTed with acknowledgement,
  and replayed from a server cursor before reads. A dependency-free reference
  server is bundled under `plugins/coordkit/apps/relay/`.

## Graceful degradation: relay → git → local (each a no-op cutover)

Because every mode reconstructs state from the **union of events**, dropping down a
level changes nothing a reader can observe — only delivery latency and reach.

```
relay down ─► git   : queue in the outbox; events also replicate on the next git sync.
git down   ─► local : stop pushing; events still recorded locally, shared later.
```

Concretely:
- The **relay** adapter folds every event into its durable backing **before**
  staging an outbox record. A POST failure is non-fatal and retryable; the next
  append, read, or `cobus relay-sync` flushes pending records.
- Relay reads pull authenticated NDJSON pages after the last locally committed
  server cursor. The cursor advances only after every returned event has been
  folded into the backing, so a crash replays rather than drops the page. Server
  deduplication by `eid` makes retries safe. If a restored/replaced server
  reports a lower latest cursor, the client rewinds and safely replays instead
  of remaining stuck beyond the server's new sequence.
- If the durable fold itself fails, `lib.sh` retries **the configured backing FIRST**
  (`COORDKIT_RELAY_BACKING`, default `local`) and only then spills to the other stores.
  This ordering matters: relay-mode **reads come from the backing**, so spilling to a
  different store would persist the event yet hide it from relay readers. Retrying the
  backing first keeps the event visible; the wider spill is a last-resort durability net.
  The re-append is idempotent because **dedup is by `eid`** (content-addressed), so a
  doubled append collapses to one event on read.
- Switching `mode` is a safe cutover for the READ path either direction — readers always
  recompute the same projection from the union of events. The one place data actually
  needs to move is **local → git**, because the two modes read different trees
  (`local`: `.coordkit-bus/log` + legacy `.coordkit-bus/ledger.jsonl`; `git`: `.claude/coord/log`).
  `scripts/init-git.sh` handles that with a **one-time migration** on `init-git`: it copies
  the prior local segments (and folds the legacy flat ledger under a synthetic actor) into
  `.claude/coord/log/`. It is a copy of append-only files and is idempotent (never shrinks
  a file), so re-running is safe.

## Privacy rule — the activity firehose stays local

coordkit's PostToolUse hook records a high-frequency **activity firehose**: every
file touch and every `Bash` invocation, written to `.coordkit-bus/activity.log`. That
stream is **local-only and MUST NOT replicate cross-team.**

- Only **deliberate ledger events** (notes, decisions, tasks, claims, answers — the
  things you explicitly emit) are eligible to travel via git/relay.
- The raw `activity.log` is never appended through `logstore_append`, never replicated
  by `__git_sync` (which only ever copies/commits `.claude/coord/log` inside its private
  `.sync` worktree), and never POSTed to a relay.
- Keep it that way: replicating the firehose would leak every command and path your
  teammates' machines run, at enormous volume, for no coordination benefit.

## Honest caveats — cross-machine claims are ADVISORY

Going multi-machine relaxes guarantees that hold trivially on one box. Be explicit:

- **Claims/leases are advisory, not mutually exclusive.** Two machines can briefly
  hold the "same" claim. The **double-claim window = sync latency** (git debounce
  interval, or relay round-trip). This is a coordination hint, not a distributed lock.
- **Cross-machine lease reclaim is TTL-only.** A stale lease is reclaimed purely by
  its TTL expiring, because **heartbeats stay local** (they're part of the local
  activity stream, which never replicates — see the privacy rule). A remote holder's
  liveness can't be observed directly; only the TTL bounds how long a dead holder
  blocks others.
- **Eventual, not immediate, consistency.** Git peers converge on the next
  debounced sync. Relay peers converge on their next hook/read/sync pull. The
  server acknowledges durable receipt, but it does not turn task claims into a
  distributed mutex.

## Relay deployment and authentication

Run `plugins/coordkit/apps/relay/server.mjs` with Node 20+ or build `plugins/coordkit/apps/relay/Dockerfile`. Require either
`COORDKIT_RELAY_TOKEN` or a `COORDKIT_RELAY_TOKENS` JSON map of token to allowed
rooms. The server binds to loopback by default and should sit behind an HTTPS
reverse proxy for cross-machine use. Clients keep tokens in the environment,
never in committed `coord.toml`.

The client refuses every non-loopback plaintext HTTP URL, even when insecure
mode is requested. Loopback HTTP is for local development only and additionally
requires `COORDKIT_RELAY_ALLOW_INSECURE_HTTP=1`; HTTPS needs no opt-in. URL
validation happens before the temporary bearer-header file is created or curl
is invoked.

The server provides durable fsynced append, per-room bearer authorization,
`eid` deduplication with conflicting-content rejection, cursor pagination,
validated acknowledgement, and optional long polling. It enforces a single
process per data directory. See
`plugins/coordkit/apps/relay/README.md` for deployment settings.

## Incremental reads: use per-actor cursors

- `logstore_actor_cursors` returns a compact JSON map of each actor to its
  highest persistent monotonic `clock.c`. Save it, then call
  `logstore_since_actor_cursors <json> [legacy-watermark]`. A newly synced actor
  or a higher counter is detected even when wall-clock skew makes its event sort
  before the previous global watermark. CoordKit's automatic ledger context
  uses this API.
- `logstore_since <watermark>` is retained for compatibility. Its total-order
  key `p:c:actor` is stable, but a newly arriving event that sorts before that
  one global key cannot be detected. The optional legacy watermark in the actor
  API applies only to old envelopes without a usable actor/counter.
- `logstore_tail <n>` is **legacy and lossy**. It counts `n` events into the total order,
  but that order is recomputed on every call, so a late event that sorts earlier shifts
  positions and the count-based boundary can skip a real event or re-emit one. Kept only
  for back-compat; use `logstore_since`.

## The LogStore interface (for adapter authors)

`transports/lib.sh` exposes the public functions and the shared helpers
`__dedup_by_eid` (keep first per `eid`; stable per-line fallback for legacy lines)
and `__total_order` (stable sort by `clock.p`, `clock.c`, `actor`). Each adapter
implements `__<mode>_append`, `__<mode>_readall`, `__<mode>_tail`, and
`__<mode>_lockfile`; `lib.sh` selects and calls them. For **local** and **git**,
`lib.sh` owns the append lock so those adapters inherit atomic appends for free —
via `flock(1)` when present (with a bounded `-w` wait so a wedged holder can't stall
every hook), or a bounded `mkdir`-based mutex as a fallback where `flock` is missing
(e.g. stock macOS), and a true append failure propagates a non-zero return to the
caller. **relay is special-cased**: it is not wrapped a second time — it drives its
own configured backing (`local`/`git`) through that same locked-append helper, then
does its best-effort fan-out on top.
