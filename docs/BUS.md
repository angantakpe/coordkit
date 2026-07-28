# How the bus works

`plugins/coordkit/scripts/claude-bus.sh` is coordkit's awareness layer — the
"who else is here, what are they touching" half of the system. It's simpler
than the ledger (`docs/LEDGER.md`): no event sourcing, just per-session
heartbeat files and a soft-lock convention, refreshed on every hook.

## 1. State layout

Everything lives under `<repo>/.claude-bus/`:

```
agents/<sid>.json    heartbeat: {sid, branch, cwd, task, files, last_seen}
claims/<sha>.json    soft FILE lock: {path, sid, ts} — one per touched file
inbox/<sid>/*.msg    messages waiting for that instance
activity.log         feed: "<iso>\t<sid8>\t<verb>\t<detail>"
```

**`claims/` here means file claims, not task claims** — a per-file soft lock
recorded whenever any session Writes/Edits, used only for the collision
warning below. This is unrelated to the ledger's task-claim/lease concept
(`docs/LEDGER.md` §2) even though both are called "claim" — the noun is
overloaded across the codebase, not the same mechanism.

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
claim from a **different, still-live** session, you get a soft warning (never
a block — that's coordguard's job, a separate plugin) plus a debounced
desktop notification. The warning respects the claim's own age: a claim older
than `STALE_SOFT` no longer triggers the proactive nag, even if the owning
session's heartbeat is technically still alive — a file touched once near the
start of a long session shouldn't keep warning every sibling for hours. The
claim itself isn't deleted by this, though; `/bus`'s COLLISIONS section still
shows it as historical context.

## 4. Messaging

`msg <all|sid8|branch:name> "<text>"` drops a timestamped line into the
target session(s)' `inbox/<sid>/*.msg`, delivered as injected context at their
next `SessionStart` or `UserPromptSubmit`, then deleted. Messages sent from a
plain shell (not from inside a live session) run under a constant `sid=cli`
identity — deliberately, this one case is *not* resolved to the real
session id the way `claim`/`done`/`tasks` are (see §5), because there's no
"who is this instance" question to answer for a broadcast; `all` targets
every live agent regardless of who sent it.

## 5. The task board — now just a front-end over the ledger

`claim "<desc>"`, `done "<text>"`, and `tasks` used to write/read their own
`TASKS.md` markdown file. They don't anymore — they're a free-text shorthand
over `claude-ledger.sh`'s own event-sourced task queue. Full details, and why
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
| `/bus` | `claude-bus.sh dashboard` | One-shot snapshot: live agents, collisions, task board, recent activity |
| `/claim "<desc>"` | `claude-bus.sh claim` | Publish + immediately lease a ledger task |
| `/tasks` | `claude-bus.sh tasks` | Print the ledger's projected task board |
| `/msg <target> "<text>"` | `claude-bus.sh msg` | Deliver a message to another live instance |

Run outside a slash command: `cbus` (alias for `claude-bus.sh watch`, a
2s-refresh full-screen monitor meant for a spare terminal pane) and `cobus gc`
(lifecycle cleanup — dead agents/claims/cursors, log rotation; dry-run by
default, see its own `--help`).
