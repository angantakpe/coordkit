---
description: Show who is alive on which machine right now (projection over presence heartbeats in the shared ledger) — see docs/PRESENCE.md
argument-hint: [--all]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/presence.sh peers:*)
---

Show the cross-machine peers view for this repo's shared log and present it.

!`${CLAUDE_PLUGIN_ROOT}/scripts/presence.sh peers $ARGUMENTS`

One row per (machine, actor, session): `alive` when the last heartbeat is
within its `ttl_s`, `stale` otherwise, plus age, current task, branch,
capabilities and repo. Rows older than 24h are hidden unless `--all`.
Reads through the transport union, so in git/relay mode this reflects other
machines too (relay mode pulls first).

Then, in one or two lines:
- Say which machines are alive and what they are working on; flag any peer
  claiming the same task I am on.
- If nothing is listed, say so plainly and suggest `cobus heartbeat --loop 30`
  on each machine.
