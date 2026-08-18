# coordkit

CoordKit is infrastructure for coordinating multiple coding agents working on
the same repository, not an autonomous software-delivery system by itself. It
packages a shared coordination runtime so it becomes installable, shareable,
and semver-versioned instead of a hand-wired set of host-specific hook scripts.
This repository ships Claude Code and Codex adapters as one plugin named
`coordkit`, plus an optional authenticated relay server for cross-machine use.

## What CoordKit actually does

CoordKit acts like a coordination layer between coding-agent sessions.

When several Claude Code or Codex agents work inside one repository, CoordKit
helps them answer:

- Which agents are currently active?
- What branch are they working on?
- Which files are they modifying?
- Are two agents about to edit the same file?
- What task is each agent handling?
- How can one agent leave information for another?
- How can agents coordinate across different computers?
- What context should be injected into a new agent session?

The canonical coordination runtime lives in `plugins/coordkit/scripts/core/scripts`.
`plugins/coordkit/scripts` contains synchronized distribution copies so the
installed plugin remains self-contained inside a versioned host cache; package
tests reject drift between those two trees.

## The architecture

```text
Claude Code ─┐
             ├── Host adapters
Codex ───────┘
                    │
                    ▼
             CoordKit plugin
                    │
       ┌────────────┼────────────┐
       ▼            ▼            ▼
     Bus          Ledger        Relay
 real-time      durable        cross-machine
 coordination   history        synchronization
```

1. Bus - current coordination state

The bus handles short-lived, operational information:

- Agent heartbeats
- Active sessions
- Current branch
- File claims
- Agent inboxes
- Collision warnings

This is how CoordKit knows that 13 peers are active or that two agents may edit
the same file.

2. Ledger - durable coordination history

The ledger is an append-only record containing things such as:

- Tasks
- Decisions
- Agent notes
- Status changes
- Shared context
- Completed work

The bus answers:

What is happening now?

The ledger answers:

What happened, what was decided, and what remains?

3. Relay - synchronization across machines

Without the relay, coordination is mainly local to the repository or machine.

The relay service allows:

```text
Laptop A running Claude Code
             │
             ▼
      Authenticated relay
             ▲
             │
Laptop B running Codex
```

The relay makes the shared state available to agents that are not using the
same filesystem. On top of any shared mode (git or relay), `cobus dispatch`
hands a task from one machine to another with a lease and a worker loop —
see [docs/DISPATCH.md](docs/DISPATCH.md).

4. Host adapters - Claude Code and Codex integration

Claude Code and Codex expose different extension systems, so CoordKit
translates its functionality into each host.

Claude Code
├── hooks
├── commands
├── plugin integration
└── session context injection

Codex
├── skill integration
├── translated hooks
├── session initialization
└── context injection

It ships **one plugin**:

| Plugin             | Version | Contract                                                          | What it does                                                                                                                                                                                                                                                                                               |
| ------------------ | ------- | ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **coordkit** | 5.3.0   | **WARN-only by default; opt-in HARD guard** | A per-repo bus + append-only ledger + host-attributed collision warnings + an authenticated relay with outbox/replay + an anti-clobber guard. The command surface is defined once as shared specs, then exposed through Claude Code slash-command wrappers, Codex skill surfaces, and native agents. |

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
  pagination/digests, and the non-local transport trust gate.
- **[docs/PRESENCE.md](docs/PRESENCE.md)** — the cross-machine presence
  layer: `cobus heartbeat` / `cobus peers` (who is alive on which machine,
  what it is doing, with what capabilities) and `cobus watch` (a live tail of
  the shared event stream over relay long-poll / git sync / local).
- **[docs/DISPATCH.md](docs/DISPATCH.md)** — cross-machine task dispatch
  (`cobus dispatch`): hand a task to a specific machine or to whoever is
  capable and idle, with leases, expiry/reap, first-accept-wins race
  resolution, the `worker` loop, and the presence (heartbeat) contract.
- **[docs/architecture.md](docs/architecture.md)** — the high-level repo map:
  the recommended target layout, the current layering, and the migration
  direction.
