---
description: Cross-machine task dispatch — hand a task to a specific machine or to whoever is capable and idle (lease/expiry/handoff); accept, renew, release, done, reap, ls, worker
argument-hint: <"title"|task-id [--to machine[/actor]] [--needs k=v,..] [--lease s]> | accept [id|--auto] | renew <id> | release <id> | done <id> | reap | ls [--open|--mine|--all] | worker [--exec cmd] | peers | whoami
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh:*)
---

Run the dispatch subcommand I asked for against this repo's shared
coordination log, then tell me what changed.

My input (a leading verb selects the sub-command; anything else is treated as
a task title / task subject to dispatch):

$ARGUMENTS

Invoke it by calling the Bash tool with:

`${CLAUDE_PLUGIN_ROOT}/scripts/dispatch.sh <verb-or-title> [args...]`

Pass each fixed token (verb, dispatch id, `--to`, `--needs`, `--lease`,
`--priority`, `--note`) as its own argument and the free-text title / note as
ONE single-quoted argument (escape an embedded single quote as `'\''`).

Sub-commands (shared log; every machine in the room sees the same projection):
- `"<title>" [--to <machine|machine/actor>] [--needs k=v,...] [--lease <secs>] [--priority N] [--note "..."]`
  — create the ledger task if needed and dispatch it (default lease 1800s)
- `accept [<id>|--auto]` — on the target machine: claim a dispatch matching this
  machine / actor / caps (`--auto` = oldest matching); first accept wins
- `renew <id> [--lease s]` / `release <id> [--reason "..."]` / `done <id>`
- `reap` — expire lapsed leases so another machine can accept
- `ls [--open|--mine|--all] [--json]` — id, task, target, state, holder, lease left
- `worker [--interval s] [--exec <cmd>] [--once]` — foreground loop that
  syncs, accepts, runs `<cmd>` with `COORDKIT_DISPATCH_ID` / `COORDKIT_TASK_ID`
  / `COORDKIT_TASK_TITLE` exported, renews while it runs, then done/release
- `peers` — live presence peers (from `cobus heartbeat`); `whoami` — this
  machine's identity and caps as the matcher sees them

After running: state the dispatch id and its state, who holds it (if anyone),
and — for a new dispatch — whether any live peer matched the selector. If a
`worker` is what I need on this machine, say so instead of leaving a dispatch
held. Full model, states, and race rules: `docs/DISPATCH.md`.
