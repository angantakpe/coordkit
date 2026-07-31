# Changelog

All notable changes to **coordkit** are documented here. This project follows
[Semantic Versioning](https://semver.org/). The plugin `version` field in
`.claude-plugin/plugin.json` is the canonical tooling-version axis for the
current Claude Code adapter — bump it to ship an update to installed users.

coordguard used to be a separate plugin on its own version axis; as of 3.0.0 its
enforcement logic is merged in here. It shipped one further release, 2.0.0, as
a deprecation tombstone (no enforcement, just a notice pointing at `/guard
on`), then the package was removed from this marketplace entirely — see below.
Its historical entries are no longer on disk but remain in git history
(`git log -- plugins/coordguard/`).

## Unreleased

### Changed
- Reframed the packaging docs around a host/adapter split: coordkit is now
  documented as a host-neutral coordination core, with the Claude Code
  packaging called out as the current adapter.

### Removed
- **The `coordguard` plugin, entirely.** The 2.0.0 tombstone described under
  3.0.0 below has been deleted from the marketplace and the repo — it's no
  longer listed in `.claude-plugin/marketplace.json` and `plugins/coordguard/`
  is gone. If you still have coordguard installed from before, the marketplace
  no longer serves it, so `/plugin update` won't touch it; run
  `/plugin uninstall coordguard@coordkit` to remove it manually. Nothing
  changes for coordkit itself — this is a marketplace-listing cleanup, not a
  coordkit behavior change.

## 3.0.0

Merges coordguard into coordkit. One plugin, one hook surface, two enforcement
levels.

**Nothing changes for existing users unless they opt in.** Out of the box 3.0.0
behaves exactly like 2.3.0 — warn-only, never denies a tool call.

### Added
- **Guard mode** — coordguard's hard anti-clobber blocker, now built in. When
  enabled, a Write/Edit is denied (PreToolUse `deny`) if the target file changed
  on disk since this session last read it, i.e. a sibling instance edited it.
  Bash calls stay fingerprint-bracketed, so this session's own shell edits
  (`sed -i`, formatters, `git checkout`) don't false-positive. Off by default;
  enable it any of three ways:
  - `/guard on` (per repo),
  - `[enforcement] mode = "guard"` in `.claude/coord/coord.toml`,
  - `COORDKIT_ENFORCEMENT=guard` in the environment (a distinct variable from
    the pre-existing `COORDKIT_MODE`, which selects transport, not enforcement).

### Changed
- **One dispatcher.** The hooks now call a single `scripts/coord.sh`, which
  fans out to the bus, the ledger, and (in guard mode) the guard. `hooks.json`
  fires on the union of both plugins' events; the guard phases are gated behind
  the mode check, so in the default warn-only mode they are no-ops.
- coordguard's `scripts/concurrency-guard.sh` now lives here as
  `scripts/guard.sh`.

### Deprecated
- **The standalone `coordguard` plugin.** It is now a tombstone at 2.0.0 that
  installs no enforcement hooks and only prints a deprecation notice. Switch to
  `/guard on` here and uninstall it. Running both is not harmful, but the
  tombstone does nothing for you.

## 2.3.0

### Changed
- **Consolidated the two task systems into one.** `claude-bus.sh`'s
  `claim`/`done`/`tasks` used to read/write their own `TASKS.md` markdown
  board — a second, simpler, unrelated store sitting alongside the ledger's
  own event-sourced task queue, with confusingly-overlapping verb names.
  `TASKS.md` is gone. `claim "<desc>"` now publishes a task to the ledger
  and immediately leases it in one step (via the shared `slug()`, now in
  `common.sh`, so the computed subject always matches what `/led task` would
  mint for the same text); `done "<text>"` resolves a literal-substring
  match against open ledger tasks and marks that subject done; `tasks`
  prints the ledger's own projected board. Both front-ends write the
  identical event stream now, so a `/claim`'d task is immediately visible to
  `/led next`'s dependency resolution and vice versa.
- Fixed `claim`/`done`/`tasks`'s session-id resolution: these three now use
  `${CLAUDE_SESSION_ID:-cli}` instead of a hardcoded `"cli"`, so a task
  claimed through `/claim` correctly shows as "in-progress" (backed by a real,
  heartbeating bus session) instead of immediately looking abandoned by the
  ledger's work-stealing check. `msg` deliberately keeps `"cli"` — see its own
  inline note.
- Added `claude-ledger.sh done-text "<substring>"`, the phase `claude-bus.sh
  done` now delegates to.

### Added
- `docs/BUS.md` and `docs/LEDGER.md` — the deep-dive documentation this
  consolidation (and the trust-gate/race-fix work before it) never had; the
  README only ever name-dropped these two subsystems in passing.

## 2.2.1

### Changed
- **Extracted `scripts/common.sh`.** `resolve_root()`, `branch_of()`, and the
  actor-identity helpers (`ck_actor`/`ck_clock_c`/`ck_ensure_site`) were
  hand-copied across `claude-bus.sh`, `claude-ledger.sh`, `transports/lib.sh`,
  `bin/sync.sh`, `scripts/init-git.sh`, `scripts/migrate.sh`, `scripts/gc.sh`,
  and `scripts/bootstrap.sh` — 7+ independent copies that could (and once did,
  see 2.1.1's trust-gate work) silently drift from each other, splitting the
  coordination state across two different `.coordkit-bus` trees. Every entrypoint
  now sources one canonical implementation. Pure refactor — no behavior change.

## 2.2.0

Adds the missing lifecycle command, and makes the event schema describe what is
actually implemented.

### Added
- **`cobus gc`** (`scripts/gc.sh`) — manual garbage collection for a repo's
  `.coordkit-bus/`. Reaps hard-stale agent heartbeats, claims with no live owner,
  cursors whose session is gone, and empty inbox dirs; trims an oversized
  `activity.log` to `--keep N` lines. **Dry-run is the default** — nothing is
  deleted without `--apply`. `--nuke` removes the whole bus and is refused
  unless `--yes-i-am-sure` is passed alongside it. This complements (does not
  replace) the automatic `prune_dead` at SessionStart and the 600-line log
  auto-trim, which only ever handled the common cases.

### Changed
- **`schema/event.schema.json` field descriptions now separate implemented from
  reserved behavior.** No structural change — required fields, types, and
  validity are untouched, so every existing event still validates. `clock.c` no
  longer claims to be "advanced past max observed" (it is a plain per-actor
  local counter; cross-replica clock reconciliation is not implemented);
  `sig`, `supersedes`, and `user` are labelled RESERVED / NOT YET IMPLEMENTED,
  since nothing populates or reads them today.

## 2.1.1

Bugfix release: two disk-hygiene leaks in the coordination bus.

### Fixed
- **Empty inbox subdirs no longer accumulate.** `drain_inbox()` deleted each
  `.msg` file but left the `inbox/<sid>/` directory behind, so a long-lived bus
  grew one stub dir per session forever. It now `rmdir`s the drained dir (a
  no-op if still non-empty or already gone), and `stop` (SessionEnd) does the
  same for the exiting session's own inbox dir.
- **Stale claims from crashed sessions are now pruned.** `stop` only releases
  claims owned by the exiting sid and never runs on a crash/kill, so a dead
  session's soft locks lingered on disk indefinitely — `check` silently ignored
  them but never cleaned them up. `prune_dead` (run at SessionStart) now also
  deletes any `claims/<key>.json` whose owning sid has no live agent record
  (including owner-less/corrupt claims), reusing the existing `agent_live`
  staleness helper.

## 2.1.0

Hardening release: fixes every finding from a full-codebase review (5 parallel
review/fix passes over the bus, ledger, transports, packaging, and coordguard).

### Fixed — critical
- **git-mode sync no longer touches the user's checkout.** `__git_sync` used to
  `git add` / `commit` / `pull --rebase --autostash` / `push` on whatever branch
  the user had checked out — a background tick could rebase unpushed commits and
  publish half-finished work. Sync now runs entirely in a private gitignored
  worktree (`<coord>/.sync`) on a dedicated orphan branch (`coordkit/log`,
  override with `COORDKIT_SYNC_BRANCH`); the coord log is gitignored in the
  project and replicated by copying segments up/down. A killed run's in-progress
  rebase is recovered (aborted or the private worktree recreated) on next tick.
- **PowerShell command injection in `notify()`** (WSL): filename/branch text is
  now sanitized (control chars stripped, single quotes doubled) before being
  embedded in the `powershell.exe -Command` string.
- **`Stop` hook no longer wired.** `stop` (heartbeat removal + claim release)
  used to fire at the end of every assistant turn, leaving instances invisible
  to `/bus` between turns; it now runs on `SessionEnd` only.
- **seq counter hardened**: `max_seq` tolerates corrupt/seq-less last lines
  (full tolerant scan instead of resetting to 0), `migrate.sh`'s marker gets a
  real `seq` under lock (it used to poison the counter), and logstore-mode seq
  allocation is atomic under a dedicated lock.
- **Incremental reads**: new watermark-based `logstore_since`/`logstore_watermark`
  (total-order key) replace the lossy positional `logstore_tail` for consumers;
  `tail` remains for back-compat with its limitation documented.

### Fixed — robustness & security
- Relay transport: payload sent via `--data-binary @-` (a leading `@` in an
  event can no longer make curl upload a local file); bearer token moved off
  argv into a 0600 header file; relay fallback lands in the configured backing
  first so relay-mode reads still see the event.
- Actor sanitization rejects `.`/`..` (no more writes escaping `log/`).
- Appends: `flock -w 5` bounded wait, mkdir-lock fallback when `flock(1)` is
  absent (macOS), real failures now propagate to callers.
- `bin/sync.sh`: failures/timeouts logged to `.coordkit-bus/sync.log` (rotated)
  instead of being discarded; repo resolution matches lib.sh (incl.
  `CLAUDE_PROJECT_DIR`); tmp fallback scoped per-user/per-repo.
- Detached HEAD no longer matches as "same branch" (false collision warnings);
  `done` matches task text literally instead of as a sed regex; inbox message
  filenames collision-proofed; `prune_dead` no longer suppresses registration
  of a second live instance (latent since 2.0.0).
- Segment concatenation newline-safe (`awk 1`); TOML values containing `#`
  parse correctly; `bin/cbus`/`cobus`/`sync.sh` work when invoked via symlink.

### Changed
- **v2 envelope now actually the default** (`COORDKIT_EMIT_V2=1`; pin `=0` for
  v1) — 2.0.0 advertised this but shipped it off. Fresh ledgers validate
  against `schema/event.schema.json`, whose `type` is now tolerant of unknown
  values as documented. The ledger self-bootstraps `site.json` (`bootstrap.sh`
  is optional/manual).
- `init-git.sh` migrates a pre-existing local-mode log into the git-mode tree
  (the "no migration needed" claim in 2.0.0 was wrong) and emits protocol
  `2.0` metadata consistent with `templates/coord.toml` and
  `schema/MANIFEST.json`.
- Slash commands: user text is no longer interpolated into `!` auto-exec lines
  (raw preprocessing substitution was injectable); user-text-carrying calls are
  model-issued with single-quoted arguments, and `allowed-tools` covers every
  documented invocation.

### Notes
- coordguard (separate plugin) went to 1.1.0 in the same pass: hasher fallback
  chain (`sha1sum`→`shasum`→`md5sum`→`md5`, fail-open) fixes a fail-closed on
  macOS, mtime+size fingerprint catches same-second sibling writes, and a
  `SessionEnd` cleanup phase removes the session's `/tmp` state.
- In repos with a commit-message-format pre-push hook (e.g. this user's global
  `Project/ISSUE - datetime - desc` hook), pushes of the `coordkit/log` branch
  will be rejected unless the hook exempts that branch or `COMMIT_FORMAT_SKIP=1`
  is set for the sync timer. coordkit deliberately does not bypass it.

## 2.0.0

First packaged release. Repackages the working same-machine coordination system
(previously a loose set of `~/.claude/hooks/*.sh` scripts wired by hand in
`settings.json`) as an installable, versioned Claude Code plugin distributed
through a git marketplace.

### Added
- **Distribution layer.** Ships as the `coordkit` plugin in the
  `coordkit-marketplace` marketplace. Installable per-user or per-project via
  `claude plugin install coordkit@coordkit-marketplace`; updates are delivered by
  bumping this `version`.
- **Six lifecycle hooks**, wired in `hooks/hooks.json` and invoked through
  `${CLAUDE_PLUGIN_ROOT}` so the plugin is path-independent:
  - `SessionStart` → bus `start`, ledger `start`
  - `UserPromptSubmit` → bus `task`, ledger `prompt`
  - `PreToolUse` (Write|Edit) → bus `check`
  - `PostToolUse` (Write|Edit|Read|Bash) → bus `record`
  - `Stop` → bus `stop`
  - `SessionEnd` → bus `stop`
- **WARN-only contract.** coordkit observes and surfaces concurrent activity; it
  never denies a tool call. The hard anti-clobber blocker lives in the separate
  `coordguard` plugin so this contract stays clean.

### Changed
- **v2 event envelope.** Events written to the per-repo bus/ledger use the v2
  envelope (see the bundled `schema/` and `transports/` layers). Migration of
  pre-existing `.coordkit-bus/` state is handled by the bundled bootstrap/migrate
  scripts on first run.
- Hook commands use exec form (`command` + `args`) so plugin paths containing
  spaces are passed as a single argument with no shell quoting.

### Notes
- The legacy hand-wired hooks under `~/.claude/` are unchanged and are not
  touched by this package; the plugin is an additive, self-contained copy.
