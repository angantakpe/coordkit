# coordkit-marketplace

A Claude Code plugin marketplace that packages a working **same-machine,
multi-instance coordination system** so it becomes installable, shareable, and
semver-versioned instead of a hand-wired set of `~/.claude/hooks/*.sh` scripts.

## Scope note

`skillkit` is bundled in this marketplace for convenience, but it is
functionally unrelated to what the repo is named for: coordkit and coordguard
are two halves of one coordination story, while skillkit is skill
auto-activation and shares no concepts, state, or hooks with them. Splitting it
into its own marketplace — or renaming this repo to something scope-neutral —
is worth doing as more unrelated plugins land here. **Flagged, not yet acted
on.**

It ships **three plugins**, deliberately kept separate:

| Plugin | Version | Contract | What it does |
| --- | --- | --- | --- |
| **coordkit** | 2.2.0 | **WARN-only — never blocks** | A per-repo bus + cross-instance ledger. Tracks who else is live in a repo and which files they touch, and surfaces it so parallel Claude instances (and you) can reconcile instead of stepping on each other. |
| **coordguard** | 1.2.0 | **HARD blocker** | An anti-clobber guard. On `Write`/`Edit` it *denies* the tool call when the target file changed on disk since this session last read it — the signature of another instance having edited it. |
| **skillkit** | 1.0.1 | **Suggest-only — never blocks** | Skill auto-activation. On every prompt it matches layered `skill-rules.json` trigger rules (global `~/.claude/skills` + per-project) and injects "use this skill" reminders into context. Also ships 10 specialized agents, the `/dev-docs` context-persistence commands, and the skill-developer meta-skill. |

## Why coordkit and coordguard are split

*(This section is about those two only — skillkit is a separate concern; see the
scope note above.)*

coordkit's entire value is that it is **safe to always run**: it observes and
reports, it never wedges a tool call. The moment a coordination layer can *block*
edits, it stops being "always on, zero-risk." So the blocking behavior is carved
out into **coordguard**, which you opt into only when you want a hard stop. Keep
coordkit installed everywhere; add coordguard where you want the guardrail. This
boundary is a contract, not a preference — please don't move blocking logic into
coordkit.

## The three layers

This package is organized as three independent layers so each can evolve on its
own axis:

1. **Distribution / packaging** *(this README, the marketplace, plugin manifests,
   hook wiring)* — how the system is installed, versioned, and updated. The
   coordkit `version` (currently `2.2.0`) is the tooling-version axis.
2. **Schema** *(`plugins/coordkit/schema/`)* — the versioned event envelope
   plus its JSON Schema, manifest, and migrations. The envelope version is
   configurable and the ledger accepts either version on read; this is the
   on-disk format axis, versioned independently of the tooling.
3. **Transport** *(`plugins/coordkit/transports/`)* — how events move: `local`
   (the per-repo `.claude-bus/` directory), and optional `git` / `relay`
   backends behind a common `lib.sh`. This is the delivery axis.

## Install

Add the marketplace, then install the plugin(s):

```bash
# From a hosted git remote (GitHub/GitLab/git URL):
/plugin marketplace add <owner>/coordkit-marketplace
# ...or from a local clone:
/plugin marketplace add ./coordkit-marketplace

# Always-on, zero-risk coordination:
/plugin install coordkit@coordkit-marketplace

# Optional hard anti-clobber guard:
/plugin install coordguard@coordkit-marketplace

# Skill auto-activation + agents + dev-docs:
/plugin install skillkit@coordkit-marketplace
```

> **Distribution reality check.** As currently configured this repo's only
> remote is **private** (`git@github.com:angantakpe/coordkit-marketplace.git`),
> so the hosted `/plugin marketplace add <owner>/coordkit-marketplace` form
> works **only for the repo owner and anyone explicitly granted access** — for
> everyone else it fails at clone time. Genuinely shareable distribution needs
> either making the repo public or documenting an access-request path; neither
> has been done. Until then, the local-clone form
> (`/plugin marketplace add ./coordkit-marketplace`) is the path that works for
> anyone who has the files.

After installing skillkit, seed your global rules file (see
`plugins/skillkit/README.md` for the schema):

```bash
cp <plugin-root>/templates/skill-rules.example.json ~/.claude/skills/skill-rules.json
```

### Scopes

- **User scope** (default) — installs for your account across every project. Best
  for coordkit, since you want awareness everywhere you run Claude.
- **Project scope** — check the plugin into a repository so every collaborator who
  clones it gets the same coordination behavior. Project-scope plugins load only
  after the repository trust gate, and components that run code (hooks) are
  restricted further; personal/user scope has no such restriction.

Updates ship by bumping the plugin `version`; users pull them with
`/plugin marketplace update` followed by `/plugin update`.

## What gets wired

**coordkit** registers five lifecycle hooks (all invoked via
`${CLAUDE_PLUGIN_ROOT}` so the install location doesn't matter):

| Event | Matcher | Invocation |
| --- | --- | --- |
| `SessionStart` | — | `claude-bus.sh start`, `claude-ledger.sh start` |
| `UserPromptSubmit` | — | `claude-bus.sh task`, `claude-ledger.sh prompt` |
| `PreToolUse` | `Write\|Edit` | `claude-bus.sh check` |
| `PostToolUse` | `Write\|Edit\|Read\|Bash` | `claude-bus.sh record` |
| `SessionEnd` | — | `claude-bus.sh stop` (end-of-session cleanup) |

**coordguard** registers the blocker (and the companion record phase it needs to
avoid blocking on files this session legitimately read):

| Event | Matcher | Invocation |
| --- | --- | --- |
| `PreToolUse` | `Write\|Edit` | `concurrency-guard.sh check` (can return a `deny`) |
| `PreToolUse` | `Bash` | `concurrency-guard.sh snapshot` (fingerprint tracked files) |
| `PostToolUse` | `Read\|Write\|Edit` | `concurrency-guard.sh record` |
| `PostToolUse` | `Bash` | `concurrency-guard.sh absorb` (re-stamp self-inflicted changes) |
| `SessionEnd` | — | `concurrency-guard.sh cleanup` (end-of-session cleanup) |

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
  `claude-ledger.sh` injects the shared-context digest on `SessionStart` directly.

## Maintenance — garbage-collecting a bus

`.claude-bus/` state is pruned opportunistically (dead heartbeats and their
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
