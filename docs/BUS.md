# How the bus works

`plugins/coordkit/scripts/core/scripts/bus.sh` is coordkit's awareness layer — the
"who else is here, what are they touching" half of the system. It's simpler
than the ledger (`docs/LEDGER.md`): no event sourcing, just per-session
heartbeat files and a soft-lock convention, refreshed on every hook.

The bus is not invoked directly by hooks. Every lifecycle event goes to the
single dispatcher `swarm.sh`. Its canonical source lives under
`plugins/coordkit/scripts/core/scripts/`, with a synchronized self-contained distribution copy
under `plugins/coordkit/scripts/`. The dispatcher sources `bus.sh`, `ledger.sh`, and `guard.sh` as libraries and runs
their phases in-process — so one hook event costs one shell, not one per
subsystem. This doc covers only the bus's phases; see [§8](#8-the-bus-and-guard-mode)
for where guard fits.

## 1. State layout

Everything lives under `<repo>/.coordkit-bus/`:

```
agents/<sid>.json           heartbeat: {sid, host, branch, cwd, task, files, last_seen}
claims/<sha>.json           soft FILE lock: {path, sid, ts} — one per touched file
subagents/<sid>/<tid>.json  a subagent this session currently has running:
                            {sid, tool_use_id, subagent_type, description, started_at}
inbox/<sid>/*.msg    messages waiting for that instance
activity.log         feed: "<iso>\t<sid8>\t<verb>\t<detail>"
metrics/context.ndjson
                     local hook-cost telemetry (rotates to context.ndjson.1)
```

**`claims/` here means file claims, not task claims** — a per-file soft lock
recorded whenever any session Writes/Edits, used only for the collision
warning below. This is unrelated to the ledger's task-claim/lease concept
(`docs/LEDGER.md` §2) even though both are called "claim" — the noun is
overloaded across the codebase, not the same mechanism.

**`subagents/<sid>/` is per-session and ephemeral**, not an audit trail: one
file per currently-running Task-tool call, written at `PreToolUse`/`Task`
(`subagent-start`) and removed at `PostToolUse`/`Task` (`subagent-stop`). A
session's own `subagents/<sid>/` directory is also wiped on `SessionEnd` and
by `prune_dead()` if the owning heartbeat goes hard-stale, so a crashed
session can't leave a phantom "still running" record behind. It's what powers
the SUBAGENTS lines in `/bus` (§7) and the same-type heads-up described there.

`host` is adapter identity (`claude-code`, `codex`, or `cli`). It is
included in session, collision, guard-attribution, and subagent messages so an
operator can tell which runtime owns a claim. Pre-5.0 heartbeat files without
the field render as `unknown`.

### Automatic context is a projection, not the dashboard

The hook path is intentionally smaller than `/bus`/`cobus dashboard`. At
`SessionStart`, automatic context is silence-by-default: only direct inbox
messages and actual file-overlap collisions are injected, with message bodies
capped at 80 characters and collision detail capped to a single peer/file line
by default. Counts and omission hints preserve awareness when more exist. Inbox
overflow is not discarded: undelivered files remain queued for a later prompt.
`UserPromptSubmit` is otherwise silent unless a direct message or another
change-driven subsystem has something new.

`compact` mode applies the caps plus hash/TTL repeat suppression; `quiet`
limits automatic context to critical collisions, guard denials, and direct inbox
messages; `debug` keeps configured caps and disables deduplication. The
dispatcher hard-caps the combined hook payload at 160 estimated tokens on
session start, 96 on prompt submit, and 64 for collision warnings. Use
`$coordkit`, `/bus`, or `cobus dashboard` for the current on-demand view
instead of enlarging every prompt.

The relevant controls are `[context].max_peers`, `max_messages`,
`event_body_chars`, and `repeat_ttl_seconds`, overridden by
`COORDKIT_CONTEXT_MAX_PEERS`, `COORDKIT_CONTEXT_MAX_MESSAGES`,
`COORDKIT_CONTEXT_EVENT_BODY_CHARS`, and
`COORDKIT_CONTEXT_REPEAT_TTL_SECONDS`. Local measurements go to
`.coordkit-bus/metrics/context.ndjson`; metrics are never injected into model
context.

