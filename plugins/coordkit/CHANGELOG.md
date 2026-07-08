# Changelog

All notable changes to **coordkit** are documented here. This project follows
[Semantic Versioning](https://semver.org/). The plugin `version` field in
`.claude-plugin/plugin.json` is the canonical tooling-version axis — bump it to
ship an update to installed users.

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
- `bin/sync.sh`: failures/timeouts logged to `.claude-bus/sync.log` (rotated)
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
  pre-existing `.claude-bus/` state is handled by the bundled bootstrap/migrate
  scripts on first run.
- Hook commands use exec form (`command` + `args`) so plugin paths containing
  spaces are passed as a single argument with no shell quoting.

### Notes
- The legacy hand-wired hooks under `~/.claude/` are unchanged and are not
  touched by this package; the plugin is an additive, self-contained copy.
