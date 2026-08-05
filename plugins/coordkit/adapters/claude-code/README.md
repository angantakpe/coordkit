# Claude Code adapter

This is the shipped adapter for coordkit.

It maps Claude Code's hook events and slash-command wrappers onto the shared
coordkit runtime in `../..`. The actual command behavior lives in
`../../commands/README.md`; this adapter only provides the Claude-specific
packaging and front door.

Current packaging entrypoints:

- `../../.claude-plugin/plugin.json`
- `../../hooks/hooks.json`
- `../../commands/*.md`

Current runtime env aliases:

- `COORDKIT_*`
- `CLAUDE_*`
- `CODEX_*`
- `GEMINI_*`

The shared runtime accepts all four families, but this adapter is the one that
actually binds Claude Code's host-specific event model today.
