# How the ledger works

`packages/core/scripts/ledger.sh` is coordkit's shared-context
layer.
It sits **on top of** the bus (`docs/BUS.md`) — it reuses the bus's per-repo
heartbeats (`.coordkit-bus/agents/<sid>.json`) to decide whether a session is
still alive, but it answers a different question. The bus tells you *who else
is here and what they're touching*; the ledger gives every instance **one
shared, append-only source of truth** — decisions, notes, questions, and a
self-orchestrating task queue — that instances receive as bounded, change-driven
context or inspect explicitly on demand.

## 1. Storage: one JSON event per line, never edited

Every write appends a line to `.coordkit-bus/ledger.jsonl` (or, in git/logstore
mode, to this machine's own actor-partitioned segment file — see
[Transports](#5-transports) below). A line is **never** edited or deleted,
only appended. Each event carries:

```
{schema_version, eid, id, actor, clock, seq, ts, sid, sid8, host, user, branch,
 type, subject, body, refs, tags, lease, supersedes, sig}
```

The full field-by-field contract lives in
`packages/protocol/event.schema.json` — read that file for the authoritative,
currently-accurate description of what's implemented vs. reserved for later
(`sig` and `supersedes` remain reserved; the documented `clock`-based transport
ordering is live for shared modes).

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
correct and sufficient for a single append-only file. Git and relay modes read
the deduplicated replica union in stable `(clock.p, clock.c, actor)` order.
Sessions persist a compact `{actor: max_clock.c}` cursor vector, plus the global
watermark only for legacy-envelope compatibility. The vector detects a newly
synced actor even when clock skew places its event before the old global key.
Ledger projections reconcile by the resulting stream position, never by a
replica-local `seq`, so a newly received event with a lower `seq` is not lost.
`clock.p` is still unsynchronised wall time rather than a reconciled Lamport
clock, so cross-machine last-writer-wins remains subject to clock skew.

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

**Questions become claimable work.** `ask <subject> "<q>"` doesn't just open a
question for a human to eventually notice in the digest — it also queues a
linked task, subject `answer-<subject>`, body `"answer the open question
'<subject>': <q>"`. That means an idle sibling's `next` can auto-claim "go
answer this question" like any other task. `answer <subject> "<a>"` closes
the loop: it marks `answer-<subject>` `done` in the same call, regardless of
which instance (if any) claimed it — the projection's done/claim
reconciliation always treats the latest `done` on a subject as authoritative.
Limitations: this doesn't add task priority/ordering — the linked task queues
in the normal first-appearance order like any other `task` call. And
re-`ask`ing an already-answered subject reopens the *question* (a fresh
`question` event outdates the prior `answer`) but does **not** reopen the
already-`done` linked task, since a bare `task` event only updates the
description, not claim/done status — re-answering still works (it appends a
fresh `done`), but `next` won't resurface it as new work.

**Work-stealing, no leader**: a claim whose lease has expired, *or* whose
owning session's bus heartbeat has gone dead (`owner_live()`, tied to the
bus's `STALE_HARD` = 6h), is treated as **open again** the next time anyone
computes `task_status()`. Nobody has to explicitly release it — the next
`claim`/`next` call just takes it. This is why the ledger depends on the bus:
liveness is the bus's job, the ledger only asks it the question.

### Swarm mode — running workers against the queue

Everything above describes the primitives; nothing runs them for you — a
human calls `/led next` by hand, one task at a time. `cobus swarm <N>`
(`packages/core/scripts/worker-runtime.sh`) is that, automated: it spawns `N`
worker loops that each repeatedly call `next`, "execute" whatever they claim,
and report the outcome back to the ledger, until the queue looks drained (a
handful of consecutive empty polls, each backed off 2-5s — no hot-looping) or
the process is interrupted.

**`N` is capped at 8, hard.** This isn't configurable in the current pass —
it's a deliberate safety ceiling against a fat-fingered `cobus swarm 500`
forking hundreds of processes.

**Bare-CLI liveness.** `owner_live()` (above) needs a live bus heartbeat for
the claiming sid, which the SessionStart/UserPromptSubmit hooks normally
supply for free — but a swarm worker is a bare shell loop with no hook driving
it. `bus.sh` gained a small `heartbeat` CLI phase for exactly this: each
worker mints itself a distinct session id (`swarm<N>-<pid>`) and registers one
heartbeat before it starts polling. The bus's liveness window (6h) comfortably
outlasts any reasonable swarm run, so there's nothing to refresh per-poll.

**Machine-readable `next`.** `next` also gained a `--quiet`/`-q` flag, purely
additive — no flag is byte-identical to the original decorated output. With
the flag: a successful claim prints exactly one line, `<subject>\t<description>`,
and exits 0; nothing claimable prints nothing and exits 1. Workers use this
instead of string-matching the human-readable "🤖 picked next task..." /
"🟢 no open tasks..." messages, which would otherwise be one decoration change
away from silently breaking every worker.

**Claim races on cold start.** `next` has no coordination beyond the log
itself — "whichever instance's call wins the append race gets the task," and
under the ledger's last-write-wins convergence, the LAST claim event for a
subject is the one that counts. With N workers all polling in lockstep, this
race is far more likely to trigger than with occasional human `/led next`
calls: testing this feature reliably reproduced two workers both claiming the
same task on their very first poll when the queue had exactly as many open
tasks as workers. Each worker's first poll is now staggered by its id
(whole seconds — `sleep 0.N` isn't portable to BSD/macOS `sleep(1)`), which
eliminated the collision in testing, but it's a mitigation, not a guarantee:
under heavy contention two workers can still occasionally claim the same
subject, and in EXEC mode (below) that means the task's command could run
twice. This is the same class of risk the ledger already accepts for two
concurrent humans racing `next` — swarm just makes it easier to trigger, not
new in kind.

**Execution is deliberately conservative.** By default, `cobus swarm` runs in
**DRY RUN**: each worker still calls the real `next` (so dependency ordering
and the work-stealing/lease mechanics are exercised for real, not simulated),
prints what task it claimed and what command *would* run, and then — this is
the one non-obvious design choice — **does NOT call `done`**. The claim is
left in place and self-expires via the normal lease TTL if nothing completes
it for real. The alternative (auto-`done`ing a dry run) was rejected: a
`done` event is a permanent, trusted assertion every other instance reads as
ground truth, and there is no "undone" verb to walk it back if a dry run
silently marked real work complete. A stale claim, by contrast, is exactly
the case leases already exist to self-heal — bounded, reversible, and costs
nothing new.

Real execution requires **both** `COORDKIT_SWARM_EXEC=1` *and*
`COORDKIT_SWARM_CMD` (a shell command template; the literal text `{desc}` is
replaced with the claimed task's description, then the whole string is handed
to `bash -c`). On success the worker calls `done`; on a nonzero exit it calls
`block <subject> "...command exited N"` instead of silently marking broken
work complete. Nothing here ever adds a "skip permissions" flag to whatever
command you configure — if `COORDKIT_SWARM_CMD` is something like
`claude -p "{desc}"`, you get normal prompted permissions unless *you*
configure otherwise, and you're responsible for that choice either way. Since
the description is spliced into a real shell command line, a description
containing shell metacharacters will be interpreted by the shell — the same
trust boundary already applies to whoever can write `task` events into this
queue in the first place (same machine, or an explicitly `cobus trust`-ed
git-mode repo), but don't point `COORDKIT_SWARM_CMD` at anything you wouldn't
run with arbitrary task-description text as input.

## 3. Context governor — what actually reaches your context

Reading the entire ledger on every turn does not scale. The ledger therefore
projects current state, coalesces repeated lifecycle changes, ranks candidates,
and packs a bounded page instead of replaying raw history:

- Tasks, decisions, and questions are projected to the latest event for each
  subject. In deltas, the latest task lifecycle, decision, and question/answer
  for a subject wins; independent notes remain distinct.
- Delta candidates are ranked by actionable type (`block`, `done`, `claim`,
  `answer`, `decision`, `question`, `task`, then `note`) and recency.
- On `UserPromptSubmit`, if the hook carries prompt text, the ledger adds a
  query-aware relevance pass before the token budget is applied. Prompt terms
  can lift an older but directly relevant event ahead of newer noise, while the
  no-prompt path keeps the existing salience order.
- The default page contains at most 5 tasks, 3 decisions, 3 questions, and 8
  events, with event bodies capped at 120 characters. Every truncated category
  reports `+N more` and points to the host's on-demand command.
- The final automatic `additionalContext`, including the untrusted-data safety
  frame, is hard-capped at an estimated 600 tokens on `SessionStart` and 250 on
  `UserPromptSubmit`. The estimator defaults to 4 UTF-8 bytes per token.

`SessionStart` computes the bounded materialized state plus events newer than
the session cursor. A brand-new session starts one page back, so it receives
recent context rather than the entire history. `UserPromptSubmit` includes only
the coalesced delta from other instances and advances the cursor; an instance's
own writes are not echoed back. Direct mode stores a local `seq` cursor; shared
git/relay mode stores that compatibility value, the total-order watermark, and
the authoritative per-actor cursor vector. Cursors whose bus heartbeat is
hard-stale are pruned automatically.

Configure the limits in `[context]` or with
`COORDKIT_CONTEXT_SESSION_START_TOKENS`, `COORDKIT_CONTEXT_PROMPT_TOKENS`,
`COORDKIT_CONTEXT_BYTES_PER_TOKEN`, `COORDKIT_CONTEXT_MAX_TASKS`,
`COORDKIT_CONTEXT_MAX_DECISIONS`, `COORDKIT_CONTEXT_MAX_QUESTIONS`,
`COORDKIT_CONTEXT_MAX_EVENTS`, and `COORDKIT_CONTEXT_EVENT_BODY_CHARS`.
Environment values must be positive integers; invalid values fall back to TOML
and then to the built-in defaults.

`/ctx`, `$coordkit`, and `cobus digest` provide an explicit catch-up view, but
the digest itself remains bounded so a one-off inspection cannot accidentally
flood context. Use the projected task board or narrower ledger operations when
you need more detail about an omitted category. The append-only ledger remains
complete on disk; context selection never deletes history.

## 4. The trust gate — why a cloned repo can't just talk to your model

A **committed** `coord.toml` can select `mode = "git"` or `mode = "relay"`,
which makes the runtime read shared coordination events from Git or a remote
endpoint. That is by design, so a trusted fresh clone can auto-join a team's
room with zero transport setup. The problem: a hostile repo could point at an
attacker-controlled stream or commit fabricated `.ndjson` events. Without a
gate, opening it could inject fake "decisions" and "tasks" into context at
`SessionStart`, before you'd typed a single word — and `next` could auto-claim
an attacker-authored task body as if it were legitimate.

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

Local mode (the default) reads/writes actor segments plus the legacy flat
`ledger.jsonl` — zero network. Git mode and the authenticated relay mode sit
behind a shared `logstore_*` interface in `transports/lib.sh`; see
`plugins/coordkit/transports/README.md` for how those work. The important
property for the ledger's own logic: **the read path is identical regardless
of transport** — `resolve_root()`, dedup, and ordering all come from the one
canonical `packages/core/scripts/common.sh`, so direct mode and logstore
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
digest | catchup      bounded projected digest with omission hints
board                 the projected task queue
note "<text>"         drop a durable note
decide <subj> "<t>"   record a decision (latest per subject wins)
ask <subj> "<q>"      open a question (also queues task answer-<subj>)
answer <subj> "<a>"   close it (also marks answer-<subj> done)
task "<desc>"         queue work (dep:<subject> tokens for ordering)
claim <subj>          lease a task
next [--quiet|-q]     auto-claim the first open, deps-satisfied task
                      (--quiet: "<subject>\t<desc>" + exit 0, or exit 1 with
                      no output when nothing's claimable — for scripts, not
                      humans; see cobus swarm below)
done <subj>           mark complete
block <subj> "<why>"  mark blocked
trust | distrust      allow/revoke this repo's coord.toml-driven sharing
compact               snapshot projections, bump the schema compaction epoch
                      (see §7 — SessionStart now auto-queues this as a task)
```

## 7. Compaction — snapshot, and now self-scheduling

`compact` (§6) is purely additive: it never truncates or edits
`ledger.jsonl`, it materializes the current projections (open/claimed/done/
blocked tasks, latest decision per subject, open questions, `max_seq`) into
`.coordkit-bus/compacted-<epoch>.json` and bumps `compaction_epoch` in
`schema/MANIFEST.json`. That command existed long before anything called it —
it was 100% manual, so in practice it never ran and every digest kept
re-scanning an ever-growing log.

`SessionStart` now checks this itself: it compares the current `max_seq()`
against the `max_seq` recorded in the most recent `compacted-*.json` for
*this* repo's bus, and once that drift exceeds `COMPACT_EVERY` (200 events,
tunable at the top of `ledger_main`), queues a `compact-ledger-<seq>` task —
the same task queue as everything else, claimable via `/led claim` or `/led
next`, whose body just tells whoever picks it up to run `cobus compact`. The
subject is suffixed with the triggering seq rather than a fixed
`compact-ledger`, because task-status reconciliation only ever compares
`done`/`claim`/`block` seqs against each other, never against a `task`
event's own seq — a fixed subject would go permanently invisible on the
board after its first done/compact cycle, defeating "self-scheduling". The
check only runs on `SessionStart` (not on every `UserPromptSubmit`): that
phase already pays for one full-log projection scan to build its own digest,
so this reuses that same cache for free, whereas `UserPromptSubmit` normally
does a much cheaper cursor-delta-only read and doesn't otherwise need to scan
the whole log — the threshold is coarse enough that a once-per-session-start
cadence is plenty. Nothing about `compact` itself changed: the log is still
never rewritten, and running `compact` any number of times stays safe.

## 8. One task queue, two front-ends

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