- **[docs/RELEASE.md](docs/RELEASE.md)** — the release checklist and tag
  convention.
- **[docs/STATUSLINE.md](docs/STATUSLINE.md)** — the Claude statusline badge:
  what it shows, why a manifest cannot wire it, and how to keep it wired.
- **[docs/HOSTS.md](docs/HOSTS.md)** — the host/adapter split: what belongs to
  the shared coordination core, what stays adapter-specific, and how shared
  command specs get wrapped for each host.
- **[CONTRIBUTING.md](CONTRIBUTING.md)**, **[SECURITY.md](SECURITY.md)**,
  **[SUPPORT.md](SUPPORT.md)**, and **[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)**
  — the public-project hygiene docs that open-source users expect to find.
- **[plugins/coordkit/commands/README.md](plugins/coordkit/commands/README.md)** —
  the shared command-spec source of truth for the command surface.
- **[Enforcement modes](#enforcement-modes)** (below) — the guard layer: what
  `warn` vs `guard` mode actually do, how the mode is resolved, and the honest
  version of the safety story now that both live in one plugin.

## Requirements

The repo is intentionally lightweight, but the actual scripts still assume a
small toolchain:

- Bash 4 or newer
- `jq`
- `python3`
- `make`
- `node` 20 or newer for the relay service and `node --check`
- `git`

The shell scripts use Bash features such as `mapfile` and lowercase expansion,
so the stock macOS `/bin/bash` 3.2 is not sufficient.

## Host model

coordkit's coordination core is host-neutral. A host adapter is the thin layer
that maps a specific host's lifecycle events, environment variables, command
surface, and packaging conventions onto the shared bus, ledger, and guard.

Claude Code and Codex adapters are shipped. Claude's `CLAUDE_*` variables,
`.claude-plugin/` packaging, and slash-command wrapper files are adapter
details. Codex has its own `.codex-plugin/plugin.json`, lifecycle hook schema,
`apply_patch` translation, native subagent mapping, `$coordkit`, and
`$agent-orchestrator` skills. Both use the same bus, ledger, guard, schema,
transports, agent definitions, command specs, and `.coordkit-bus` state. The
shared runtime accepts `COORDKIT_*`, `CLAUDE_*`, and `CODEX_*` aliases. Each
heartbeat records `host`, so warnings identify the sibling as `claude-code`,
`codex`, or `cli`.

### Portable agent runtime

The files under `plugins/coordkit/agents/*.md` are executable prompt artifacts,
not documentation. Their YAML frontmatter supplies identity, role family,
lifecycle stage, and routing context; their Markdown bodies are the role
instructions. At session start, both shipped host adapters validate and compile them to
`<plugin-data>/agents/catalog.json`. The catalog includes a digest of every
source file, so stale or malformed definitions are visible rather than silently
ignored.

If session-start compilation fails, CoordKit removes the stale catalog, writes
`<plugin-data>/agents/catalog.error.json`, and emits one bounded warning. Hook
execution remains fail-open, but consumers cannot mistake an older catalog for
the current source.

The catalog is deliberately split into two families. The five `orchestration`
roles form a lifecycle: work-graph planning, conflict-free dispatch, bounded
implementation, integration, and independent goal verification. The five
`system` roles diagnose CoordKit's own state, ledger convergence, transports,
host adapters, and context governor. This keeps reusable workflow responsibilities
separate from CoordKit maintenance expertise.

Claude Code can invoke the top-level definitions through its native agent
discovery. Codex uses `$agent-orchestrator`: it ranks the same catalog, renders
the selected Markdown into a bounded assignment, and passes that assignment to
a native Codex subagent. The host owns model/tool execution; CoordKit owns
definition loading, routing, prompt rendering, and lifecycle visibility.

The same runtime is inspectable without either host:

```bash
cobus agents validate
cobus agents list
cobus agents workflow
cobus agents route --role-type orchestration 'split this feature into safe parallel tasks'
cobus agents render work-graph-planner --task 'Plan this feature.' --cwd "$PWD"
```

`render` prints a prompt; it never executes definition or ledger content.

## Token-efficient context

CoordKit keeps the complete coordination record on disk but sends only a
bounded, relevant projection to the model. The default `[context]` profile in
`plugins/coordkit/templates/coord.toml` is deliberately small:

| Control | Default | Environment override |
| --- | ---: | --- |
| Context mode | `compact` | `COORDKIT_CONTEXT_MODE` |
| Session-start budget | 160 estimated tokens | `COORDKIT_CONTEXT_SESSION_START_TOKENS` |
| Prompt-delta budget | 96 estimated tokens | `COORDKIT_CONTEXT_PROMPT_TOKENS` |
| Collision budget | 64 estimated tokens | `COORDKIT_CONTEXT_COLLISION_TOKENS` |
| Token estimate | 4 bytes/token | `COORDKIT_CONTEXT_BYTES_PER_TOKEN` |
| Tasks | 2 | `COORDKIT_CONTEXT_MAX_TASKS` |
| Decisions | 1 | `COORDKIT_CONTEXT_MAX_DECISIONS` |
| Questions | 1 | `COORDKIT_CONTEXT_MAX_QUESTIONS` |
| Delta events | 3 | `COORDKIT_CONTEXT_MAX_EVENTS` |
| Direct messages | 2 | `COORDKIT_CONTEXT_MAX_MESSAGES` |
| Peers | 1 | `COORDKIT_CONTEXT_MAX_PEERS` |
| Event body | 80 characters | `COORDKIT_CONTEXT_EVENT_BODY_CHARS` |
| Repeat TTL | 3600 seconds | `COORDKIT_CONTEXT_REPEAT_TTL_SECONDS` |
| Metrics file rotation | 262144 bytes | `COORDKIT_CONTEXT_METRICS_MAX_BYTES` |
| Claude skill suggestions | top 1 | `COORDKIT_CONTEXT_SKILL_TOP_K` |

All numeric controls must be positive integers. Invalid environment values
fall back to `coord.toml`, then to the defaults above. Token counts are a cheap,
deterministic byte estimate controlled by `bytes_per_token`, not a claim about
any provider's exact tokenizer.

The three modes trade automatic detail for prompt cost:

- **`quiet`** — inject only critical collision/deny information and direct
  inbox messages. Hard budgets still apply; collision/deny alerts are never
  hidden by repeat suppression.
- **`compact`** *(default)* — apply hard budgets, top-K category caps, and
  hash-plus-TTL deduplication. Unchanged hook context is silent.
- **`debug`** — keep the configured caps but disable repeat deduplication so
  every selected payload can be inspected. Metrics remain local and are never injected.

Nothing is deleted when an item is omitted from automatic context. Use
`$coordkit` in Codex, `/ctx` in Claude Code, or `cobus digest` in a terminal to
retrieve current detail on demand. Hook telemetry is written locally to
`.coordkit-bus/metrics/context.ndjson` and rotates to `context.ndjson.1`; it
records the event, host, bytes, estimated tokens, suppression count, and reason,
without adding those measurements to the model prompt.

The relay transports events and **does not consume model tokens** by itself;
tokens are used only when a bounded projection of received events is later
injected. To reduce host-level usage beyond CoordKit, start a fresh session at
phase boundaries, keep `AGENTS.md` focused, disable unrelated plugins for the
project, load skills only when the task needs them, store long logs/notes in
files and reference them, and give subagents bounded context instead of full
conversation history.

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

See [docs/architecture.md](docs/architecture.md) for the target layout, the
dependency direction, and the plain-English explanation of each top-level area.

## The three layers

This package still has three separate concerns: distribution/packaging, schema,
and transport. The details live in the linked docs and the code itself.

## Install

Claude Code:

```bash
# From a hosted git remote (GitHub/GitLab/git URL):
/plugin marketplace add <owner>/coordkit
# ...or from a local clone:
/plugin marketplace add ./coordkit

/plugin install coordkit@coordkit
```

Codex CLI, from a local clone:

```bash
codex plugin marketplace add /path/to/coordkit
codex plugin add coordkit@coordkit
```

Start a new Codex session, open `/hooks`, and trust the CoordKit hook definition.
Codex deliberately skips new or changed command hooks until their exact hash is
reviewed. Use `$coordkit` for the bus, ledger, messaging, guard, fleet, and relay
operations that Claude exposes as slash commands.

**One plugin covers both hosts.** Installing `coordkit` gives you the warn-only
bus and ledger. Claude also gets skill auto-activation; Codex gets the bundled
`$coordkit` skill. `/guard on` in Claude, or `$coordkit` with guard `on` in
Codex, adds hard anti-clobber enforcement for that repository.

> **Distribution reality check.** The hosted
> `/plugin marketplace add <owner>/coordkit` form works only for people who can
> clone the repository. If the repo is private or access-controlled, that means
> the owner and anyone explicitly granted access; if it is public, it works for
> anyone with the URL. When access is the limiting factor, the local-clone form
> (`/plugin marketplace add ./coordkit`) is the path that works for anyone who
> has the files.

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

CoordKit is MIT-licensed. See [LICENSE](LICENSE).

## What gets wired

The **Claude adapter** registers five lifecycle events across ten hook entries. Nine of
them invoke the *same* dispatcher —
`${CLAUDE_PLUGIN_ROOT}/scripts/swarm.sh` (via `${CLAUDE_PLUGIN_ROOT}` so the
install location doesn't matter). `swarm.sh` sources `bus.sh`, `ledger.sh`, and
`guard.sh` as **libraries** and runs their phases in-process, so a hook event
costs one shell rather than one shell per subsystem. The tenth entry —
`skill-activation.sh` on `UserPromptSubmit` — is a separate, stateless script
(merged in from skillkit at 4.0.0), invoked directly rather than through
`swarm.sh`:

| Event                | Matcher                            | Script / `swarm.sh` subcommand | Phases run, in order                                                     |
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

The **Codex adapter** registers `SessionStart`, `UserPromptSubmit`,
`PreToolUse`, `PostToolUse`, `SubagentStart`, `SubagentStop`, and `SessionEnd`.
Its thin adapter converts Codex `apply_patch` calls into one shared-core edit
event per target path, observes explicit files in conservative read-only Bash
commands for guard fingerprints, converts native subagent fields, and emits one
Codex-valid context object even when the shared dispatcher produced several
Claude-compatible NDJSON messages.

`PostToolUse` is split by matcher rather than one combined
`Write|Edit|NotebookEdit|Read|Bash|Task` entry, because each tool group needs a
different phase (Bash needs guard's `absorb`, Task needs `subagent-stop`, the
rest need `record`).

Guard runs *before* the bus on `pretool-write`, and a deny **short-circuits** —
`swarm.sh` exits without running the bus check at all, since a soft "someone else
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

If a repo still has a legacy pre-4.0.0 bus directory sitting next to (or
instead of) `.coordkit-bus/`, remove it before or after running `cobus gc`.
`cobus gc` now only manages `.coordkit-bus/` itself.

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

## Presence across machines (who is alive, live tail)

Once a repo shares its ledger over git or the relay, three verbs give you a live
cross-machine picture — no new daemon or dependency, just heartbeat events on the
same durable log (details, precedence rules and design notes in
[docs/PRESENCE.md](docs/PRESENCE.md)):

```bash
cobus heartbeat --loop 30 --cap gpu       # on each machine, in a spare pane / systemd unit
cobus peers                               # who is alive (age vs ttl), task, branch, caps, repo
cobus watch --since 10m --exclude heartbeat   # follow the shared event stream live (Ctrl-C to stop)
```

Machine name comes from `COORDKIT_MACHINE`, then `coord.toml` `[machine] name`,
then `hostname -s`; capabilities from `[machine] caps`, `COORDKIT_CAPS`, and
`--cap k=v`. Heartbeats never appear in the hook-injected digest, and
`cobus fleet` gains one trailing `machines` line when any exist.
