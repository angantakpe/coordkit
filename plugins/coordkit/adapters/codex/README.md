# Codex adapter

This is the shipped Codex adapter for CoordKit.

Packaging and runtime entrypoints:

- `../../.codex-plugin/plugin.json` — Codex plugin manifest.
- `adapter.json` — machine-readable adapter pointer.
- `../../hooks/hooks.json` — default cross-host lifecycle configuration.
- `../hook.sh` — cross-host dispatcher.
- `hook.sh` — Codex payload translation into `scripts/coord.sh`.
- `../../skills/coordkit/` — the Codex command/workflow surface.

Codex represents edits as `apply_patch` calls containing one patch string. The
adapter extracts every Add/Update/Delete/Move path and invokes the shared guard
and bus once per target. Because Codex normally reads files through Bash rather
than a generic `Read` tool, successful conservative read-only commands are also
observed so guard mode can retain a meaningful last-seen fingerprint.

Native `SubagentStart` and `SubagentStop` events map to CoordKit's running-
subagent records. Every heartbeat sets `host:codex`, which is displayed in
session, collision, guard-attribution, and subagent messages.

Codex requires users to review and trust installed command hooks through
`/hooks`. A changed hook definition is skipped until its new hash is trusted.

Automatic context uses the shared `[context]` profile. `compact` is the bounded,
deduplicated default, `quiet` limits automatic context to critical coordination,
and `debug` retains configured caps while disabling repeat suppression. Use
`$coordkit` for live, on-demand state instead of raising hook budgets for every
turn. The optional relay moves events between trusted machines but does not
consume model tokens until a received event is selected for model context.
