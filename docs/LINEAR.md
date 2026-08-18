# Linear ⇄ ledger bridge (`cobus linear`)

coordkit's ledger is the cross-machine source of truth for *what agents are
doing right now* (tasks, claims, blockers, notes — see [LEDGER.md](LEDGER.md)).
Linear is where humans track *what should be done*. The bridge keeps the two in
sync in both directions without either side having to know about the other:

- **pull** — matching Linear issues become ledger tasks (`linear-cod-123`), so
  an agent on **any** machine can `cobus next` / `cobus claim linear-cod-123`
  and pick an issue up from the shared board.
- **push** — each mapped task's ledger activity (who claimed it and from which
  machine/branch, progress notes, block reason, completion) is mirrored into
  **one persistent comment per issue** that coordkit owns and rewrites in place,
  plus a workflow-state transition and a `blocked` label. Humans watching Linear
  see live progress from whichever machine is working the ticket.
- **sync** — pull then push, optionally looping as a foreground daemon.

Implementation: `plugins/coordkit/scripts/core/scripts/linear.sh` — bash + jq +
curl against `https://api.linear.app/graphql`, no other runtime dependencies.

## Setup

1. **Create a personal API key** in Linear: *Settings → Security & access →
   Personal API keys → New key*. Copy it once.
2. **Export it in your shell** (a `~/.bashrc`/direnv/1Password-cli line is
   fine). It is only ever read from the environment:

   ```bash
   export LINEAR_API_KEY='lin_api_…'
   ```

   Never put it in `coord.toml`, `.env` files that get committed, or the bridge
   state file — `cobus linear status` deliberately reports only *present /
   missing* and the key's length.
3. **Configure the team** in `<repo>/.claude/coord/coord.toml`:

   ```toml
   [linear]
   team_key      = "COD"              # required — the issue prefix
   project       = "coordkit"         # optional: only issues in this project
   label         = "repo:coordkit"    # optional: only issues carrying this label
   states        = "Todo,In Progress" # default `pull` filter (--state overrides)
   claim_state   = "In Progress"      # ledger claim  → this state (only from Todo/unstarted)
   done_state    = "Done"             # ledger done   → this state
   blocked_label = "blocked"          # ledger block  → this label ("" = comment only)
   poll_s        = 60                 # `sync --loop` default interval
   ```

   Every key can also be overridden per invocation with
   `COORDKIT_LINEAR_<KEY>` (e.g. `COORDKIT_LINEAR_TEAM_KEY=COD`).
4. `cobus linear status` — confirms config + auth presence, then
   `cobus linear pull` to seed the board.

## Commands

| Command | What it does |
| --- | --- |
| `cobus linear pull [--state "A,B"] [--assignee me]` | Fetch issues of `team_key` (paged, 50 at a time) filtered by state names / project / label / `assignee.isMe`, and **upsert** each as ledger task `linear-<identifier>` (lower-cased). Body: `COD-123: <title> [<state> · P<prio> · @<assignee>] <url>`; `refs = [url]`; `tags = ["linear","state:…","priority:…","assignee:…"]`. Issues whose Linear state type is `completed`/`canceled` also get a ledger `done` if the task is not done yet. |
| `cobus linear push [COD-123 …\|--all]` | For each mapped issue: read the ledger, compose the comment, create/update it, transition state, add/remove the blocked label. No arguments = `--all` (every pulled issue, every `link`, every `linear-<team>-N` task on the board). |
| `cobus linear sync [--loop <secs>]` | `pull` then `push --all`. With `--loop` it repeats until Ctrl-C (SIGINT/SIGTERM finish the round, then exit 0). Failures inside a round are logged and retried next round. |
| `cobus linear link <task-subject> <COD-123>` | Map an arbitrary existing ledger task (e.g. one created with `cobus task`) onto an issue so `push` covers it. Also drops a ledger note so siblings see the link. |
| `cobus linear status` | Config, endpoint, auth presence, state file, last pull/push, and a mapping table (issue, ledger subject, Linear state, ledger status, comment yes/no, last push). |
| `--dry-run` (any command) | Print every GraphQL **mutation** it would send (query + variables) instead of sending it. Reads still happen; nothing is written locally. |

Exit codes: `0` ok · `2` usage / missing `LINEAR_API_KEY` / missing `team_key`
· `3` Linear rejected the key (401/403) · non-zero from `push` when at least
one issue failed.

## Idempotency — how re-runs stay quiet

- **pull** goes through the ledger's own `task-as` verb (an explicit-subject
  `task` upsert added for bridges). It compares the composed description with
  the projected task row and emits **nothing** when identical, so a `sync
  --loop` on three machines does not triple the log. Because the description
  embeds the Linear state / priority / assignee, a real change on Linear does
  produce exactly one new `task` event (last-write-wins in the projection;
  claim/done/block history is untouched).
- **push** hashes the composed comment body (minus the "last push at" footer)
  and skips the `commentUpdate` when nothing changed. State transitions are
  computed against the issue's *live* state and never demote (claim → In
  Progress only lifts an issue whose state type is `unstarted`; done → Done is
  skipped when the issue is already completed/canceled).
- The bridge's per-machine memory (issue ids, comment ids, cached workflow-state
  and label ids, last-push hashes) lives in
  `<repo>/.claude/coord/linear/state.json`. It is created with a `*` `.gitignore`
  and added to `.git/info/exclude`, the same treatment `.coordkit-bus/` and
  `.claude/coord/log/` get. A fresh machine with no state file still finds the
  existing comment by its marker line, so two machines never create two
  comments.

