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

The adapter shipped in this repository today is the Claude Code one. That is
why the current plugin manifest lives under `.claude-plugin/`, the hook runtime
uses host-adapter environment variables, and some docs still reference
`.claude/` paths. Those are adapter details, not requirements of the
coordination model itself.

The runtime now accepts these adapter env families:

- `COORDKIT_*` for the neutral names
- `CLAUDE_*` for the current Claude Code adapter
- `CODEX_*` and `GEMINI_*` as parallel adapter aliases

Adapter slots are tracked under
[`plugins/coordkit/adapters/`](../plugins/coordkit/adapters/):

- `claude-code/` is shipped and wired to the current plugin manifest.
- `codex/` is scaffolded for a future Codex host integration.
- `gemini/` is scaffolded for a future Gemini host integration.

What is not generalized yet:

- A host-agnostic manifest format shared across all host runtimes.
- Host-native event wiring for Codex and Gemini.
- A non-Claude command surface for slash-command style interactions.
- `scripts/skill-activation.sh` (merged in from skillkit at coordkit 4.0.0):
  its rule-file discovery paths (`~/.claude/skills/skill-rules.json`,
  `$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json`) are still
  Claude-adapter-specific, unlike the rest of the coordination core.

Those are adapter/runtime responsibilities, not gaps in the shared coordination
core.
