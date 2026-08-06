# Architecture

CoordKit should be organized as a runtime first, adapters second repository.
The plugin and host-specific wrappers are thin delivery layers. The shared
runtime owns the actual coordination behavior.

## Target layout

```text
coordkit/
├── apps/
│   ├── relay/
│   └── cli/
│
├── packages/
│   ├── core/
│   │   ├── scripts/
│   │   ├── commands/
│   │   ├── schemas/
│   │   └── domain.json
│   │
│   ├── protocol/
│   ├── core/
│   │   ├── peers/
│   │   ├── sessions/
│   │   ├── claims/
│   │   ├── inbox/
│   │   ├── tasks/
│   │   └── collisions/
│   │
│   ├── ledger/
│   ├── bus/
│   ├── guard/
│   ├── memory-gate/
│   ├── worker-runtime/
│   │
│   ├── transport-local/
│   ├── transport-git/
│   └── transport-relay/
│
├── adapters/
│   ├── claude-code/
│   └── codex/
│
├── plugins/
│   └── coordkit/
│
├── docs/
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── contracts/
│   └── e2e/
│
├── examples/
│   ├── local-repository/
│   └── remote-relay/
│
└── var/
    └── runtime-state/
```

## Plain English

- `apps/` holds runnable entrypoints.
- `apps/relay/` is the network service for cross-machine event sharing.
- `apps/cli/` is the command-line entrypoint surface.
- `packages/core/` is the current home for the shared runtime scripts
  and shared package metadata.
- `packages/protocol/` defines events, commands, and schemas.
- `packages/core/` holds the shared coordination domain: sessions, peers,
  claims, inboxes, tasks, and collisions.
- `packages/ledger/`, `packages/bus/`, and `packages/guard/` implement the
  shared runtime behavior.
- `packages/memory-gate/` and `packages/worker-runtime/` are supporting runtime
  services.
- `packages/transport-local/`, `packages/transport-git/`, and
  `packages/transport-relay/` move events between storage backends.
- `adapters/` contains host integration shims for Claude Code and Codex.
- `plugins/coordkit/` is the packaging layer for the shipped plugin and thin
  wrappers around the shared runtime.
- `tests/` is split by intent so unit, integration, contract, and end-to-end
  coverage stay visible.
- `examples/` contains runnable reference setups.
- `var/` is for runtime state that should not be committed.

## Current shape

The current repository places the relay service under `apps/relay/` and the
canonical shared runtime under `packages/core/scripts/`.
`plugins/coordkit/scripts/` contains checked-in distribution copies because
host plugin installers copy only that plugin directory into their versioned
caches. Package tests require those copies to match the canonical runtime. This
is still not the full package split described above.

`packages/protocol/` now exists as the explicit home for the protocol contract
itself. It is still paired with the current shell-based schema and runtime, but
it marks the boundary the next refactor steps should converge on.

## Migration direction

The intended path is:

1. Move protocol and runtime behavior into `packages/`.
2. Move runnable entrypoints into `apps/`.
3. Keep `adapters/` and `plugins/` as thin host/package layers.
4. Leave the plugin depending on the runtime, not owning it.

The docs and README should describe the target shape even while the codebase
moves there in steps.
