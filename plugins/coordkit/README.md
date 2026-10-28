# CoordKit

CoordKit coordinates concurrent Claude Code and Codex sessions working in the
same repository. It tracks live sessions and file claims, warns about overlapping
edits, and keeps tasks, decisions and handoff notes in a shared append-only
ledger. Local coordination is the default; Git and an authenticated relay are
optional ways to share events across machines.

## Start using the plugin

After installing `coordkit@coordkit`, start a new host session. In Codex, open
`/hooks` and review the command hooks before approving them. Run `/bus` in Claude
Code or `$coordkit bus` in Codex to inspect the current sessions. Use `/ctx` or
`$coordkit` for the task board and shared context.

The default mode warns about collisions and allows edits. Guard mode is opt-in:
it can reject supported edits when a file changed since the session last read
it. It is not a lock for every possible shell command or editor.

The runtime needs Bash 4+, `jq`, Python 3.11+ and Git. The optional relay needs
Node 20+. Core implementation files live in `scripts/core/scripts/`; the shell
files in `scripts/` are distribution wrappers.

- [Installation and troubleshooting](https://github.com/angantakpe/coordkit#quick-start)
- [Architecture](https://github.com/angantakpe/coordkit/blob/main/docs/architecture.md)
- [Contributing](https://github.com/angantakpe/coordkit/blob/main/CONTRIBUTING.md)
- [Security reporting](https://github.com/angantakpe/coordkit/blob/main/SECURITY.md)

CoordKit is MIT-licensed. The host provides the coding agent and model access.
