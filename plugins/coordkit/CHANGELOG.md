# Changelog

All notable changes to **coordkit** are documented here. This project follows
[Semantic Versioning](https://semver.org/). The plugin `version` field in
the Claude and Codex plugin manifests is the canonical tooling-version axis.

coordguard used to be a separate plugin on its own version axis; as of 3.0.0 its
enforcement logic is merged in here. It shipped one further release, 2.0.0, as
a deprecation tombstone (no enforcement, just a notice pointing at `/guard
on`), then the package was removed from this marketplace entirely — see below.
Its historical entries are no longer on disk but remain in git history
(`git log -- plugins/coordguard/`).

`skillkit` used to be a separate plugin in this marketplace; as of 4.0.0 it is
merged into coordkit the same way coordguard was at 3.0.0. Its historical
entries are no longer on disk but remain in git history
(`git log -- plugins/skillkit/`).

## 5.0.0

### Added
- A strict automatic-context governor with `quiet`, `compact`, and `debug`
  modes; 600/250/120-token defaults for session, prompt, and collision context;
  bounded top-K task/decision/question/event/peer/message selection; latest-state
  coalescing; unchanged-state TTL suppression; and short on-demand retrieval
  hints instead of unbounded projections.
- Privacy-safe rotating context telemetry under
  `.coordkit-bus/metrics/context.ndjson`. It records byte/token estimates and
  suppression counts, never prompts, paths, event bodies, or generated context.
- Stress coverage with hundreds of ledger records plus peer, inbox, skill TTL,
  package-validation, and hard decoded-output-cap assertions.
- A shipped Codex plugin manifest, repository marketplace, lifecycle hook
  configuration, and payload adapter. The default cross-host
  `hooks/hooks.json` is discovered without an unsupported manifest override and
  dispatches through the host-specific translator. Codex `apply_patch` calls are expanded to
  one shared-core event per path; conservative read-only Bash inspection records
  guard fingerprints; native subagent events map to the existing bus records.
- A bundled `$coordkit` Codex skill for bus, fleet, ledger, messaging, guard,
  and relay operations.
- Host-attributed heartbeats, ledger events, and messages. New records carry
  `host: claude-code|codex|gemini|cli`; session, collision, guard, dashboard,
  and subagent output identifies the owning runtime. Old records render as
  `unknown`.
- A production-capable relay protocol and dependency-free Node 20+ server:
  room-scoped bearer authorization, fsynced append, `eid` deduplication,
  acknowledgements, paginated cursor replay, optional long polling, durable
  client outbox retry, crash-safe cursor advancement, and explicit sync/status
  CLI verbs.
- End-to-end tests for Codex hook translation/guard behavior/host attribution
  and relay auth/dedup/replay/offline recovery.
- Shared ledger cursors now persist per-actor monotonic counters (plus a legacy
  total-order watermark), while projections reconcile by ordered stream
  position. Remote events with lower replica-local sequence numbers and newly
  synced events that sort before the old global watermark are not skipped.
- Relay room initialization is single-flight across concurrent cold-start
  requests. Clients reject arbitrary plaintext HTTP before bearer credentials
  are prepared, with an explicit opt-in limited to loopback development.
- `cobus init-relay` for a secret-free repo pointer, plus a top-level-only TOML
  writer shared with `init-git` so transport setup preserves guard mode.

- **Read-set drift warning ("your mental cache is stale").** `guard.sh` now
  has an always-on `guard_driftreport` phase, wired into `UserPromptSubmit`,
  that tells the model which files it already Read/Write/Edit'd this session
  have since changed on disk — unlike the guard's deny path, this fires in
  coordkit's default `warn` mode too, not just opt-in `guard` mode. It's
  read-only (never mutates guard state), so a file naturally drops off the
  report the next time it's re-Read. Best-effort attribution names a live
  sibling session (sid8 + task) when its bus heartbeat shows it wrote the
  drifted path; otherwise the file is reported with no guessed author.
- **Open questions are now claimable work.** `ledger.sh ask <subject> "<q>"`
  also queues a linked task (`answer-<subject>`) so an idle sibling instance's
  `/led next` can auto-claim "go answer this question" instead of it only
  sitting in the digest's "❓ Open questions" section for a human to notice.
  `answer <subject> "<a>"` closes the loop by marking that linked task `done`
  in the same call, regardless of who (if anyone) claimed it.
- **Guard deny messages now carry best-effort attribution.** When enforcement
  mode denies a Write/Edit, `guard.sh` tries to name WHO likely changed the
  file, not just that it changed: it checks the bus's live heartbeats
  (`agents/<sid>.json`) for a sibling whose recently-touched files include the
  target, then falls back to the file's `claims/<sha>.json` soft lock if no
  live heartbeat matches. A hit appends the session's sid8/branch/task (or
  just sid8 for the weaker claims-only signal) plus a concrete `/msg` or
  `/led ask` suggestion to the deny reason; a miss leaves the message exactly
  as generic as before. Purely a string enrichment — the gate, the fingerprint
  comparison, and the return codes are unchanged.
