# Adapters

coordkit is split into a shared coordination core plus host-specific adapter
slots.

The shared core lives in `scripts/`, `transports/`, `schema/`, and the shared
docs. Each adapter directory describes how a host maps its lifecycle events,
packaging format, environment variables, and command surface onto that core.

Adapter status in this repository:

- `claude-code/` - shipped adapter, backed by the Claude plugin
  manifest and hook wiring.
- `codex/` - shipped adapter, backed by `.codex-plugin/plugin.json`, Codex
  lifecycle hooks, and the bundled `$coordkit` skill.
- `gemini/` - scaffolded adapter slot for a Gemini host integration.

These adapter directories are intentionally small. They exist to keep host-
specific packaging separate from the shared runtime, and to make future host
integrations explicit instead of implicit.
