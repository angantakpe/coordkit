---
description: Linear ⇄ ledger bridge — pull Linear issues onto the shared task board, push ledger claims/notes/blocks/done back into ONE persistent Linear comment per issue
argument-hint: <pull|push|sync|link|status> [args] [--dry-run]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/linear.sh:*)
---

Run the Linear bridge subcommand I asked for against this repo's shared ledger,
then summarize what changed.

My input (the first token is the subcommand):

$ARGUMENTS

Invoke it by calling the Bash tool with:

`${CLAUDE_PLUGIN_ROOT}/scripts/linear.sh <subcommand> [args...]`

Subcommands (config lives in `.claude/coord/coord.toml` `[linear]`; the API key
ONLY in the `LINEAR_API_KEY` env var — never write it to any file):
- `pull [--state "Todo,In Progress"] [--assignee me]` — upsert matching Linear
  issues as ledger tasks `linear-<identifier>` (e.g. `linear-cod-123`).
  Idempotent: re-running emits nothing for unchanged issues.
- `push [COD-123 ...|--all]` — mirror each mapped task's ledger activity (claim
  owner + machine + branch, notes, block reason, completion) into ONE persistent
  `coordkit ledger` comment on the issue (created once, updated in place),
  move the issue to `claim_state`/`done_state`, add/remove the `blocked` label.
- `sync [--loop <secs>]` — pull then push; `--loop` keeps going (Ctrl-C stops).
- `link <task-subject> <COD-123>` — map an existing ledger task onto an issue.
- `status` — config, auth presence (never the key), last sync, mapping table.
- add `--dry-run` to any of them to print the GraphQL mutations instead of
  sending them.

After running: tell me which issues were pulled/pushed, any state transitions
that happened, and — if `LINEAR_API_KEY` was missing or Linear was unreachable
— say so plainly and point at `docs/LINEAR.md` rather than retrying.
