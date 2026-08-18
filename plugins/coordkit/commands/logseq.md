---
description: Bridge this repo's shared ledger into a Logseq graph (export/import/sync/status)
argument-hint: export [--journal] [--pages] | import [--dry-run] | sync [--loop <secs>] | status
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/logseq.sh:*)
---

Run the Logseq ⇄ ledger bridge subcommand I asked for.

My argument (first token is the subcommand; `export`/`import`/`sync` take the
optional flags shown above — treat anything else, including empty, as `status`):

$ARGUMENTS

Invoke it by calling the Bash tool with:

`${CLAUDE_PLUGIN_ROOT}/scripts/logseq.sh <subcommand> [flags]`

Subcommands:
- `export [--journal] [--pages]` — project the shared ledger/bus state INTO the
  configured Logseq graph: `pages/<namespace>___fleet.md` (live sessions/repos),
  `pages/<namespace>___tasks.md` (one Logseq TODO/DOING/DONE/WAITING block per
  ledger task, keyed by a `coordkit-task::` property so re-exports update the
  same block in place), and an append-only bullet in today's journal for every
  notable event since the last export. With no flags, does both pages and the
  journal. Only rewrites the marked region of each page — hand-written content
  elsewhere on the page is left alone.
- `import [--dry-run]` — scan the graph for `TODO`/`LATER`/`NOW`/`DOING` blocks
  tagged `#coordkit` (or on the `<namespace>/inbox` page) that don't yet carry a
  `coordkit-task::` property, queue each as a ledger task, and write the new
  task's subject back into that exact block. A block that turns `DONE` in
  Logseq closes the matching ledger task. `--dry-run` reports what it would do
  without writing anything.
- `sync [--loop <secs>]` — import, then export, once. With `--loop`, repeats on
  that interval in the foreground until interrupted (Ctrl-C).
- `status` — graph path, export cursor, task counts, and whether the optional
  Logseq HTTP API is reachable.

Requires `[logseq] graph_dir` to be set in this repo's `.claude/coord/coord.toml`
(see `docs/LOGSEQ.md` for setup and the config example). Without it, `export`/
`import`/`sync` fail with a clear error naming the missing config; `status`
always runs and reports what's missing.

After running, tell me what changed in one or two lines — pages updated,
tasks created/closed on import, or (for `status`) the graph path and counts.
