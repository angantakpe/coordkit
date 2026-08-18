# Cross-machine task dispatch — `cobus dispatch`

`cobus dispatch` hands a ledger task from one machine to another — either to a
**specific** machine (`--to desktop`), or to **whoever is capable and idle**
(`--needs gpu=1`) — with a **lease** so nothing is lost when a laptop lid
closes, and a wake-up so the target picks it up in near-real-time (relay mode)
or on its next sync (git mode). It is a thin state machine projected from
append-only events written through the same LogStore the ledger uses
(`transports/lib.sh`), so it works unchanged in `local`, `git`, and `relay`
mode. Implementation: `plugins/coordkit/scripts/core/scripts/dispatch.sh`
(dist wrapper `plugins/coordkit/scripts/dispatch.sh`; wired as `cobus dispatch`).

## 1. The model

A **dispatch** is a request: "task `T` should be worked by someone matching
selector `S`, who gets a lease of `L` seconds once they accept". It has an id
(`d-<hex>`), refers to a normal ledger task subject (created for you if the
title is new — the same `ledger.sh task` path `/led task` uses), and lives in
the shared log as a family of events:

| event                | who writes it              | payload (in `body` as JSON, mirrored top-level as `dispatch`)      |
|----------------------|----------------------------|--------------------------------------------------------------------|
| `dispatch`           | the requester              | `{id, task, title, target:{machine?,actor?,needs{}}, lease_s, priority, note, from:{machine,actor}, ts}` |
| `dispatch.accepted`  | the target machine         | `{id, task, by:{machine,actor}, lease_until, epoch, ts}`            |
| `dispatch.renewed`   | the holder                 | `{id, by, lease_until, ts}`                                         |
| `dispatch.released`  | the holder                 | `{id, by, reason, ts}`                                              |
| `dispatch.expired`   | any reaper                 | `{id, holder, lease_until, reaped_by, ts}`                          |
| `dispatch.done`      | holder or requester        | `{id, by, ts}`                                                      |

The envelope is the normal v2 event envelope (`protocol/event.schema.json`)
with `subject` = dispatch id, plus a top-level `machine` (human machine name)
and no `seq` (deliberately — that keeps dispatch traffic out of the ledger's
seq-keyed digest/board projections; the ledger sees the *task* through the
ordinary `task` / `claim` / `done` events dispatch.sh emits via `ledger.sh`).
Payload schema: `protocol/dispatch.schema.json`.

### States (a projection — recomputed on every read)

```
              accept                 done
   open  ───────────────►  accepted ───────►  done
    ▲                        │  │
    │      release           │  │  reap (lease lapsed)
    ├────────────────────────┘  │
    │  (state: released)        │
    └───────────────────────────┘
       (state: expired)
```

- `open`, `released`, `expired` are all **acceptable** — `accept --auto`
  treats them the same; `released`/`expired` are kept as distinct states so
  `ls` tells you *why* it is back on the board.
- `accepted` carries a holder (`machine/actor`) and `lease_until`. `ls` shows
  the remaining seconds, or `LAPSED Ns` once it is overdue but not yet reaped.
- `done` is terminal and also marks the ledger task done.
- Every release/expiry bumps the dispatch's **epoch** (1 on creation). Accepts
  are tagged with the epoch they target.

### Identity: machine, actor, caps

Dispatch matches on three things, resolved identically to `cobus heartbeat`
(the presence side, see §5):

| what      | resolution                                                                                   |
|-----------|----------------------------------------------------------------------------------------------|
| `machine` | env `COORDKIT_MACHINE` > `coord.toml` `[machine] name = "..."` > `hostname -s` > `$HOSTNAME`  |
| `actor`   | the stable coordkit site id (`ck_actor`, from `$(ck_data_dir)/site.json`)                    |
| `caps`    | `coord.toml` `[machine] caps = "gpu=1,os=linux"` **or** `caps = ["gpu","docker"]` **or** a `[machine.caps]` table (`gpu = "1"`), then overridden key-by-key by env `COORDKIT_CAPS="k=v,k2=v2"`. A bare key means `true`. |

`cobus dispatch whoami` prints what the matcher will use on this box. Note
`COORDKIT_HOST` is **not** the machine name — it is the host *adapter*
identity (`claude-code`/`codex`/`cli`) that the envelope's `host` field
already carries; the machine name is a separate axis.

### Selector matching

`--to <machine>` / `--to <machine>/<actor>` require an exact match.
`--needs k=v,k2=v2` requires every key to be present and truthy in the
acceptor's caps, and — for a non-`*` value — equal as a string. Both may be
combined. No selector at all means "anyone".

## 2. Commands

```
cobus dispatch <task-id|"title"> [--to <machine|machine/actor>] [--needs k=v,...]
               [--lease <secs>] [--priority N] [--note "..."] [--quiet]
cobus dispatch accept [<dispatch-id>|--auto] [--quiet]
cobus dispatch renew <id> [--lease <secs>]
cobus dispatch release <id> [--reason "..."]
cobus dispatch done <id>
cobus dispatch reap
cobus dispatch ls [--mine|--open|--all] [--json]
cobus dispatch worker [--interval <s>] [--exec <cmd>] [--once] [--max-idle N]
cobus dispatch peers | whoami
```

