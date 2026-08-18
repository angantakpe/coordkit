---
description: One-shot backfill of the cross-machine event stream (cobus watch --once); the live follow loop belongs in a terminal — see docs/PRESENCE.md
argument-hint: [--since 10m|all] [--filter <type,...>] [--exclude <type,...>] [--json]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/presence.sh watch --once:*)
---

`cobus watch` follows the shared event stream across machines in real time
(relay long-poll / git sync / local re-read) and exits on Ctrl-C. It is meant
for a spare terminal pane, so do NOT start the follow loop from here.

What I can do from here is a one-shot backfill — call the Bash tool with:

`${CLAUDE_PLUGIN_ROOT}/scripts/presence.sh watch --once --no-color --since 10m $ARGUMENTS`

(a later `--since` in `$ARGUMENTS` wins; `--filter note,claim,done` /
`--exclude heartbeat` narrow the types; `--json` prints raw event lines.)
Show me the result and, if I want to keep following, tell me to run in a
terminal:

`cobus watch [--since 10m] [--exclude heartbeat]`

See docs/PRESENCE.md §3.
