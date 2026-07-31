# coordkit

A host-adapter marketplace for same-machine, multi-instance coordination. It
packages a working coordination core so it becomes installable, shareable, and
semver-versioned instead of a hand-wired set of host-specific hook scripts.
This repository currently ships the Claude Code adapter, as a single plugin
named `coordkit`.

It ships **one plugin**:

| Plugin             | Version | Contract                                                          | What it does                                                                                                                                                                                                                                                                                               |
| ------------------ | ------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **coordkit** | 4.0.0   | **WARN-only by default; opt-in HARD guard via `/guard on`** | A per-repo bus + cross-instance ledger + an anti-clobber guard + skill auto-activation. Tracks who else is live in a repo, which files they touch, and which subagents they're running, and surfaces it so parallel sessions can reconcile instead of stepping on each other and duplicating work — and, where you ask for it, *denies* an edit that would clobber theirs. Also matches prompts against layered `skill-rules.json` trigger rules (global `~/.claude/skills` + per-project) and injects "use this skill" reminders, and ships a shared roster of specialized agents and the `/dev-docs` context-persistence commands. |

> **`coordguard` and `skillkit` have both been merged in.** Through 2.x, the
> hard anti-clobber blocker shipped as a separate `coordguard` package. As of
> coordkit **3.0.0** that blocker lives inside coordkit as opt-in
> [guard mode](#enforcement-modes); `coordguard` itself has since been deleted
> from this marketplace and repo entirely. As of **4.0.0**, `skillkit` (skill
> auto-activation + agents + dev-docs) is merged in the same way. If you still
> have either installed separately, `/plugin update` won't fix it (the
> marketplace no longer serves them as separate entries) — run
> `/plugin uninstall coordguard@coordkit` and/or
> `/plugin uninstall skillkit@coordkit` manually. See [Install](#install).

## Documentation

This README covers install/quickstart. For how coordkit's pieces actually work
under the hood:

- **[docs/BUS.md](docs/BUS.md)** — the awareness layer: heartbeats, liveness,
  the age-aware collision warning, messaging, the statusline badge.
- **[docs/LEDGER.md](docs/LEDGER.md)** — the shared-context layer: the
  event-sourcing model, the task queue (leases, auto-claim, work-stealing),
  pagination/digests, and the git-mode trust gate.
- **[docs/STATUSLINE.md](docs/STATUSLINE.md)** — the statusline badge: what it
  shows, why a plugin manifest can never wire it, and how to keep it wired.
- **[docs/HOSTS.md](docs/HOSTS.md)** — the host/adapter split: what belongs to
  the shared coordination core, what stays adapter-specific, and what is still
  Claude-only today.
- **[Enforcement modes](#enforcement-modes)** (below) — the guard layer: what
  `warn` vs `guard` mode actually do, how the mode is resolved, and the honest
  version of the safety story now that both live in one plugin.

## Host model

coordkit's coordination core is host-neutral. A host adapter is the thin layer
that maps a specific host's lifecycle events, environment variables, command
surface, and packaging conventions onto the shared bus, ledger, and guard.

The Claude Code adapter is the one shipped in this repository today. Its
`CLAUDE_*` variables, `.claude/` paths, and slash-command wiring are adapter
details, not requirements of the coordination model itself. The runtime now
accepts `COORDKIT_*`, `CLAUDE_*`, `CODEX_*`, and `GEMINI_*` adapter aliases
for the shared shell helpers. Adapter slots for Claude Code, Codex, and Gemini
live in [`plugins/coordkit/adapters/`](/home/anga/workspace/projects/coordkit/plugins/coordkit/adapters/).
The Claude slot is shipped; the Codex and Gemini slots are scaffolded and use
the same core concepts and on-disk coordination state.

## Enforcement modes

*(This section covers coordkit's bus/guard layers only. Skill auto-activation
is unrelated and always suggest-only — it's never gated by enforcement mode.)*

coordkit's default contract is unchanged from 2.x: it **observes and reports, it
never wedges a tool call**. That's what makes it safe to leave installed
everywhere, in every repo, forever. **Guard mode** is the opt-in exception: it
adds a hard `deny` on `Write`/`Edit` when the target file changed on disk since
this session last read it — the signature of another instance having edited it
underneath you.

| Mode                     | What happens on a `Write` / `Edit`                                                                                                                                                  |
| ------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **`warn`** *(default)* | Never denies. You still get the bus's soft collision warning and a debounced desktop notification when a **live sibling session** holds a claim on that file. The edit proceeds. |
| **`guard`**        | The above, **plus** a `deny` when the file's on-disk fingerprint (`mtime:size`) changed since this session last read it — whether or not any sibling is still alive. Re-`Read`, reconcile, then edit. |

Note that these are two different questions, not one behavior with the volume
turned up. The warning asks *"is a live sibling working in this file?"*; the deny
asks *"did this file change under me?"* — which catches cases the warning cannot
(a sibling that already exited, a `git pull`, an editor outside the Claude
adapter), and
misses cases the warning catches (a live sibling who hasn't written yet). Both
run in guard mode, guard's check first. See
[docs/BUS.md §8](docs/BUS.md#8-the-bus-and-guard-mode) for the side-by-side.

### Resolving the mode

`ck_enforcement_mode()` in `scripts/common.sh` resolves the active mode. First
match wins:

1. **`COORDKIT_ENFORCEMENT=guard|warn`** in the environment — per-shell, highest
   priority, good for a one-off session.
2. **`.claude/coord/coord.toml`** → `mode` inside the `[enforcement]` table —
   per-repo and **committable**, so a team can opt an entire repository in for
   everyone who clones it:

   ```toml
   [enforcement]
   mode = "guard"
   ```
3. **`$(ck_data_dir)/config`** → `enforcement=guard` — per-user, applies across
   every repo on this machine.
4. **Default: `warn`.**

`/guard on|off|status` writes level 2 and reports the currently resolved mode
*plus which level supplied it* — so "why is this denying?" (or "why isn't it?")
is always one command away rather than a hunt through three config sites.

> **One nearby name to keep straight.** `coord.toml`'s **top-level** `mode` key
> is a different setting entirely: it selects the ledger **transport**
> (`local` / `git` / `relay`, see [docs/LEDGER.md](docs/LEDGER.md) §4), and
> `COORDKIT_MODE` overrides *that*. Enforcement has its own variable and its own
> table. A single `coord.toml` can carry both, answering unrelated questions:
>
> ```toml
> mode = "git"      # transport: share the ledger over a git remote
>
> [enforcement]
> mode = "guard"    # enforcement: deny edits that would clobber a sibling
> ```

### The honest version of the safety story

Through 2.x, "coordkit never blocks" was a **structural** guarantee: coordkit
could not block because the blocking code was not in the package. You opted in
by installing a second plugin. That guarantee is now **weaker**. coordkit 3.0.0
ships the deny path, and it is inert only because a config check says so.

That's a real reduction, and it's worth being clear-eyed about rather than
papering over. What stands in its place:

- **The gate is one auditable early exit.** The mode check is the *first*
  statement in guard's `check` phase — it returns a no-op unless
  `ck_enforcement_mode()` resolved to `guard`. Verifying "this cannot deny in my
  configuration" means reading one function, not reasoning about a whole
  subsystem.
- **Fail-open discipline is unchanged.** Any error inside the guard — missing
  state, an unreadable file, a hashing tool that isn't installed — results in
  *allowing* the tool call, never denying it. A guard that breaks degrades to
  warn-only rather than wedging your session.
- **The false-positive suppression is unchanged.** The `snapshot`/`absorb` pair
  around Bash still keeps the session's own shell mutations from tripping a deny;
  see [What gets wired](#what-gets-wired).

And one property genuinely improved. Opting in used to require installing a
second plugin *on every machine* — per-user state that a repository has no way to
express. The `coord.toml` route is per-repo and committed, so "this repo is
routinely edited by several agents at once and wants a hard guard" travels with
the repository instead of depending on each teammate having independently
installed the right thing.

## The three layers

This package is organized as three independent layers so each can evolve on its
own axis:

1. **Distribution / packaging** *(this README, the marketplace, plugin manifests,
   hook wiring)* — how the system is installed, versioned, and updated. The
   coordkit `version` (currently `3.0.0`) is the tooling-version axis. The
   2.3.0 → 3.0.0 major bump is a change on *this axis only* — folding coordguard
   in changed the hook surface and the safety contract, and deliberately did not
   touch layers 2 and 3. Guard mode keeps its own state and emits no events, so
   the on-disk event format and the delivery mechanism are byte-identical to
   2.3.0.
2. **Schema** *(`plugins/coordkit/schema/`)* — the versioned event envelope
   plus its JSON Schema, manifest, and migrations. The envelope version is
   configurable and the ledger accepts either version on read; this is the
   on-disk format axis, versioned independently of the tooling.
3. **Transport** *(`plugins/coordkit/transports/`)* — how events move: `local`
   (the per-repo `.coordkit-bus/` directory), and optional `git` / `relay`
   backends behind a common `lib.sh`. This is the delivery axis.

## Install

Add the marketplace, then install the plugin(s):

```bash
# From a hosted git remote (GitHub/GitLab/git URL):
/plugin marketplace add <owner>/coordkit
# ...or from a local clone:
/plugin marketplace add ./coordkit

/plugin install coordkit@coordkit
```

**One plugin covers everything now.** Installing `coordkit` gives you the
warn-only bus, ledger, and skill auto-activation immediately; running `/guard
on` inside a repo adds the hard anti-clobber guard *there*. There is no second
plugin to install for full functionality.

> **Distribution reality check.** As currently configured this repo's only
> remote is **private** (`git@github.com:angantakpe/coordkit.git`),
> so the hosted `/plugin marketplace add <owner>/coordkit` form
> works **only for the repo owner and anyone explicitly granted access** — for
> everyone else it fails at clone time. Genuinely shareable distribution needs
> either making the repo public or documenting an access-request path; neither
> has been done. Until then, the local-clone form
> (`/plugin marketplace add ./coordkit`) is the path that works for
> anyone who has the files.

To use skill auto-activation, seed your global rules file (the schema is
documented inline in `plugins/coordkit/scripts/skill-activation.sh`'s header
comment):

```bash
cp <plugin-root>/templates/skill-rules.example.json ~/.claude/skills/skill-rules.json
```

### Migrating from 2.x + coordguard, or from separate coordkit + skillkit

If you were running the pre-3.0.0 two-plugin coordguard setup, uninstall the
old blocker and turn guard mode on in the repos that relied on it:

```bash
/plugin uninstall coordguard@coordkit
/guard on          # run inside each repo that wants the hard guard
```

If you had `coordkit` and `skillkit` installed as two separate plugins
(pre-4.0.0), uninstall skillkit — its functionality now ships as part of
coordkit, with nothing else to configure:

```bash
/plugin uninstall skillkit@coordkit
```

Neither `coordguard` nor `skillkit` is listed in this marketplace as a
separate entry anymore — `coordguard` briefly shipped one further release as a
deprecation tombstone (v2.0.0, no enforcement hooks, just a one-time notice)
before being deleted entirely; `skillkit` was folded straight in at 4.0.0.
`/plugin marketplace update` won't remove a pre-existing install for you (the
catalog simply no longer offers updates for it); the uninstalls above are the
only way to clear them. Running a stale 2.x coordguard *and* coordkit 3.0.0+
with guard mode on is the case worth actually avoiding — two independent
blockers on the same `PreToolUse` event keeping two separate fingerprint
stores, which mostly buys
you confusing double denies.

### Scopes

- **User scope** (default) — installs for your account across every project. Best
  for coordkit, since you want awareness everywhere you run the Claude
  adapter.
- **Project scope** — check the plugin into a repository so every collaborator who
  clones it gets the same coordination behavior. Project-scope plugins load only
  after the repository trust gate, and components that run code (hooks) are
  restricted further; personal/user scope has no such restriction.

Updates ship by bumping the plugin `version`; users pull them with
`/plugin marketplace update` followed by `/plugin update`.

## What gets wired

**coordkit** registers five lifecycle events across ten hook entries. Nine of
them invoke the *same* dispatcher —
`${CLAUDE_PLUGIN_ROOT}/scripts/coord.sh` (via `${CLAUDE_PLUGIN_ROOT}` so the
install location doesn't matter). `coord.sh` sources `bus.sh`, `ledger.sh`, and
`guard.sh` as **libraries** and runs their phases in-process, so a hook event
costs one shell rather than one shell per subsystem. The tenth entry —
`skill-activation.sh` on `UserPromptSubmit` — is a separate, stateless script
(merged in from skillkit at 4.0.0), invoked directly rather than through
`coord.sh`:

| Event                | Matcher                            | Script / `coord.sh` subcommand | Phases run, in order                                                     |
| -------------------- | ---------------------------------- | ----------------------- | ------------------------------------------------------------------------ |
| `SessionStart`     | —                                 | `session-start`       | bus `start` → ledger `start`                                       |
| `UserPromptSubmit` | —                                 | `prompt-submit`       | bus `task` → ledger `prompt`                                       |
| `UserPromptSubmit` | —                                 | `skill-activation.sh` | matches the prompt against `skill-rules.json`, suggests skills (suggest-only) |
| `PreToolUse`       | `Write\|Edit\|NotebookEdit`       | `pretool-write`       | guard `check` (**may `deny` — guard mode only**) → bus `check` (warn) |
| `PreToolUse`       | `Bash`                           | `pretool-bash`        | guard `snapshot` (fingerprint tracked files)                             |
| `PreToolUse`       | `Task`                           | `pretool-task`        | bus `subagent-start` (record + soft same-type heads-up, never denies)    |
| `PostToolUse`      | `Write\|Edit\|NotebookEdit\|Read` | `posttool-write`      | bus `record` → guard `record`                                      |
| `PostToolUse`      | `Bash`                           | `posttool-bash`       | bus `record` → guard `absorb` (re-stamp self-inflicted changes)     |
| `PostToolUse`      | `Task`                           | `posttool-task`       | bus `subagent-stop` (drop the running-subagent record)                   |
| `SessionEnd`       | —                                 | `session-end`         | bus `stop` (also clears any still-running subagent records) → guard `cleanup` |

`PostToolUse` is split by matcher rather than one combined
`Write|Edit|NotebookEdit|Read|Bash|Task` entry, because each tool group needs a
different phase (Bash needs guard's `absorb`, Task needs `subagent-stop`, the
rest need `record`).

Guard runs *before* the bus on `pretool-write`, and a deny **short-circuits** —
`coord.sh` exits without running the bus check at all, since a soft "someone else
touched this" warning adds nothing to a call that's already been stopped. In warn
mode guard's check is a no-op and the bus check always runs.

Only guard's `check` consults the enforcement mode. Every other guard phase —
`snapshot`, `record`, `absorb`, and `cleanup` — runs in **both** modes: they
only maintain the fingerprint store (and, at session end, remove it), and none of
them can deny. That's what lets `/guard on` take effect immediately and apply to
files you already read, rather than starting from an empty store at the moment
you flip it.

Because the phases share one process, `SessionStart` and `UserPromptSubmit` also
merge the bus's and the ledger's injected context into a single
`additionalContext` payload instead of emitting two competing ones.

The `snapshot`/`absorb` pair brackets every Bash call so files modified by this
session's **own** shell commands (`sed -i`, formatters, `git checkout`) don't
trip a false-positive deny on the next Write/Edit: a tracked file that was clean
when the command started and changed while it ran is re-stamped as ours. A file
that was already stale before the Bash call (a sibling edited it earlier) is
deliberately not absorbed and still denies. Files the session never Read —
including files its Bash commands *create* — remain untracked: Read once to
adopt them.

## Runtime behavior — verified

Both prior caveats were tested on Claude Code **v2.1.193** (empirical dry-run via
`claude --plugin-dir` + the official docs) and **resolved**:

- **`bin/` IS on `PATH`.** When the plugin is enabled, its `bin/` dir is added to
  the Bash tool's `PATH` (confirmed: a `--plugin-dir` dry-run showed
  `…/coordkit/bin` in `$PATH`; docs: *"Executables added to the Bash tool's PATH
  while the plugin is enabled"*). Hooks still reference scripts via
  `${CLAUDE_PLUGIN_ROOT}/…` (correct, since the plugin is copied to a versioned
  cache). The `bin/` CLIs also self-resolve their root from `$0` as a belt-and-braces fallback.
- **`SessionStart` additionalContext works.** No issue #16538 exists in the
  current changelog; `hookSpecificOutput.additionalContext` from a plugin
  `SessionStart` hook is injected (since v2.1.152+) and even re-runs on resume.
  the ledger's `start` phase injects the shared-context digest on `SessionStart`
  directly.

## Maintenance — garbage-collecting a bus

`.coordkit-bus/` state is pruned opportunistically (dead heartbeats and their
orphaned claims at `SessionStart`; `activity.log` auto-trimmed past 600 lines),
but nothing ever cleans a bus you've stopped using. `cobus gc` is the manual
pass — **dry-run by default, it deletes nothing without `--apply`**:

```bash
cobus gc                    # report what would be reaped, change nothing
cobus gc --apply            # actually reap
cobus gc --apply --keep 100 # ...and trim activity.log harder
```

It reaps hard-stale agent records, claims with no live owner, cursors whose
session is gone, and empty inbox dirs. To abandon a project's bus entirely
there is `--nuke`, which is deliberately double-gated because it discards the
shared ledger and all history irreversibly, for every instance:

```bash
cobus gc --nuke --yes-i-am-sure --apply
```

`cobus gc` also migrates the pre-4.0.0 bus directory name: coordkit used to
write state to `.claude-bus/`, renamed to `.coordkit-bus/` at 4.0.0. If a repo
still has a `.claude-bus/` sitting next to (or instead of) `.coordkit-bus/`,
`cobus gc` finds it — a plain rename if `.coordkit-bus/` doesn't exist yet (no
data lost, folded straight into the same `--apply` pass), or just a report if
both exist (it won't auto-merge two `ledger.jsonl` histories — remove the
legacy one yourself once you've checked it).

Persistent identity (site id, clock counter) lives in `${CLAUDE_PLUGIN_DATA}`,
which **survives plugin updates** (the versioned `${CLAUDE_PLUGIN_ROOT}` cache does not).

## Git-mode sharing (team, no server)

Turn the coordination log into a committed, mergeable artifact replicated over a
plain git remote — no server, no daemon:

```bash
# in your project repo:
bash ${CLAUDE_PLUGIN_ROOT}/scripts/init-git.sh <room_id> [remote]
git add .claude/coord .gitignore && git commit -m "coordkit: enable git mode"
git push
```

A **fresh clone auto-joins** — the committed `.claude/coord/coord.toml` (`mode=git`)
self-describes the room, so teammates just `git pull`; no env var, no setup. Each
machine writes to its own actor-partitioned segment
(`.claude/coord/log/<actor>/…ndjson`), so concurrent writers touch disjoint files
(structurally conflict-free); `*.ndjson merge=union` is the backstop if one actor
id is reused across clones. Drive replication **out of the hook path** on a timer:

```bash
watch -n15 '${CLAUDE_PLUGIN_ROOT}/bin/sync.sh'   # or cron / systemd timer / a background loop
```

`sync.sh` is debounced, `flock`-guarded, and `timeout`-bounded — never call it from
a hook (git network must stay off the tool-call critical path). Solo users who never
run `init-git` keep the zero-dependency local default, byte-identical to today.