- **create** — resolves the task (`slug(title)`; created via `ledger.sh task`
  if absent), appends `dispatch`, then: relay mode → the append already
  flushes the outbox and `relay-client.sh sync` runs; git mode → `bin/sync.sh`
  runs (debounce 1s) so the event is pushed now rather than on the next timer;
  local mode → nothing to do. Also drops a best-effort `bus.sh msg all` on
  *this* machine (the bus inbox is machine-local, so this only helps when the
  target is a session on the same box). Prints a presence advisory: how many
  live peers match the selector, or that no peer info exists yet.
  `--quiet` prints only the id (for scripts).
- **accept** — runs on the target: sync, `reap --quiet` (so lapsed leases are
  re-acceptable), then either the named id (refused with exit 4 if the
  selector does not match this machine/actor/caps, exit 1 if not acceptable)
  or `--auto`: the oldest acceptable dispatch (priority asc, creation asc)
  whose selector matches. On success it appends `dispatch.accepted` with
  `lease_until = now + lease_s`, calls `ledger.sh claim <task>` (so the ledger
  board shows the task in-progress), re-syncs, **re-projects**, and confirms
  it actually holds the dispatch — if it lost the race it says so (exit 3)
  and, under `--auto`, tries the next candidate. `--quiet` prints
  `<id>\t<task>\t<title>` on success and nothing (exit 1) otherwise.
- **renew** — holder only (`DSP_FORCE=1` overrides, used by the worker's
  signal handler); new `lease_until = now + (--lease | lease_s)`; also
  re-claims the ledger task.
- **release** — holder only; the dispatch becomes `released` (new epoch) and
  is immediately acceptable by any other matching machine.
- **done** — anyone (holder or requester); appends `dispatch.done` and
  `ledger.sh done <task>`.
- **reap** — for every `accepted` dispatch whose `lease_until < now`, appends
  `dispatch.expired`. Safe to run from *any* machine on a timer; `accept` and
  `worker` run it implicitly. Because a reaper may be working from a stale
  view, the expiry is applied on read only if the holder still matches and
  the (possibly renewed) lease really was lapsed at the reaper's `ts` — a
  renewal that arrived after the reaper read the log wins.
- **ls** — default: everything not done; `--open`: acceptable ones;
  `--mine`: held by or requested from this machine/actor; `--all`; `--json`
  for the raw projection (`state`, `holder`, `lease_until`, `lease_left`,
  `epoch`, `lapsed`, ...).
- **worker** — foreground loop on a target machine: `sync → reap → accept
  --auto`; when it gets one and `--exec` is set, runs `bash -c "<cmd>"` with
  `COORDKIT_DISPATCH_ID`, `COORDKIT_TASK_ID` (ledger subject) and
  `COORDKIT_TASK_TITLE` exported, renews the lease every `lease_s/3` seconds
  (min 5) while the child runs, then `done` on exit 0 or `release --reason
  "worker command exited N"` otherwise. Without `--exec` it accepts and
  leaves the dispatch held for a human/agent on that machine. SIGINT/SIGTERM:
  the child is TERMed and the dispatch released with reason "worker
  interrupted (signal)". `--once` handles at most one dispatch and exits;
  `--max-idle N` exits after N empty polls (0 = forever). This is the hook
  for kicking off a claude/codex session per task, e.g.
  `--exec 'claude -p "work ledger task $COORDKIT_TASK_ID: $COORDKIT_TASK_TITLE"'`.
  Like `cobus swarm`, the worker registers a bus heartbeat for its own session
  id so the ledger's claim liveness check has something to see, and it never
  adds a "skip permissions" flag — what `--exec` runs under is your call.

## 3. Race resolution — first accept wins, on read

The log is append-only and eventually consistent (git: next sync; relay:
seconds; local: immediate). Two machines can both see a dispatch as `open` and
both append `dispatch.accepted`. Nobody arbitrates at write time; instead every
reader replays one dispatch's events in the deterministic order

```
( clock.p  — the emitter's millisecond wall clock,
  create-first — a `dispatch` event always precedes its own transitions,
  eid      — content hash, tie-break )
```

and applies: the **first** `dispatch.accepted` whose `epoch` equals the
current epoch wins; later ones for the same epoch are ignored. Every replica
computes the same answer once it has the same events, so a machine that
briefly believed it won simply sees itself lose on the next projection —
which is why `accept` re-projects after writing and reports "lost the race"
rather than printing success. The `epoch` tag prevents a *stale* accept (one
written against an epoch that has since been released/expired) from being
applied out of order.

Caveats, inherited from the ledger's own ordering (`event.schema.json` →
`clock`): `clock.p` is per-machine wall clock and is not reconciled against
peers, so cross-machine ordering is subject to clock skew; two causally
related events (release on A, accept on B) are separated by at least the
transport latency, so in practice skew only matters when it exceeds that.
The tie-break by eid is arbitrary but deterministic.

