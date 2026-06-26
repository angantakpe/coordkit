# Changelog

All notable changes to **coordkit** are documented here. This project follows
[Semantic Versioning](https://semver.org/). The plugin `version` field in
`.claude-plugin/plugin.json` is the canonical tooling-version axis — bump it to
ship an update to installed users.

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
