# Host adapters

coordkit's coordination core is host-neutral. The shared pieces are the bus,
the ledger, the guard, the schema, and the transport logic. Those pieces do not
care whether they are being driven by Claude Code, another agent host, or some
future runtime.

An adapter is the host-specific packaging layer that:

- Maps the host's lifecycle events onto the shared `coord.sh` phases.
- Supplies the host-specific environment variables and plugin paths.
- Exposes any command or UI surface the host supports.
- Translates between the host's packaging format and coordkit's on-disk state.

Claude Code and Codex adapters are shipped. Both discover the default
`hooks/hooks.json` manifest and enter through `adapters/hook.sh`; that dispatcher
selects the host-specific payload translation before calling the shared shell
core. Claude uses `.claude-plugin/` packaging and Markdown slash commands.
Codex uses `.codex-plugin/plugin.json`, `adapters/codex/adapter.json`, the Codex
payload translator, and the bundled `$coordkit` skill. Both share the same
per-repository `.coordkit-bus` state.

The runtime now accepts these adapter env families:

- `COORDKIT_*` for the neutral names
- `CLAUDE_*` for Claude Code
- `CODEX_*` and `GEMINI_*` as parallel adapter aliases

Adapter slots are tracked under
[`plugins/coordkit/adapters/`](../plugins/coordkit/adapters/):

- `claude-code/` is shipped and wired to the Claude plugin manifest.
- `codex/` is shipped and wired to the Codex plugin manifest and hook schema.
- `gemini/` is scaffolded for a future Gemini host integration.

Adapters set `COORDKIT_HOST`, or the shared runtime infers Claude Code from its
plugin environment as a compatibility fallback. Heartbeats and newly emitted
ledger events persist that identity as `host`, and every user-facing sibling/
collision attribution displays it. Old records without the field remain valid
and render as `unknown`.

Automatic model context is governed centrally rather than independently by
each host. The `[context]` table and `COORDKIT_CONTEXT_*` overrides select
`quiet`, `compact`, or `debug` behavior and hard hook budgets; see
[Token-efficient context](../README.md#token-efficient-context). Host-facing
commands provide the detail omitted from those automatic projections: Codex
uses `$coordkit`, Claude Code uses `/ctx` and `/bus`, and either host can call
the `cobus` CLI from a terminal.

What is not generalized yet:

- A host-agnostic manifest format shared across all host runtimes.
- Host-native event wiring for Gemini.
- `scripts/skill-activation.sh` (merged in from skillkit at coordkit 4.0.0):
  its rule-file discovery paths (`~/.claude/skills/skill-rules.json`,
  `$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json`) are still
  Claude-adapter-specific, unlike the rest of the coordination core.

Claude-only specialized agent definitions and slash commands remain available
to Claude. Codex exposes the coordination operations through `$coordkit`, since
Codex plugins package skills rather than Claude-style command Markdown.
