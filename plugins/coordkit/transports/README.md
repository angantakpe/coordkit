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
| relay | team, real-time    | fan-out POST over a durable backing | curl + backing | the **backing** (local/git), never the relay |

- **local** (default): exactly today's same-machine behaviour. Each actor appends to
  its own `.claude-bus/log/<actor>/seg.ndjson`; `readall` is the union of all those
  segments plus the legacy flat `ledger.jsonl`. Zero network, zero daemons, fast.
- **git**: each actor appends to its own `.claude/coord/log/<actor>/<epoch>-NNNN.ndjson`
  and a **debounced, out-of-hook** timer (`bin/sync.sh` → `__git_sync`) does
  `pull --rebase` then `push`. Because writers only ever touch their own files, there
  are no structural conflicts; `*.ndjson merge=union` is a backstop only.
- **relay**: an optional real-time fan-out **cache** on top of a durable backing
  (local or git). Currently a degraded stub — see caveats.

## Graceful degradation: relay → git → local (each a no-op cutover)

Because every mode reconstructs state from the **union of events**, dropping down a
level changes nothing a reader can observe — only delivery latency and reach.

```
relay down ─► git   : stop fanning out; events still replicate on the next git sync.
git down   ─► local : stop pushing; events still recorded locally, shared later.
```

Concretely:
- The **relay** adapter folds every event into its durable backing **before** the
  best-effort POST. A POST failure is non-fatal — the event is already persisted.
- If the durable fold itself fails, `lib.sh` falls back **git → local** automatically.
  The re-append is idempotent because **dedup is by `eid`** (content-addressed), so a
  doubled append collapses to one event on read.
- Switching `mode` in `coord.toml` (or `COORDKIT_MODE`) is therefore a safe cutover in
  either direction; no migration, no data move — readers recompute the same projection.

## Privacy rule — the activity firehose stays local

coordkit's PostToolUse hook records a high-frequency **activity firehose**: every
file touch and every `Bash` invocation, written to `.claude-bus/activity.log`. That
stream is **local-only and MUST NOT replicate cross-team.**

- Only **deliberate ledger events** (notes, decisions, tasks, claims, answers — the
  things you explicitly emit) are eligible to travel via git/relay.
- The raw `activity.log` is never appended through `logstore_append`, never committed
  by `__git_sync` (which only stages `.claude/coord/log`), and never POSTed to a relay.
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
- **Eventual, not immediate, consistency** in git mode: peers converge on the next
  debounced sync, not instantly. relay narrows this window but, as a cache, never
  makes it zero or authoritative.

## The LogStore interface (for adapter authors)

`transports/lib.sh` exposes the public functions and the shared helpers
`__dedup_by_eid` (keep first per `eid`; stable per-line fallback for legacy lines)
and `__total_order` (stable sort by `clock.p`, `clock.c`, `actor`). Each adapter
implements `__<mode>_append`, `__<mode>_readall`, `__<mode>_tail`, and
`__<mode>_lockfile`; `lib.sh` selects and calls them, owning the `flock` so every
adapter inherits atomic appends for free.