## 4. Latency: git vs relay vs local

| mode    | how a dispatch reaches the target                                                                              | typical wake-up            |
|---------|----------------------------------------------------------------------------------------------------------------|----------------------------|
| `relay` | append flushes the outbox to the relay immediately; the target's `accept`/`worker` pulls on every poll (`relay-client.sh sync`) | seconds (worker `--interval`) |
| `git`   | `dispatch` runs `bin/sync.sh` right away (push); the target sees it on ITS next `sync.sh` tick / worker poll (each poll syncs, debounce 1s) | one sync interval          |
| `local` | same filesystem, same log dir                                                                                   | immediate                  |

Leases should be sized for the mode: with git replication every few minutes,
a 60s lease will look lapsed to a reaper on another machine before the renew
arrives. The default lease is 30 min; the worker renews at a third of that.

## 5. Presence contract (heartbeats)

Presence is a separate feature (`cobus heartbeat` / `cobus peers` /
`cobus watch`, `presence.sh`). Dispatch only **reads** it, and degrades to
"no peer info" without it. The contract both sides implement:

- event `type: "heartbeat"`, `subject: "<machine>/<actor>"`, normal v2
  envelope, **no `seq`**;
- top-level fields: `machine` (string — NOT `host`, which stays the adapter
  identity), `actor` (ck_actor), `caps` (object string→string|true), `task`
  (string|null), `ttl_s` (int, default 90), `ts` (epoch s); a superset lives
  under a nested `presence` object (`{machine, pid, session, cwd, repo, branch,
  task, caps, ttl_s}`); dispatch reads `.machine // .presence.machine` etc.;
- a peer is **alive** while `ts + ttl_s >= now`; the latest heartbeat per
  `machine/actor` wins.

Dispatch uses it for: `cobus dispatch peers` (a live/stale list), and the
advisory printed by `dispatch` ("N/M live peers match the selector" / "none
match — it will wait" / "no live presence peers seen"). Matching at *accept*
time never consults presence — the accepting machine matches against its own
identity, so a machine that never heartbeats can still accept.

## 6. Interaction with the ledger task queue

- Creating a dispatch for a new title runs `ledger.sh task "<title>"`, so
  `/led board`, `cobus next`, `swarm` all see the task; a subject that already
  exists is reused (`cobus dispatch <existing-subject>`).
- Accepting runs `ledger.sh claim <subject>` (900s ledger lease, its usual
  liveness rules — the ledger's own claim is for board visibility; the
  dispatch lease is what dispatch tooling enforces). Renew re-claims.
- `done` runs `ledger.sh done <subject>`.
- Nothing stops a local `cobus next` from claiming a dispatched task's subject
  directly on the ledger — dispatch adds a routing layer, it does not fence
  the queue. If that matters, dispatch a task that only exists as a dispatch
  (a fresh title) and let workers pick it up through `dispatch worker`.

## 7. Example — laptop hands a heavy test run to a desktop worker

Desktop (once): describe the machine, then leave a worker running.

```toml
# .claude/coord/coord.toml on the desktop
[machine]
name = "desktop"
caps = "gpu=1,os=linux,cores=32"
```

```bash
cobus heartbeat --loop 30 &                             # optional presence
cobus dispatch worker --interval 10 \
  --exec 'cd ~/src/app && make test-full 2>&1 | tee /tmp/${COORDKIT_DISPATCH_ID}.log'
```

Laptop:

```bash
cobus dispatch "run the full test suite on main" --needs cores=32 --lease 2700 \
  --note "compare against last night's run"
# 📤 dispatched d-6a84c1a2b3c4: task 'run-the-full-test-suite-on-main' → needs=cores=32 (lease 2700s, ...)
#    1/1 live peer(s) match the selector
cobus dispatch ls
# ID               TASK                           TARGET     STATE     HOLDER                 LEASE
# d-6a84c1a2b3c4   run-the-full-test-suite-on…    cores=32   accepted  desktop/site-10265dd3  2688s
```

Close the laptop lid — the desktop worker keeps renewing; when `make` exits 0
it appends `dispatch.done` and marks the ledger task done. If the desktop
crashes mid-run, its lease lapses; the next `reap` (any machine, or the next
`accept --auto` anywhere) flips it to `expired` and another `cores=32` machine
can `accept --auto` it.

## 8. Test

`tests/dispatch.sh` (in `make test`) simulates three machines in local mode
(shared `COORDKIT_BUS_ROOT`, per-machine `COORDKIT_DATA` / `COORDKIT_MACHINE`
/ `COORDKIT_CAPS`) and covers: create → `ls` open; accept on a non-matching
machine is a no-op; `accept --auto` on matching caps claims it (dispatch +
ledger claim); a second machine loses; forged same-clock accepts resolve by
eid; a stale-epoch accept is ignored; `reap` after a short lease reopens it;
re-accept after expiry; `done` completes the ledger task; release/re-accept;
`worker --exec` runs a stub with the env vars set, renews, completes on exit 0
and releases with the exit code on failure; a heartbeat with matching caps is
reported as a live matching peer.
