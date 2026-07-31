# Codex adapter

Scaffolded host adapter slot for a future Codex integration.

The shared coordkit runtime already accepts `CODEX_*` environment aliases and
neutral `COORDKIT_*` names. What remains is a Codex-specific packaging format
and event wiring that maps its lifecycle to the shared coord phases.

Expected responsibilities:

- Provide a Codex-native manifest or extension entrypoint.
- Map Codex lifecycle events to `scripts/coord.sh` phases.
- Pass through session, workspace, and tool metadata in the shared contract.
- Bind any command or UI surface Codex exposes to the shared CLI helpers.

Until that host wiring exists, this directory is documentation and a contract
stub, not a runnable adapter.
