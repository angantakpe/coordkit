# core

`core` is the explicit coordination engine package behind the plugin
surface. It is the place to look for the domain model and shared command
catalog, independent of any host adapter.

## Core domain

- Peer
- Session
- Heartbeat
- Claim
- Message
- Task
- Ledger event
- Collision
- Relay

## What lives here

- `domain.json` - machine-readable core domain map.
- `commands/catalog.json` - shared command-intent catalog.

Host-specific adapters and command wrappers stay under `plugins/coordkit/`.
Its `scripts/` directory now contains thin wrappers that defer into
`scripts/core/scripts/`, so installed plugins do not depend on files outside
their cache and the runtime stays single-sourced.
