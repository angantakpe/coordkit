# Gemini adapter

Scaffolded host adapter slot for a future Gemini integration.

The shared coordkit runtime already accepts `GEMINI_*` environment aliases and
neutral `COORDKIT_*` names. What remains is a Gemini-specific packaging format
and event wiring that maps its lifecycle to the shared coord phases.

Expected responsibilities:

- Provide a Gemini-native manifest or extension entrypoint.
- Map Gemini lifecycle events to `scripts/swarm.sh` phases.
- Pass through session, workspace, and tool metadata in the shared contract.
- Bind any command or UI surface Gemini exposes to the shared CLI helpers.

Until that host wiring exists, this directory is documentation and a contract
stub, not a runnable adapter.
