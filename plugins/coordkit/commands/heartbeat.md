---
description: Emit a machine-presence heartbeat into the shared ledger (who is alive on which machine, what it is doing) — see docs/PRESENCE.md
argument-hint: [--task <id>] [--cap k=v]... [--ttl <secs>]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/presence.sh heartbeat:*)
---

Emit one presence heartbeat for this machine into the shared log, then confirm.

My input (optional flags): $ARGUMENTS

Invoke it by calling the Bash tool with:

`${CLAUDE_PLUGIN_ROOT}/scripts/presence.sh heartbeat $ARGUMENTS`

The event carries the machine name (`COORDKIT_MACHINE` > `coord.toml`
`[machine] name` > `hostname -s`), the stable actor id, session, cwd/repo,
branch, the current task/claim (`--task` overrides auto-detection),
capabilities (`--cap gpu`, `--cap ram=64g`, merged over `[machine] caps` and
`COORDKIT_CAPS`), and a `ttl_s` (default 90). It is a NORMAL ledger event, so
it travels over whichever transport this repo uses (local / git / relay), but
it is out-of-band for the digest: it never appears in `/ctx`.

Do NOT run `--loop` from here — that is a foreground process meant for a
terminal pane, tmux, or a systemd unit (see docs/PRESENCE.md §1.3).

Afterwards tell me it was emitted and suggest `/peers` to see who else is alive.
