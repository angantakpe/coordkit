# CoordKit Protocol

CoordKit is moving from a shell-shaped contract to an explicit protocol.
This document names the protocol concepts that the runtime, adapters, and
transports already imply, so the implementation can be split without changing
the meaning of the system.

## Scope

The protocol defines:

- the entities CoordKit coordinates;
- how those entities relate to each other;
- what must stay invariant across adapters and transports;
- which parts are storage and delivery concerns rather than protocol meaning.

The protocol does **not** define:

- host-specific wrappers;
- shell command layout;
- user-facing phrasing;
- packaging location;
- implementation details of a specific transport backend.

## Layers

```text
host adapter
  -> runtime
  -> protocol objects
  -> transport
  -> storage / replay
```

- Host adapters translate Claude Code, Codex, or CLI lifecycle events
  into protocol objects.
- The runtime interprets protocol objects and decides what to emit, claim, warn
  about, or inject.
- Transports move protocol data between storage locations and machines.
- Storage preserves the append-only history and the current projections.

## Core entities

### Session

A session is one live host conversation on one machine.

- Identified by a host session id (`sid`) and a short display id (`sid8`).
- Bound to a working directory (`cwd`), host type, branch, and actor.
- Produces events, claims, messages, and context requests.

### Agent

An agent is the active coordination participant inside a session.

- `plugins/coordkit/protocol/agent.schema.json` is the canonical agent definition.
- The host may surface it as a Claude thread, Codex subagent, or another
  runtime-specific persona.
- The protocol only cares that the actor is stable enough to attribute events,
  claims, and collisions.
- Agent identity is protocol metadata, not a shell path.

### Actor

An actor is the stable identity used to partition coordination state.

- It is used for append/write attribution and per-actor ordering.
- It must be stable for the site that is doing the writes.
- It is not the same thing as the human user name or the host brand.

### Event

An event is the append-only record line in the coordination log.

- `plugins/coordkit/protocol/event.schema.json` is the canonical envelope for events.
- Events are append-only.
- Stored events are never rewritten in place.
- The event id (`eid`) is the deduplication and audit anchor.
- The display id (`id`) is sortable and advisory.

Event projections derive the visible coordination state:

- active sessions and peers;
- file claims and collision warnings;
- task queue state;
- decisions and questions;
- inbox context summaries.

### Claim

A claim is a lease over a task or file scope.

- A claim is not a distributed lock.
- A claim can expire.
- A claim can be superseded by a newer event projection.
- The hard safety rule is about preventing clobber, not about guaranteeing
  exclusive ownership forever.

### Task

A task is claimable work in the shared board.

- Tasks may depend on other tasks.
- Claims lease tasks.
- `done` closes tasks.
- `block` marks work as blocked.
- `next` selects the next claimable task according to the projected board.

### Message

A message is a direct delivery object for one live session or a set of live
sessions.

- `plugins/coordkit/protocol/message.schema.json` is the canonical message envelope.
- Current implementation: messages are delivered through the bus inbox and
  injected into the next turn's context.
- Messages are not the same thing as ledger events.
- A message may summarize or accompany an event, but it does not replace the
  append-only ledger history.

### Transport

A transport is how CoordKit moves the same coordination history between
storage locations.

Current transport families:

- `local`
- `git`
- `relay`

Transport changes:

- how data is persisted;
- how far it replicates;
- how quickly peers observe it.

Transport does **not** change:

- the event meaning;
- the projection rules;
- the claim semantics;
- the append-only history contract.

## Invariants

These are the protocol rules that must hold across adapters and transports.

1. Append-only history.
   - New information is added as new events.
   - Existing stored events are not rewritten in place.

2. Stable event identity.
   - `eid` must remain the deduplication key.
   - Replay and union reads must tolerate duplicate delivery.

3. Latest-wins projection by subject.
   - The visible state for a subject is the latest non-superseded event for that
     subject.

4. Claims are leases, not locks.
   - A claim can time out.
   - A claim can be reclaimed when the owner is no longer live.

5. Transport must not change meaning.
   - Local, git, and relay backends can differ in durability and replication.
   - They must not change the projection result for the same event set.

6. Host-specific behavior stays at the edge.
   - Claude, Codex, and CLI integrations are adapters.
   - The protocol stays host-neutral.

7. Fail open on coordination safety.
   - If the guard or transport layer cannot prove a denial condition, the
     runtime should preserve the tool call rather than wedging the session.

## Protocol fields

The current event envelope already carries the main protocol metadata:

- `schema_version`
- `eid`
- `id`
- `actor`
- `clock`
- `sid`
- `sid8`
- `host`
- `user`
- `branch`
- `type`
- `subject`
- `body`
- `refs`
- `tags`
- `lease`
- `supersedes`
- `sig`

The important boundary is not the exact field list. The important boundary is
that the runtime interprets these fields as protocol data rather than as shell
conventions.

## How transports fit

The transport layer answers only these questions:

- Where does the append-only history live?
- How do new events replicate?
- How do readers rebuild the same projection from the union of events?

That means:

- local transport stores coordination data on the same machine;
- git transport shares the history through a git remote;
- relay transport adds authenticated near-real-time delivery and replay.

The transport layer must not redefine:

- what a session is;
- what a claim is;
- what a task is;
- what an event means;
- what a message is.

## Current gaps

These are the protocol gaps still visible in the repo today.

- The protocol still has a shell-shaped implementation underneath the new
  package boundary, not a fully typed runtime.
- `coord.toml` still combines transport configuration and enforcement policy in
  one file.
- `message` is now a first-class protocol object in `plugins/coordkit/protocol/`, but
  inbox files are still the delivery medium and the runtime still projects
  them through shell code.
- `agent` is now first-class in `plugins/coordkit/protocol/`, but the runtime still
  discovers agents from Markdown frontmatter rather than typed schema objects.
- The protocol schemas now live in `plugins/coordkit/protocol/`, but the runtime still
  projects and consumes them through shell code rather than a typed runtime.
- The shared runtime now knows how to resolve protocol schema paths through
  `ck_protocol_root()` and `ck_protocol_schema_path()`, but it still treats the
  schemas as descriptive artifacts rather than typed runtime inputs.
- The canonical runtime lives in packages, but host installers still require a
  synchronized self-contained copy under the plugin distribution directory.

## Intended next split

The next package boundary should turn this document into code:

- `plugins/coordkit/protocol/` for shared types and schemas;
- `plugins/coordkit/protocol/agent.schema.json`, `session.schema.json`, `claim.schema.json`,
  `task.schema.json`, `message.schema.json`, `event.schema.json`,
  `dispatch.schema.json` (cross-machine dispatch payload, see `docs/DISPATCH.md`), and
  `transport.schema.json`
  for the protocol envelopes and projections that move across the bus and
  ledger;
- `plugins/coordkit/scripts/core/` for session, claim, task, and message logic;
- `packages/bus/` for live-session coordination and collision visibility;
- `packages/ledger/` for append-only history and projections;
- `packages/transport-*` for storage and replication backends;
- `plugins/coordkit/` as the host packaging layer, including generated runtime
  and protocol distribution copies where installers require self-containment.