## 2. Heartbeats and liveness

Every hook invocation (`start`, `task`, `record`, `badge`) calls `heartbeat()`,
which upserts `agents/<sid>.json` with the current branch, cwd, last-seen
timestamp, the current task description (from the prompt, truncated to 120
chars), and up to 8 recently-touched files. Two thresholds classify an agent:

- `STALE_SOFT = 900s` (15 min) — beyond this, shown as **idle** rather than
  **live** in `/bus` and the statusline, and its file claims stop triggering
  the proactive collision warning (see below) — but the heartbeat itself
  isn't removed yet.
- `STALE_HARD = 21600s` (6h) — beyond this, the heartbeat is pruned entirely
  (`prune_dead()`, run at `SessionStart`), and any file claims or ledger task
  leases it held are treated as abandoned.

## 3. Collision warnings — age-aware

On `PreToolUse Write|Edit` (`check` phase), if the target file has a recorded
claim from a **different, still-live** session, you get a soft warning plus a
debounced desktop notification. The bus itself **never blocks** — a hard deny is
guard mode's job ([§8](#8-the-bus-and-guard-mode)), and the two are separate
mechanisms with separate state even though they now ship in one plugin. The
warning respects the claim's own age: a claim older
than `STALE_SOFT` no longer triggers the proactive nag, even if the owning
session's heartbeat is technically still alive — a file touched once near the
start of a long session shouldn't keep warning every sibling for hours. The
claim itself isn't deleted by this, though; `/bus`'s COLLISIONS section still
shows it as historical context.

The model-facing warning is separately capped at 64 estimated tokens by
`[context].collision_tokens` or `COORDKIT_CONTEXT_COLLISION_TOKENS`. It is
critical context: `quiet` mode retains it, and repeat suppression does not hide
the warning when a colliding edit is attempted again.

## 4. Messaging

`msg <all|sid8|branch:name> "<text>"` drops a timestamped line into the
target session(s)' `inbox/<sid>/*.msg`, delivered as injected context at their
next `SessionStart` or `UserPromptSubmit`, then deleted. The logical message
envelope is defined in `plugins/coordkit/protocol/message.schema.json`; the inbox file
is the delivery medium, not the protocol itself. Delivery is capped per hook
(`max_messages = 2` by default); excess message files stay queued rather than
being silently consumed. Messages sent from a plain shell (not from inside
a live session) run under a constant `sid=cli`
identity — deliberately, this one case is *not* resolved to the real
session id the way `claim`/`done`/`tasks` are (see §5), because there's no
"who is this instance" question to answer for a broadcast; `all` targets
every live agent regardless of who sent it. The runtime also honors
`COORDKIT_SESSION_ID` and `COORDKIT_PROJECT_DIR`, falling back to the legacy
`CLAUDE_*` names when present so existing Claude Code setups keep working.

## 5. The task board — now just a front-end over the ledger

`claim "<desc>"`, `done "<text>"`, and `tasks` used to write/read their own
`TASKS.md` markdown file. They don't anymore — they're a free-text shorthand
over `ledger.sh`'s own event-sourced task queue. Full details, and why
this consolidation happened, live in `docs/LEDGER.md` §7
("One task queue, two front-ends").

One consequence worth knowing: these three verbs resolve their session id as
`${CLAUDE_SESSION_ID:-cli}` rather than the constant `"cli"` other CLI-context
phases use — because the ledger's lease/work-stealing logic needs a real,
heartbeating session id to correctly show a claim as "in-progress" rather
than immediately "abandoned" (a claim owned by the literal string `"cli"`
would have no matching bus heartbeat and would always look dead).

## 6. Statusline badge

