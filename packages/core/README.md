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

The plugin wrappers under `plugins/coordkit/` stay host-specific. This package is
where the coordination engine becomes visible as a first-class unit.
