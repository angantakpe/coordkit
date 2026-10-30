# Presence — who is alive on which machine, and a live tail

`docs/BUS.md` covers **one repo on one machine** (per-session heartbeats in
`.coordkit-bus/agents/`) and §9's fleet view covers **many repos on one
machine**. Presence is the third axis: **one repo across many machines**
(laptop, desktop, a cloud box) sharing a ledger over the git or relay
transport, so you can see in real time who is alive, what they are doing, and
follow the shared event stream live.

It is built entirely on the existing durable log — no new daemon, no new
dependency (bash 4 + jq, plus `curl` only in relay mode, exactly as today).

```
cobus heartbeat [--task <id>] [--cap <k[=v]>]... [--ttl <s>] [--loop <s>] [--json]
cobus peers     [--json] [--all] [--summary]
cobus watch     [--since <10m|2h|all|<watermark>|<actor-cursors-json>>]
                [--filter <type,...>] [--exclude <type,...>] [--json|--pretty]
                [--interval <s>] [--once]
```

Source: `plugins/coordkit/scripts/core/scripts/presence.sh` (dist wrapper
`plugins/coordkit/scripts/presence.sh`); routed by `bin/cobus`.

## 1. The heartbeat event

`cobus heartbeat` appends ONE `heartbeat` event through `logstore_append`, so
it travels exactly like a note or a claim: local segment in `local` mode,
committed + synced segment in `git` mode, backing + relay POST in `relay`
mode. It is a normal v2 envelope
(`plugins/coordkit/protocol/event.schema.json`) with these specifics:

| field | value |
| --- | --- |
| `type` | `"heartbeat"` |
| `subject` | `"<machine>/<actor>"` |
| `machine` | machine name — see resolution below |
| `actor` | `ck_actor()`, the stable site id (unchanged) |
| `host` | adapter identity `claude-code\|codex\|cli` — **unchanged**, NOT the machine name |
| `caps` | object `k -> string \| true` (capabilities) |
| `task` | current task/claim subject, or `null` |
| `ttl_s` | liveness window in seconds (default 90) |
| `ts` | epoch seconds (already in the envelope) |
| `presence` | superset record: `{machine, pid, session, cwd, repo:{root,name,remote}, branch, task, caps, ttl_s}` |
| `lease` | `null`; `tags: ["presence"]` |
| `seq` | **absent** (see §1.2) |

The top-level `machine / actor / caps / task / ttl_s / ts` are the contract
other tooling reads (e.g. `cobus dispatch`, `cobus peers`); `presence.*` is
the full record for humans and debugging.

### 1.1 Machine name, capabilities, TTL