`badge` (wired manually into `settings.json`'s `statusLine`, since a plugin
manifest can't register one) prints `🛰️ N live` / `· M idle` / `· ⚠ K on this
branch`, throttled to at most one heartbeat tick per `TICK_MIN=10s`. It goes
silent (prints nothing) when you're the only live agent and nobody's idling —
so a solo session sees a clean statusline.

## 7. CLI / command reference

| Slash command | What it calls | Does |
| --- | --- | --- |
| `/bus` | `bus.sh dashboard` | One-shot snapshot: live agents (+ any subagents each is running), collisions, task board, recent activity |
| `/claim "<desc>"` | `bus.sh claim` | Publish + immediately lease a ledger task |
| `/tasks` | `bus.sh tasks` | Print the ledger's projected task board |
| `/msg <target> "<text>"` | `bus.sh msg` | Deliver a message to another live instance |

| `/fleet` | `bus.sh fleet` | Cross-repo view: which OTHER repos on this machine have live coordkit sessions right now — see §9 |
| `/heartbeat`, `/peers`, `/watch` | `presence.sh …` | Cross-MACHINE presence over the shared ledger and a live event tail — see [docs/PRESENCE.md](PRESENCE.md) |

Run outside a slash command: `cobus msg <all|sid8|branch:name> "<text>"`
uses the same inbox delivery path and exits non-zero when no live recipient
matches. `cbus` is an alias for `bus.sh watch`, a
2s-refresh full-screen monitor meant for a spare terminal pane), `cobus gc`
(lifecycle cleanup — dead agents/claims/cursors, log rotation; dry-run by
default, see its own `--help`), `cobus fleet` (same as `/fleet`), and the
presence trio `cobus heartbeat [--loop 30]` / `cobus peers` / `cobus watch`
(who is alive on which machine + a live cross-machine event tail;
[docs/PRESENCE.md](PRESENCE.md) — note `cobus watch` tails the shared EVENT
stream, whereas `cbus`/`bus.sh watch` redraws this repo's bus dashboard).

## 8. The bus and guard mode

Through coordkit 2.x, the hard anti-clobber blocker was a **separate plugin**
(`coordguard`) that you installed alongside coordkit. As of **3.0.0** the
canonical implementation lives in `plugins/coordkit/scripts/core/scripts/guard.sh`, with a
synchronized distribution copy in `plugins/coordkit/scripts/guard.sh`. The
same runtime is reached by the shared `swarm.sh` dispatcher. Full details —
the `warn` vs `guard` modes, how the mode is resolved from env / `coord.toml`
/ per-user config, `/guard on|off|status`, and the fail-open discipline —
live in the README's [Enforcement modes](../README.md#enforcement-modes)
section.

Same plugin, still two mechanisms. Worth keeping straight:

|                | Bus collision warning              | Guard deny                                       |
| -------------- | ---------------------------------- | ------------------------------------------------ |
| Asks           | "is another *live session* holding a claim on this file?" | "did this file change *on disk* since I last read it?" |
| State          | `claims/<sha>.json` (§1) — shared across sessions | per-session `mtime:size` fingerprints, private to this session |
| Needs a sibling to be alive | yes — a dead session's claim doesn't warn | no — it catches any external change, including your own `git pull` |
| Outcome        | warning + notification, edit proceeds | `deny`, and only when mode is `guard`          |

They fire on the same `PreToolUse Write|Edit|NotebookEdit` event, guard first —
and a guard deny short-circuits, so the bus check is skipped entirely rather than
appending a warning to an already-stopped call.

Because guard compares the file's own on-disk state rather than asking who
claimed what, it catches cases the bus can't (a sibling that already exited, a
rebase, an editor outside Claude) — and conversely the bus warns about a *live*
sibling working in the same file even when neither of you has written to it yet.
Neither subsumes the other, which is why both still run.

### Read-set drift warning

One more piece of guard.sh is **not** gated by enforcement mode at all:
`guard_driftreport`, wired into `UserPromptSubmit`. On every turn it re-stats
every file this session has Read or Write/Edit'd and, if any of them changed on
disk since, injects a short warning — "you've read this, it's since changed,
re-Read before trusting it." It fires in `warn` mode (coordkit's default) too,
because the problem it solves — the model confidently reasoning from content
that's gone stale underneath it — exists regardless of whether guard mode is
armed to deny anything about it.

It's read-only: it never mutates a stored fingerprint (that still only happens
via the normal `posttool-write` → `guard_record` path), so re-Reading a drifted
file is what naturally drops it off the next report — no separate bookkeeping.
Attribution is best-effort: it checks whether a *live* sibling's bus heartbeat
(`agents/<sid>.json`, same file the bus itself reads) shows that session having
written the drifted path, and names it (sid8 + task) if so; otherwise the file
is reported with no guessed author.

### Guard deny attribution

A guard deny's message also carries **best-effort attribution** when the bus
has a signal for it: it checks (1) `agents/<sid>.json` for a live sibling whose
recently-touched `files` include the target, giving sid8 + branch + task, then
falls back to (2) a `claims/<sha>.json` file-lock naming who last touched it
(sid8 only, no liveness requirement — a weaker, history-only signal). Either
hit appends a concrete "likely changed by / try `/msg`" suggestion to the deny
reason; if neither finds anything, the message is exactly the plain generic
one it's always been. Purely informational — it never changes whether the
call is denied, only what the reason says.

## 9. Cross-repo fleet view

Everything above is scoped to ONE repo's `.coordkit-bus/`. The fleet view is
the one exception: a small, **read-only discovery** layer that answers "which
OTHER repos on this machine currently have live coordkit sessions?" — useful
when you work across many separate repos and want to check from any one of
them whether you left a session running somewhere else.

**This is explicitly NOT cross-repo task dispatch.** A PM session in repo A
cannot create a task that lands in repo B's ledger/queue through this
mechanism, and nothing here attempts that. Routing work across repos raises
a materially bigger question — whose enforcement/trust settings apply, what
happens if the target repo doesn't exist locally, how does a foreign task
get signed — and is deliberately left as future work, not attempted here.

**Registry.** `$(ck_data_dir)/fleet.json` (the same persistent, per-machine,
per-user directory that already holds `site.json`/`trust.json`/`clock.state`
— see `common.sh`'s `ck_data_dir()`) holds a flat map of repo root ->
`{last_seen}`:

```json
{"repos": {"/path/to/repo-a": {"last_seen": 1735689600},
           "/path/to/repo-b": {"last_seen": 1735689500}}}
```

**Registration.** `bus.sh`'s `heartbeat()` — already called on every
SessionStart/UserPromptSubmit/tool-use — upserts THIS repo's own entry
(`resolve_root()`'s path) at the end of every call, so there is no second,
separate write path. Because heartbeat() itself is far too hot a cadence for
a file shared across every repo on the machine, the fleet write is
independently throttled to once per `TICK_MIN` (10s) per repo via a small
per-repo marker file (`.coordkit-bus/.fleet-tick`), the same debounce idiom
`bus.sh` already uses for desktop-notification debouncing.

**View.** `/fleet` (`bus.sh fleet`, or `cobus fleet` from a plain shell)
reads the registry and, for each entry, **re-derives** live/idle session
counts and the branches in use at view time by reading that repo's own
`.coordkit-bus/agents/*.json` directly — using the same `STALE_SOFT`/
`STALE_HARD` age thresholds §2 describes. The registry only remembers WHERE
repos are; it never caches a liveness count, because a cached count would go
stale between heartbeats. A registry entry whose path no longer exists on
disk (a moved or deleted repo) is skipped from the listing and pruned from
`fleet.json`, so a stale entry doesn't linger forever.

**Privacy — strictly local.** `fleet.json` lists local filesystem paths of
your OTHER repos. It is written only via `ck_data_dir()` (per-machine,
per-user) and MUST NEVER be routed through the git/relay ledger transport
(`transports/git.sh`, `transports/relay.sh`) or any other sharing mechanism —
unlike the ledger, which a `coord.toml` can opt into sharing across machines,
the fleet registry has no such opt-in and never leaves the machine it was
written on.

**Machines line.** The fleet listing ends with one additive line —
`🌐 machines (shared log): N alive (…) · M stale (…)` — summarising the
cross-MACHINE presence view of the CURRENT repo (`presence.sh peers
--summary`, i.e. heartbeat events in this repo's shared ledger). It prints
nothing when no heartbeat was ever emitted, so repos that don't use presence
see the fleet output exactly as before. That line comes from the ledger, not
from `fleet.json`, and does not weaken the privacy rule above: `fleet.json`
still never leaves the machine. Full view: `cobus peers`; design:
[docs/PRESENCE.md](PRESENCE.md).