- **Self-scheduling ledger compaction.** `ledger.sh compact` snapshots the
  ledger's projections into `compacted-<epoch>.json` without touching the
  append-only log, but nothing ever triggered it — it was 100% manual, so in
  practice it never ran. `SessionStart` now checks, once per session (not on
  every prompt — that phase already scans the log once for its own digest, so
  this piggybacks on that same cache for free), whether `max_seq()` has
  drifted more than `COMPACT_EVERY` (200, tunable) events past the last
  compaction recorded for this repo's bus, and if so queues a
  `compact-ledger-<seq>` task onto the existing task queue — claim and run it
  like any other task (`/led claim`/`/led next`, then `cobus compact`, then
  `/led done`). Guarded against duplicate queueing while one is already open
  or claimed. The task subject is suffixed per occurrence rather than fixed,
  because task-status reconciliation compares done/claim/block seqs against
  each other but never against a `task` event's own seq — a fixed subject
  would silently stop showing on the board after its first done cycle,
  defeating the point.
- **`/fleet` (`bus.sh fleet` / `cobus fleet`) — read-only cross-repo fleet
  view.** Shows which OTHER repos on this machine currently have live
  coordkit sessions: `bus.sh`'s `heartbeat()` now also upserts this repo's
  root into a small local registry at `$(ck_data_dir)/fleet.json` (piggybacked
  on heartbeat's existing call sites, independently throttled to `TICK_MIN`
  so it doesn't add a second unthrottled write path), and `/fleet` reads that
  registry and re-derives each repo's live/idle counts + branches at view
  time straight from that repo's own `.coordkit-bus/agents/*.json` — the
  registry never caches liveness. Entries for repos that no longer exist on
  disk are skipped and pruned automatically. This is discovery only, **not**
  cross-repo task dispatch — see `docs/BUS.md` §9 for the explicit scope
  boundary and the local-only privacy guarantee.
- **`cobus swarm <N>` — a queue-draining worker pool.** Spawns `N` (1-8, hard
  ceiling, not configurable) worker loops that each auto-claim a task via the
  ledger's `next`, "execute" it, and report the outcome back — automating what
  was previously a human calling `/led next` by hand, one task at a time.
  Defaults to **DRY RUN**: workers still claim for real (exercising dependency
  ordering and lease/work-stealing), but deliberately do NOT call `done` —
  the claim self-expires via the existing lease TTL instead, since a `done`
  event is a permanent, trusted assertion with no "undone" verb to walk back
  if a dry run silently marked real work complete. Real execution requires
  both `COORDKIT_SWARM_EXEC=1` and `COORDKIT_SWARM_CMD` (a `{desc}`-templated
  shell command); a nonzero exit calls `block` instead of `done`, so a failed
  run never gets marked complete. Never adds a "skip permissions" flag to
  whatever command you configure. See docs/LEDGER.md's new "Swarm mode"
  section for the full design rationale, including the claim-race behavior
  under concurrent cold-started workers and its mitigation.
  - `ledger.sh next` gained a purely-additive `--quiet`/`-q` flag (byte-
    identical output with no flag) so swarm's workers don't have to
    string-match the decorated human-readable "picked next task" / "no open
    tasks" messages.
  - `bus.sh` gained a small `heartbeat` CLI phase: a bare-shell actor like a
    swarm worker has no hook establishing the bus heartbeat `owner_live()`
    needs to treat its claims as in-progress rather than instantly
    reclaimable — this registers one, the same way a hooked session's
    SessionStart/UserPromptSubmit already does.
- **`scripts/signing.sh` — an ed25519 event-signing PROTOTYPE, deliberately
  NOT wired into the write or read path.** A working, self-tested
  sign/verify library (`bash signing.sh selftest`) built around the
  `sig` field `schema/event.schema.json` already reserves. This is inert by
  design, not an oversight: `append_event`/`_ck_emit_v2` still write
  `sig: null` on every real event, and nothing in `ledger.sh`'s digest/delta
  read paths calls into it. See `docs/SIGNING-PROPOSAL.md` for the
  integration proposal (key distribution via committed
  `.claude/coord/keys/<actor>.pub`, gated by the existing `cobus trust`
  mechanism; hot-path cost measurements; and an honest accounting of what
  signing would and would not protect against) that the write/read wiring
  is waiting on.

### Fixed
- **Linked worktrees now share the main checkout's bus.** Bus-root resolution
  follows a worktree's `.git` file back to the main checkout instead of creating
  a second, isolated `.coordkit-bus/` per worktree, so sibling instances working
  in worktrees of the same repo see each other.
- **`bus.sh` tracks `NotebookEdit`** alongside `Write`/`Edit`, so notebook edits
  no longer go unrecorded in the file-touch view.
- **`bus.sh`'s claim-key hashing falls back to `shasum`/`md5`** when `sha1sum`
  is unavailable (macOS), instead of silently collapsing every file's claim
  onto the same key.
- **`init-git.sh` reads the correct bus-directory environment variable**, so
  git-transport initialization lands in the configured bus root.
- **`gc.sh`'s legacy-bus migration is race-safe.** Migrating a pre-4.0.0
  `.claude-bus/` directory can no longer collide with a live instance writing to
  it.
- **`ledger.sh` delta injection tolerates malformed lines** instead of aborting
  the whole injection on one bad record.
- **Torn-line race in the git transport's sync path** — partially written
  segments can no longer be read or replicated mid-append.
- **`migrate.sh` goes through the LogStore abstraction** rather than writing the
  log directly, so migrations respect locking and seq allocation.

### Changed
- Corrected stale ordering-guarantee wording in the transport layer and event
  schema docs, which described guarantees the implementation does not make.
- README no longer states a stale plugin version: the comparison table matches
  the shipped version and the three-layers section points at
  `plugins/coordkit/.claude-plugin/plugin.json` instead of hardcoding a number.

## 4.2.0

### Added
- **`/coordkit:statusline-setup` — coordkit now owns the statusline seam.** The
  `badge` phase is the one part of coordkit a plugin manifest cannot wire: a
  manifest can't register `settings.json`'s top-level `statusLine` key, so the
  badge has always required a hand-written wrapper living outside the plugin.
  Those wrappers rot silently — a real one hardcoded an absolute path to
  `claude-bus.sh` under `coordkit-marketplace/`, both names were later renamed
  (the marketplace dir at HARDEN-3, then `claude-bus.sh` → `bus.sh`), and the
  badge went empty with no error anywhere while the rest of the statusline kept
  working. New `scripts/statusline-setup.sh` makes that wiring a first-class,
  idempotent install step:
  - `install` writes `~/.claude/hooks/coordkit-statusline.sh` and points
    `statusLine` at it. The generated wrapper discovers `bus.sh` **by glob at
    run time** (`~/.claude/plugins/marketplaces/*/plugins/coordkit/scripts/bus.sh`),
    never by a path baked in at install time, so a future rename self-heals
    without re-running anything — and if `bus.sh` is genuinely absent the
    wrapper prints a visible `⚠️ coordkit bus.sh not found` badge instead of
    going quiet.
  - An existing `statusLine` command is **chained, never clobbered**: it runs
    first and the badge is appended after a dim `│` separator, the pattern
    already proven in the hand-written wrapper this replaces. `settings.json`
    is read/written with `jq` and backed up to `settings.json.bak-<timestamp>`
    before any modification; invalid JSON is refused rather than rewritten.
  - Re-running is a no-op when everything is already correct, so it stays safe
    after a coordkit update, a machine move, or a fresh `~/.claude`.
  - `check` (alias `doctor`) is read-only: reports whether `statusLine` is
    wired, whether it resolves to the coordkit wrapper, whether the wrapper's
    glob still finds `bus.sh`, and prints a badge preview. Exits non-zero on a
    genuine problem so it can gate a script, but never crashes.
- **Passive statusline drift check on `SessionStart`.** `coord.sh`'s
  `session-start` now also runs `statusline_drift_note` — two stats and a glob,
  read-only, no writes. Silent unless the wrapper is installed *and* its glob no
  longer resolves, in which case it adds one line to the session's
  additionalContext suggesting `/coordkit:statusline-setup install`. That is
  exactly the state that used to be invisible.

## 4.1.0

### Added
- **`cobus gc` migrates the pre-4.0.0 bus directory name.** coordkit used to
  write state to `<repo>/.claude-bus/`; the 4.0.0 host/adapter reframe renamed
  it to `<repo>/.coordkit-bus/` in code, but that rename doesn't touch state
  already on disk — a repo that ran pre-4.0.0 coordkit is left with a stale
  `.claude-bus/` next to (or instead of) the new `.coordkit-bus/`. `gc` now
  detects it: a plain rename (no data lost) if `.coordkit-bus/` doesn't exist
  yet, folded into the same `--apply` pass as everything else; otherwise just
  a report, since merging two independent `ledger.jsonl` histories risks
  colliding `seq` numbers and isn't attempted automatically.

## 4.0.0

Merges skillkit into coordkit and adds cross-instance subagent visibility.

### Added
- **skillkit's skill auto-activation**, absorbed as-is: a second
  `UserPromptSubmit` hook entry runs `scripts/skill-activation.sh`, matching
  the prompt against layered `skill-rules.json` files (global
  `~/.claude/skills` + per-project) and suggesting skills. Suggest-only,
  same as before — never blocks.
- **10 specialized agents** (`agents/`), the `/dev-docs` and
  `/dev-docs-update` context-persistence commands, `/route-research-for-testing`,
  and the `skill-developer` meta-skill — all moved in from skillkit and now
  available to every instance with coordkit installed, not just skillkit.
- **Cross-instance subagent visibility**: new `PreToolUse`/`PostToolUse` hook
  entries matching the `Task` tool record which subagent (type + description)
  each live instance is currently running, under
  `.coordkit-bus/subagents/<sid>/<tool_use_id>.json`. The `/bus` dashboard now
  shows a SUBAGENTS section per live instance, and launching a subagent whose
  type another live sibling is already running surfaces a non-blocking
  heads-up — same warn-only philosophy as the existing file-collision check.

### Changed
- Reframed the packaging docs around a host/adapter split: coordkit is now
  documented as a host-neutral coordination core, with the Claude Code
  packaging called out as the current adapter.
- Bumped to 4.0.0 for the skillkit merge — a packaging change, not a breaking
  behavior change for either plugin's existing hooks.

### Removed
- **The `coordguard` plugin, entirely.** The 2.0.0 tombstone described under
  3.0.0 below has been deleted from the marketplace and the repo — it's no
  longer listed in `.claude-plugin/marketplace.json` and `plugins/coordguard/`
  is gone. If you still have coordguard installed from before, the marketplace
  no longer serves it, so `/plugin update` won't touch it; run
  `/plugin uninstall coordguard@coordkit` to remove it manually. Nothing
  changes for coordkit itself — this is a marketplace-listing cleanup, not a
  coordkit behavior change.
- **The `skillkit` plugin, entirely.** Its `agents/`, `commands/`, `scripts/`,
  `skills/`, and `templates/` moved into `plugins/coordkit/`; its own
  `.claude-plugin/`, `hooks/`, `README.md`, and `CHANGELOG.md` are gone. If
  you have skillkit installed separately, run
  `/plugin uninstall skillkit@coordkit` — its functionality now ships as part
  of coordkit.

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
