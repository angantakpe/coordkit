# Claude Code adapter

This is the shipped adapter for coordkit.

It maps Claude Code's hook events and slash-command surface onto the shared
coordkit runtime in `../..`.

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
