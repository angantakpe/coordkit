# coordkit-marketplace

A Claude Code plugin marketplace that packages a working **same-machine,
multi-instance coordination system** so it becomes installable, shareable, and
semver-versioned instead of a hand-wired set of `~/.claude/hooks/*.sh` scripts.

It ships **two plugins**, deliberately kept separate:

| Plugin | Version | Contract | What it does |
| --- | --- | --- | --- |
| **coordkit** | 2.0.0 | **WARN-only — never blocks** | A per-repo bus + cross-instance ledger. Tracks who else is live in a repo and which files they touch, and surfaces it so parallel Claude instances (and you) can reconcile instead of stepping on each other. |
| **coordguard** | 1.0.0 | **HARD blocker** | An anti-clobber guard. On `Write`/`Edit` it *denies* the tool call when the target file changed on disk since this session last read it — the signature of another instance having edited it. |

## Why two plugins (the split rationale)

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
   coordkit `version` (currently `2.0.0`) is the tooling-version axis.
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
| `PostToolUse` | `Read\|Write\|Edit` | `concurrency-guard.sh record` |

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
