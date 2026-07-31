# How the ledger works

`plugins/coordkit/scripts/ledger.sh` is coordkit's shared-context layer.
It sits **on top of** the bus (`docs/BUS.md`) — it reuses the bus's per-repo
heartbeats (`.coordkit-bus/agents/<sid>.json`) to decide whether a session is
still alive, but it answers a different question. The bus tells you *who else
is here and what they're touching*; the ledger gives every instance **one
shared, append-only source of truth** — decisions, notes, questions, and a
self-orchestrating task queue — that all of them read a paginated slice of on
every turn.

## 1. Storage: one JSON event per line, never edited

Every write appends a line to `.coordkit-bus/ledger.jsonl` (or, in git/logstore
mode, to this machine's own actor-partitioned segment file — see
[Transports](#5-transports) below). A line is **never** edited or deleted,
only appended. Each event carries:

```
{schema_version, eid, id, actor, clock, seq, ts, sid, sid8, user, branch,
 type, subject, body, refs, tags, lease, supersedes, sig}
```

The full field-by-field contract lives in
`plugins/coordkit/schema/event.schema.json` — read that file for the
authoritative, currently-accurate description of what's implemented vs.
reserved for later (`sig`, `supersedes`, and the `clock`-based cross-machine
ordering are all explicitly marked as **not yet implemented** there; don't
trust older prose elsewhere that implies otherwise).

`type` is one of `note | decision | question | answer | task | claim | done |
block` (readers tolerate unknown types as opaque notes, so this isn't a
strictly closed set). `subject` is the **reconciliation key**: for any given
subject, the *latest* event of a given type wins. There is no in-place mutable
state anywhere — "is this task done?" is answered by scanning for the newest
`task`/`claim`/`done`/`block` event on that subject, not by reading a stored
flag. That's the whole trick: every instance reading the same append-only log
converges on the same answer, deterministically, with no cache-invalidation
class of bug possible.

**Ordering, honestly**: in the shipped default (direct/local mode), the log is
read in **local `seq` order** — `seq` is a plain per-physical-log integer,
correct and sufficient for a single append-only file. The schema also defines
a `clock` field (`{p: wall-ms, c: monotonic counter}`) intended for a future
machine-independent total order across replicas (`sort by (clock.p, clock.c,
actor)`) for git/relay sharing — but the *read path* doesn't use it yet; the
schema file says so explicitly. Don't design around cross-machine clock
ordering being live today.

## 2. The task queue — leases, auto-claim, work-stealing

This is the **one** task queue in coordkit — the bus's `/claim`/`/tasks`/
`done` are a thin front-end over this same engine, not a separate store; see
[One task queue, two front-ends](#7-one-task-queue-two-front-ends) below.

- `task "<desc>"` — publish work. `subject` is a slug derived from the text.
  Add `dep:<subject>` tokens in the body to make it depend on other tasks.
- `claim <subject>` — lease a task for `LEASE_TTL` (900s, matched to the bus's
  `STALE_SOFT` liveness window). Refuses if already claimed or done.
- `next` — auto-claim the first *open* task whose deps are all `done`. No
  coordination beyond the log itself: whichever instance's `next` call wins
  the append race gets the task.
- `done <subject>` / `block <subject> "<why>"` — mark terminal states.

**Work-stealing, no leader**: a claim whose lease has expired, *or* whose
owning session's bus heartbeat has gone dead (`owner_live()`, tied to the
bus's `STALE_HARD` = 6h), is treated as **open again** the next time anyone
computes `task_status()`. Nobody has to explicitly release it — the next
`claim`/`next` call just takes it. This is why the ledger depends on the bus:
liveness is the bus's job, the ledger only asks it the question.

## 3. Pagination — what actually reaches your context

Reading the *entire* ledger on every turn doesn't scale and would flood every
prompt with history nobody needs. Instead:

- **`SessionStart`** (`ledger.sh start`): computes the small
  *materialized state* (open/claimed/blocked tasks, the 5 most recent
  decisions, any open questions) — always included, it's cheap — then adds
  events strictly newer than this session's cursor (`cursors/<sid>.json`,
  capped at `PAGE=20` events, each body truncated to `BODYCAP=240` chars). A
  brand-new session starts its cursor one page back (not at zero), so it gets
  recent context instead of either nothing or the entire history.
- **`UserPromptSubmit`** (`ledger.sh prompt`): injects only the delta
  from *other* instances since your last turn, then advances your cursor.
  You never see your own writes echoed back.
- Cursors for sessions whose bus heartbeat is long gone get pruned
  automatically (`prune_cursors()`, called from `ensure_dirs()`) — they used
  to accumulate forever; this was closed in a hardening pass.

`/ctx` gives you the full un-paginated digest by hand at any time; `/led
digest` (alias `catchup`) is the same thing from the ledger's own CLI.

## 4. The trust gate — why a cloned repo can't just talk to your model

A **committed** `coord.toml` can select `mode = "git"`, which flips a repo
into reading `coord/log/**/*.ndjson` files as its ledger when the runtime is
pointed there by `COORDKIT_COORD_TOML` or `COORDKIT_COORD_DIR` (the legacy
`CLAUDE_*` names still work too). That is by design, so a fresh `git clone`
auto-joins a team's shared coordination room with zero setup. The problem:
nothing stops a *hostile* repo from also committing fabricated `.ndjson` event
files there. Without a gate, cloning such a repo would inject the attacker's
fake "decisions" and "tasks" into your context at `SessionStart`, before you'd
typed a single word — and `next` would auto-claim and hand the model an
attacker-authored task body as if it were legitimate.

So: a committed `coord.toml` selecting git/relay mode is **not enough** to
auto-activate log reads on its own. The repo also has to be explicitly
trusted on *this machine*:

```bash
cobus trust      # trust the current repo's coord.toml-driven sharing
cobus distrust   # revoke it
```

Trust is recorded per-repo (keyed by the git remote URL, or a path hash if
there's no remote) in `${COORDKIT_DATA:-${CLAUDE_PLUGIN_DATA}}/trust.json` —
this machine's own persistent decision, not something a repo can grant itself.
An untrusted repo silently falls back to local-only mode (never blocks, never
errors) and gets one advisory line in the SessionStart digest telling you
sharing was requested but not enabled. Setting `COORDKIT_MODE`/
`COORDKIT_USE_LOGSTORE` directly in your own environment is *your* explicit
decision and still activates immediately — the gate only applies to the
toml-derived path.

**Not to be confused with enforcement mode.** Everything above — `COORDKIT_MODE`
and `coord.toml`'s top-level `mode` — is about the **transport**
(`local` / `git` / `relay`). Since 3.0.0 coordkit also has an **enforcement**
mode (`warn` / `guard`) deciding whether the guard denies a clobbering edit.
That's a separate setting with its own env var (`COORDKIT_ENFORCEMENT`) and its
own `[enforcement]` table in the same file; see the README's
[Enforcement modes](../README.md#enforcement-modes). The two share the word
"mode" and nothing else — neither reads the other's value.

The trust gate is likewise unaffected by guard mode: the guard reads and writes
only local, per-session fingerprint state and never reads or appends to the
shared log, so nothing a hostile repo can commit influences whether it denies.

On top of the gate, injected digest content is framed as **untrusted data,
not instructions** — even in local/direct mode where every writer is a
same-machine sibling you already trust, so the framing costs nothing and adds
a second layer of defense for the git-mode case.

## 5. Transports

Local mode (the default) reads/writes a single flat `ledger.jsonl` directly —
zero dependencies, zero network. Git mode and the stubbed relay mode sit
behind a shared `logstore_*` interface in `transports/lib.sh`; see
`plugins/coordkit/transports/README.md` for how those work. The important
property for the ledger's own logic: **the read path is identical regardless
of transport** — `resolve_root()`, dedup, and ordering all come from the one
canonical `plugins/coordkit/scripts/common.sh`, so direct mode and logstore
mode can never resolve to two different `.coordkit-bus` trees.

## 6. CLI / command reference

| Slash command | What it calls | Does |
| --- | --- | --- |
| `/ctx` | `ledger.sh digest`, `board` | Full digest + task board, read-only |
| `/led <verb> [subject] [text]` | `ledger.sh <verb> ...` | Drives every write verb below |

`ledger.sh` phases (also reachable via `cobus <verb>` from a plain
shell, since `bin/cobus` forwards anything it doesn't special-case straight to
the ledger):

```
digest | catchup      full paginated digest
board                 the projected task queue
note "<text>"         drop a durable note
decide <subj> "<t>"   record a decision (latest per subject wins)
ask <subj> "<q>"      open a question
answer <subj> "<a>"   close it
task "<desc>"         queue work (dep:<subject> tokens for ordering)
claim <subj>          lease a task
next                  auto-claim the first open, deps-satisfied task
done <subj>           mark complete
block <subj> "<why>"  mark blocked
trust | distrust      allow/revoke this repo's coord.toml-driven sharing
compact               snapshot projections, bump the schema compaction epoch
```

## 7. One task queue, two front-ends

This used to be two unrelated systems: the bus had its own simple markdown
board (`TASKS.md`, checkbox lines, literal-text `done` matching, no leases or
dependencies) sitting alongside the ledger's event-sourced queue — same verb
names (`claim`, `done`, `tasks`), completely different storage, and using the
wrong one silently did nothing you expected (a bus `/claim` never showed up
in `/led next`, and a ledger `task` never showed up in `/tasks`). That
duplication was consolidated: **there is now exactly one task queue, the
ledger's**, with two ways to talk to it:

- **`/led task` / `claim <subject>` / `next` / `block`** — the full engine,
  for when you want dependencies (`dep:<subject>`) or Claude-instance
  self-organization via `next`'s auto-claim.
- **`/claim "<desc>"` / `/tasks` / `bus.sh done "<text>"`** — a
  free-text shorthand over the *same* engine. `/claim` publishes a task
  *and* immediately leases it to you in one step (computing the subject via
  the shared `slug()` in `common.sh`, so it's always the identical subject
  `/led task` would have minted for that text); `done "<text>"` finds the
  first still-open task whose description contains that text as a **literal
  fixed string** (not a regex — `[urgent]`, `(P0)`, `*` in a description all
  match literally, they don't need escaping) and marks it done; `/tasks`
  just prints the ledger's own projected board.

Both paths write the identical event stream, so a task claimed via `/claim`
is immediately visible to `/led next`'s dependency resolution and vice versa
— there's nothing left to keep in sync, because there's only one store.