`host` already means "which adapter produced this event" everywhere in
coordkit (`ck_host()`, the schema enum, the digest's `who@host`), so presence
introduces a separate **`machine`** field. Resolution:

- machine: env `COORDKIT_MACHINE` > `coord.toml` `[machine] name` >
  `hostname -s` > `$HOSTNAME`.
- caps (merged, later wins): `coord.toml` `[machine] caps` < env
  `COORDKIT_CAPS="k=v,k2=v2"` < `--cap k[=v]` flags. A bare key means `true`.
  `[machine] caps` accepts a `"k=v,k2"` string, a `["gpu","docker"]` array,
  or a `[machine.caps]` table (`region = "ca-east"`).
- ttl: `--ttl` > env `COORDKIT_HEARTBEAT_TTL` > `[machine] ttl_s` > 90.
- task: `--task` > env `COORDKIT_TASK` > this session's bus record
  (`.coordkit-bus/agents/<sid>.json` `.task`) > the latest unexpired `claim`
  by this actor in the shared log (skip that scan with
  `COORDKIT_PRESENCE_DETECT_TASK=0`).

```toml
# .claude/coord/coord.toml
[machine]
name  = "cloudbox"
caps  = "docker,os=linux"
ttl_s = 120

[machine.caps]
gpu = "a100"
```

### 1.2 Design: out-of-band, never deduped

- **No `seq`.** Every `ledger.sh` projection — the hook-injected digest, the
  board, session cursors — keys off a NUMERIC `.seq`. Heartbeats deliberately
  omit it, so a 30s heartbeat from every machine can never flood the
  shared-context digest, and heartbeats never contend for the seq-allocation
  lock. `cobus watch` shows them; `cobus digest` / `/ctx` never do.
- **`ts` is part of the identity hash.** Every other event's `eid` excludes
  volatile fields so a re-emission dedups. A heartbeat is the opposite: each
  tick is a fresh liveness signal, two identical heartbeats 30s apart must
  both survive, so `eid` covers `{…logical fields…, ts}`. Consequence: the
  shared log grows by one line per tick per machine (~2,900/day at 30s). Use
  the widest `--loop` your ttl allows (default recommendation `--loop 30`
  with the 90s ttl; `--loop 60 --ttl 180` for always-on boxes) and see
  `cobus gc` for the local bus. The relay room file and git log branch grow
  the same way; this is the price of presence over an append-only log.
- **`host` unchanged.** Repurposing `host` for the machine name would break
  the schema enum and every `who@host` line in the digest.

### 1.3 `--loop`: running it continuously

`cobus heartbeat --loop 30` re-emits every 30s in the foreground and, in
relay mode, drains the relay outbox each tick (so an offline stretch is
flushed as soon as the server is back). It exits 0 on SIGINT/SIGTERM.

Nothing in `hooks/hooks.json` emits heartbeats: the hook path is hot
(SessionStart/UserPromptSubmit/tool-use) and already too expensive to add a
network-touching append per call, and a Claude session's per-repo liveness is
already tracked by the bus. Run the loop under whatever supervises your
machine instead:

```bash
# tmux / a spare pane
cobus heartbeat --loop 30 --cap gpu

# background job in a shell (not inside a hook)
( cd ~/repo && cobus heartbeat --loop 30 ) &

# systemd --user unit
[Service]
WorkingDirectory=%h/repo
ExecStart=/path/to/plugins/coordkit/bin/cobus heartbeat --loop 30 --cap docker
Restart=always
```

## 2. `cobus peers` — projection

`peers` reads the union (`logstore_readall`, so it works in every mode; in
relay mode that pulls replayable events first) and reduces heartbeats to the
latest one per **(machine, actor, session)**: state (`alive` if `age <=
ttl_s`, else `stale`), age, task, branch, caps, repo. Rows older than 24h are
hidden unless `--all`. `--json` prints the raw rows (`machine, actor, sid,
sid8, host, user, ts, age_s, ttl_s, state, task, branch, caps, repo,
repo_root, cwd, pid, last_seen`). `--summary` prints the one-line form that
`cobus fleet` / `/fleet` now appends after its per-repo listing (only when at
least one heartbeat exists — the fleet output is unchanged otherwise).

Rows are per session rather than strictly per (machine, actor) because
several Claude sessions on one machine share an actor but not a task; a
plain-shell `cobus heartbeat` has session `cli`, so one-shot shell heartbeats
still collapse to one row per machine.

## 3. `cobus watch` — live tail across machines

`watch` follows the shared event stream and prints one line per event:

```
16:23:34  laptop/site-10265dd3@cli  heartbeat/laptop/site-10265dd3  branch:main task:COD-844 ttl:90s
16:23:37  desktop/site-9a1f00c2@claude-code  claim/fix-login  claimed by 3fa9c1d2 (branch:cod-812)
```

Colored by type when stdout is a TTY (`--color` / `--no-color` to force);
`--json` prints the raw event lines. `--filter note,claim` keeps only those
types, `--exclude heartbeat` drops one. `--since` backfills before following:
a duration (`10m`, `2h`, `1d`), `all`, a `p:c:actor` watermark
(`logstore_watermark`), or an actor-cursors JSON object
(`logstore_actor_cursors`). Default backfill is nothing (start from now).
`--once` prints the backfill and exits (handy for scripts/tests).

Following is lossless: each tick re-reads the union and emits every event
whose per-actor `clock.c` is beyond what was already shown
(`__filter_since_actor_cursors`), so a late-arriving event from a peer whose
wall clock is behind is still printed. Per transport:

- **relay** — long-polls the server (`GET /v1/events?since=<cursor>&wait=<ms>`,
  `COORDKIT_WATCH_LONGPOLL_MS`, default 20000, server cap 25000) via
  `__relay_wait_for_events`, which holds **no** lock and folds nothing, so a
  sibling `cobus board` can still pull; when the server reports something
  newer the normal sync folds it. Also settable on any pull via
  `COORDKIT_RELAY_WAIT_MS`. A dead relay degrades to a poll every `--interval`.
- **git** — runs `__git_sync` every `--interval` (default 10s), then re-reads.
- **local** — re-reads the segments every `--interval` (default 1s).

Exits 0 on SIGINT/SIGTERM. Note that `cbus` / `bus.sh watch` is a different
thing: the per-repo bus dashboard loop, not the event stream.

## 4. Testing

`tests/presence.sh` (wired into `make test`): heartbeat emit → `peers` alive
with task/caps; ttl elapsed → stale; machine-name precedence; heartbeats
absent from `cobus digest`/`board` in both direct and logstore modes; `watch
--once` backfill + `--filter`; a live local-mode `watch` prints an event
another actor appended and exits 0 on SIGTERM; `fleet` appends the machines
line; and — when `node` + `curl` exist — a relay case where machine B's
`watch` is woken by machine A's heartbeat through the server long-poll and
`peers` on B sees A alive.