## The comment

One comment per issue, first line a stable marker, always regenerated whole:

```
<!-- coordkit:ledger:v1 subject=linear-cod-123 -->
## coordkit ledger · COD-123

- **Ledger status:** `in-progress`
- **Worker:** `site-1a2b3c4d` · user `anga` · session `9f3e2c1a` · host `claude-code` ← this machine: `devbox-01`
- **Branch:** `feature/cod-123`
- **Last ledger event:** `2026-08-18T14:02:11Z` · seq 42 · note
- **Ledger task:** `linear-cod-123` in repo `coordkit` (5 event(s))

### Timeline (last 5 ledger events)
- `2026-08-18T13:58:03Z` **task** · `site-1a2b3c4d` (main) — COD-123: … 
- `2026-08-18T13:59:40Z` **claim** · `site-1a2b3c4d` (feature/cod-123) — claimed by 9f3e2c1a (branch:feature/cod-123)
- `2026-08-18T14:02:11Z` **note** · `site-1a2b3c4d` (feature/cod-123) — COD-123: GraphQL client wired, tests next

---
_Maintained by **coordkit** (`cobus linear push`) — regenerated in place on every push, do not edit by hand. Separate from Symphony's `## Codex Workpad` comment. Last push from `devbox-01` (`site-1a2b3c4d`) at 2026-08-18 14:02:30 UTC._
```

- **Which machine:** ledger events carry the writer's stable `actor` (site id,
  see `ck_actor`), `user`, `sid8` and adapter `host`; the pushing machine adds
  its own hostname when it is the claim owner, and the footer always names the
  machine that pushed. Bus heartbeats (what `board` uses to call a claim
  "live") are local to a machine, so the bridge derives status from the events
  themselves: last of claim/done/block wins; a claim whose lease has lapsed is
  shown as `claim-expired` (reclaimable) rather than silently "open".
- **What counts as this task's activity:** every event whose subject is the
  task subject (task/claim/done/block/decision/question/answer) plus `note`s
  whose body mentions the issue identifier (`COD-123`, case-insensitive) or
  the subject — so `cobus note "COD-123: found the bug"` shows up.
- **Blocked** adds a `### ⛔ Blocked` section with the reason and, by default,
  the `blocked` label (found by name; created on the team if missing; removed
  again by the bridge once the task is claimed again or done). Set
  `blocked_label = ""` to keep it comment-only. Nothing else in Linear is
  touched for a block — no state change, no assignee change — which is the
  least surprising thing a watcher can see.
- **Done** adds a `### ✅ Done` section and moves the issue to `done_state`.

## Living alongside Symphony / WORKFLOW.md

`WORKFLOW.md` (live config for the Symphony orchestrator — do not edit it) has
its own single-persistent-comment convention: the `## Codex Workpad` comment
that a Symphony-driven agent owns per ticket. The bridge is designed not to
collide with it:

- Different comment, different marker: coordkit's comment starts with
  `<!-- coordkit:ledger:v1 subject=… -->` and is titled `## coordkit ledger`;
  Symphony's starts with `## Codex Workpad`. Each side finds and rewrites only
  its own; the test suite pins that a workpad comment on the same issue is left
  byte-identical.
- Same identifiers, same tracker: pull uses the `team_key` and issue
  identifiers WORKFLOW.md already uses (`COD-###`), and its default state filter
  (`Todo,In Progress`) matches Symphony's `active_states` minus `In Review`,
  which is Symphony's landing lane, not something a coordkit agent should claim.
  Add `label = "repo:coordkit"` to mirror `required_labels`.
- State transitions are conservative: `claim` only lifts `Todo → claim_state`
  (never touching Backlog, In Review, or Done — the states Symphony treats as
  out of scope or terminal), and `done → done_state` never overwrites a
  completed/canceled issue. If Symphony lands work through `In Review`, set
  `done_state = "In Review"` so a coordkit `done` hands off into Symphony's
  lane rather than jumping past it.
- Blockers stay blockers: WORKFLOW.md turns real blockers into follow-up
  issues; the bridge only *surfaces* a ledger block (label + comment section) so
  a human can do that triage.

## Failure behavior

- Missing `LINEAR_API_KEY` → one clear message pointing here, exit 2, nothing
  else happens (help/status still work).
- Network errors, HTTP 429 and 5xx → retried with exponential backoff
  (`COORDKIT_LINEAR_RETRIES`, default 4; `COORDKIT_LINEAR_BACKOFF_S`, default
  1 s base). Exhausted retries fail the current command but never a `sync
  --loop` — the loop logs and tries again next round.
- 401/403 → exit 3 immediately (retrying a bad key is pointless).
- GraphQL-level errors (unknown state name, missing permissions) are printed
  per issue and the round continues with the next issue.

## Testing

`tests/linear-bridge.sh` (wired into `make test`) drives every subcommand
offline: `COORDKIT_LINEAR_CURL` points the bridge at
`tests/fixtures/fake-linear-gql.sh`, a jq-backed stand-in for the GraphQL
endpoint that answers the bridge's queries from a JSON fixture and records
every request. It asserts idempotent pull, the exact comment body and mutation
sequence, all state/label transitions and their guards, `link`, marker
discovery on a fresh machine, `--dry-run`, retry/backoff, and SIGINT-safe
looping — without a network connection or a real key.
