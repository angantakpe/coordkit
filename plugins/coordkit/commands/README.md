# Shared command spec

The canonical shared source of truth lives in
[`plugins/coordkit/scripts/core/commands/catalog.json`](/home/anga/workspace/projects/agents/coordkit/plugins/coordkit/scripts/core/commands/catalog.json).
The Markdown files in this directory are host wrappers around those command
intents. Host adapters may expose the same intent differently, but the behavior
should stay aligned with the core package.

## Contract

- Command files describe intent, inputs, and expected output.
- Host-specific packaging stays in the frontmatter and wrapper text.
- Shared behavior belongs in the core package, not in adapter readmes or skill
  docs.
- Claude Code can surface these files as slash commands.
- Codex and future hosts should expose the same intents through their own thin
  wrappers or skill surfaces.

## Command intents

- `bus` - show live sessions, file claims, and collision risk for the current
  repo.
- `led` - write to or inspect the shared ledger and task queue.
- `claim` - claim work on the shared board and show the board state.
- `fleet` - show live coordkit usage in other repos on the same machine.
- `heartbeat` - emit a machine-presence heartbeat (machine, actor, task, caps,
  ttl) into the shared ledger; `--loop` for a foreground emitter.
- `peers` - show which machines/actors are alive right now and what they are
  doing (projection over heartbeat events).
- `watch` - follow the shared event stream live across machines; the slash
  wrapper only does a `--once` backfill, the follow loop belongs in a terminal.
- `dev-docs` - create a structured planning document and companion task docs.
- `dev-docs-update` - refresh planning docs before context compaction.
- `statusline-setup` - install or check the host statusline badge wiring.
- `ctx` - show the shared context layer: task queue, decisions, questions, and
  recent ledger events.
- `guard` - toggle or inspect the hard anti-clobber enforcement mode.
- `msg` - send a message to another live instance in this repo.
- `route-research-for-testing` - derive route contracts from edited files and
  validate them with a read-only subagent.
- `tasks` - show the shared command-center task board.
- `dispatch` - hand a task to another machine (or to whoever is capable and
  idle) with lease/expiry/handoff; accept, renew, release, done, reap, ls,
  worker. See `docs/DISPATCH.md`.
- `linear` - bridge Linear and the shared ledger: pull issues onto the task
  board, push claims/notes/blocks/done back into one persistent comment per
  issue (see `docs/LINEAR.md`).
- `logseq` - bridge the shared ledger into a Logseq graph: export fleet/task
  pages and a journal log, import `#coordkit` TODOs back as ledger tasks.

## Wrapper guidance

When editing a command file:

- Keep the wrapper thin.
- Prefer neutral wording like "shared command spec" or "repo-local script"
  over host-specific behavior language.
- Keep the repo-local shell call explicit so the wrapper remains usable.
- If a host needs special packaging or trust instructions, put those in the
  adapter docs, not the command body.
