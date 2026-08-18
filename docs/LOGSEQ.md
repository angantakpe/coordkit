# Logseq ⇄ ledger bridge

`plugins/coordkit/scripts/core/scripts/logseq.sh` (`cobus logseq ...`, `/logseq`
in Claude Code, `$coordkit logseq` in Codex) turns a
[Logseq](https://logseq.com) graph — plain markdown files, typically already
git- or iCloud-synced across your machines — into a human-readable, editable
window onto coordkit's shared ledger (`docs/LEDGER.md`) and bus
(`docs/BUS.md`). It is read-only against the graph except for the two managed
pages and one property line per imported block; it never touches anything
else you've written.

Two directions:

- **export** — project ledger/bus state INTO the graph: who's live, what's
  claimed, what's open, what happened.
- **import** — read Logseq `TODO`/`LATER`/`NOW`/`DOING` blocks tagged
  `#coordkit` back OUT as ledger tasks, so writing a task in Logseq on your
  phone or laptop queues real coordkit work.

Both directions go through the ledger's own verbs (`task`, `done`, `board
--json`, `events`) — there is no second task system, no separate state file
that could drift from the ledger's. The graph is a *view*, not a second
source of truth; conflicts always resolve toward the ledger.

## 1. Setup

Add a `[logseq]` table to this repo's `.claude/coord/coord.toml` (create the
file if it doesn't exist yet — see `templates/coord.toml` for the full
annotated template):

```toml
[logseq]
graph_dir = "/home/you/logseq/my-graph"   # must contain pages/ and journals/
namespace = "coordkit"                     # page prefix: coordkit/fleet, coordkit/tasks
tag = "coordkit"                           # import scans for #coordkit (no leading #)
journal_format = "yyyy_MM_dd"              # Logseq's default journal file naming
# linear_workspace = "acme"                # optional: renders linear:COD-123 refs as URLs
# api_url = "http://127.0.0.1:12315/api"    # optional: push updates to a running Logseq
```

Every key can be overridden per-machine with an env var
(`COORDKIT_LOGSEQ_GRAPH_DIR`, `COORDKIT_LOGSEQ_NAMESPACE`,
`COORDKIT_LOGSEQ_TAG`, `COORDKIT_LOGSEQ_JOURNAL_FORMAT`,
`COORDKIT_LOGSEQ_API_URL`, `COORDKIT_LOGSEQ_LINEAR_WORKSPACE`) without editing
the committed file — useful when your graph lives at a different path on each
machine. `graph_dir` supports a leading `~`.

`.claude/coord/logseq/state.json` holds the bridge's own bookkeeping (export
cursor, seen-event dedup set, last-known presence, which subjects were
imported from where) — it's per-machine, gitignored via the repo's git
`info/exclude` (added automatically), and safe to delete: the next `export`
just re-derives everything from the ledger and re-scans the graph.

## 2. `cobus logseq export [--journal] [--pages]`

With no flags, does both. Writes:

- **`pages/<namespace>___fleet.md`** (Logseq's `namespace/page` → `namespace___page.md`
  file naming) — one bullet per repo this machine has registered
  (`docs/BUS.md`'s cross-repo fleet registry) with its live/idle session
  count and branches, one nested bullet per live session (host, state, age,
  branch, current task), and a second section listing the most recent event
  per actor seen in the shared ledger (their site id, host, branch, and last
  action) — a rough "who's been doing what" even for actors with no current
  heartbeat.
- **`pages/<namespace>___tasks.md`** — one Logseq task block per ledger task
  subject, in queue order, marker mapped from the ledger's projected status:

  | ledger status   | Logseq marker |
  |------------------|---------------|
  | open             | `TODO`        |
  | `claimed:<sid8>` | `DOING`       |
  | blocked          | `WAITING`     |
  | done             | `DONE`        |

  Each block carries a `coordkit-task::` property holding the ledger
  subject — re-exports find the same block by this property and update it in
  place instead of duplicating it. Claimed tasks also get `coordkit-owner::`
  /`coordkit-host::`/`coordkit-branch::`; blocked tasks get
  `coordkit-blocked::` with the reason; a task description containing
  `linear:COD-123` gets `coordkit-ref::` and, if `linear_workspace` is set,
  a clickable `coordkit-url::`; an open task whose `dep:` isn't satisfied yet
  gets `coordkit-waiting-on:: deps`.
- **`journals/<today>.md`** — **appends** (never rewrites) one bullet per
  notable ledger event (`task`/`claim`/`done`/`block`/`note`/`decision`/
  `question`/`answer`) since the last export, plus a line for every session
  that appeared or disappeared, all nested under a single `- [[coordkit/log]]`
  parent bullet for the day (reused across exports on the same day). The
  export cursor in `state.json` makes this incremental: a re-export with no
  new activity prints "nothing new" and touches nothing on disk.

Both pages use a marker-comment convention —
`<!-- coordkit:begin tasks -->` / `<!-- coordkit:end tasks -->` (and `fleet`)
— and **only the lines strictly between those markers are ever rewritten**.
Anything you write above, below, or around them (notes, other bullets, a
different `updated::` property) survives every re-export untouched. A page
that doesn't exist yet is created with the markers already in place.

Every write is atomic (temp file + `mv`) and preserves the target file's
existing line-ending convention (LF or CRLF) and indentation exactly, so a
graph synced from a Windows machine round-trips cleanly.

## 3. `cobus logseq import [--dry-run]`

Scans every page and journal file in the graph (skipping the two managed
pages themselves) for `TODO`/`LATER`/`NOW`/`DOING` blocks that are tagged
`#<tag>` (a `#coordkit` hashtag or `#[[coordkit]]` link anywhere in the block
text) **or** live on the `<namespace>/inbox` page, and don't yet carry a
`coordkit-task::` property:

- Queues a new ledger task via the ledger's normal `task` verb (the block
  text, tag stripped, becomes the task description).
- Writes `coordkit-task:: <subject>` back as a new property line directly
  under that exact block — indentation, trailing CRLF, and everything else
  about the file is left alone. This is what makes import idempotent: the
  second `import` run sees the property and skips the block.
- If a block's marker is already `DONE`/`CANCELED`/`CANCELLED` *and* it
  carries a `coordkit-task::` property for an ledger task that isn't done
  yet, marks that ledger task done (`ledger done <subject>`) — so finishing
  a synced task in Logseq closes the real coordkit task, no export round-trip
  required.

`--dry-run` prints exactly what it would create/close without writing
anything to the graph or the ledger.

The inverse direction — a ledger task completed by an agent — is reflected in
Logseq on the **next `export`**: any block carrying a `coordkit-task::`
property whose ledger task is now done gets flipped to `DONE` in place.

## 4. `cobus logseq sync [--loop <secs>]`

`import` then `export`, once. With `--loop <secs>`, repeats on that interval
in the foreground (not a daemon — run it under `tmux`/`systemd --user` if you
want it to survive a terminal closing) until interrupted with Ctrl-C, which
prints "stopped" and exits cleanly.

If `api_url` (+ `LOGSEQ_API_TOKEN` in the environment) is configured and the
[Logseq local HTTP API](https://logseq.github.io/plugins/) is reachable, sync
additionally pushes the freshly rendered content of any task block Logseq
already knows about (found via its `coordkit-task` property, looked up with
`logseq.DB.datascriptQuery`) through `logseq.Editor.updateBlock`, so an
already-open Logseq window refreshes immediately instead of waiting on its
file watcher. This is **best-effort and silent on failure** — file mode
(export/import above) is the only path that's guaranteed to work, and is all
you need if you don't run Logseq's API server. New pages/blocks and the fleet
page are always left to Logseq's own file watcher either way.

## 5. `cobus logseq status`

Reports the configured graph path (and whether it exists), namespace/tag/
journal format, whether the two managed pages have been exported yet, the
export cursor and last export time from `state.json`, current ledger task
counts, how many tasks have been imported from Logseq, and whether the HTTP
API is configured/reachable. Always safe to run even with no `graph_dir`
configured — it just reports what's missing instead of erroring.

## 6. Cross-machine story

Nothing in this bridge talks over the network on its own. Cross-machine
propagation comes from two independent syncs composing:

- The **Logseq graph** syncs itself (git, iCloud, Syncthing, whatever you
  already use for it) — a `#coordkit` TODO you jot down on your phone shows
  up as a real file on your laptop once that sync runs, and the next
  `cobus logseq import` there turns it into a ledger task.
- The **coordkit ledger** syncs itself via its own transport (`local` on one
  machine, or `git`/`relay` mode per `docs/LEDGER.md` §5 across several) — a
  task claimed on one machine shows up in the projected board everywhere else
  that ledger is shared, and the next `export` on any of those machines
  reflects it into that machine's own copy of the graph.

The bridge only ever reads/writes against the ledger and bus running *on the
machine it's invoked on* — it does not itself reach across machines. If your
ledger is `local`-mode (the default), each machine's Logseq view reflects
only that machine's own coordkit state; switch to `git`/`relay` mode for a
Logseq page that reflects the whole fleet.

## 7. Caveats

- `graph_dir` must already exist and, on first export, `pages/`/`journals/`
  are created under it if missing — the bridge never creates the graph
  itself (open it in Logseq once first, or `logseq-cli` if you use that).
- Task descriptions become both the Logseq block text and the ledger
  `slug()`'d subject; very long or punctuation-heavy descriptions are
  truncated by the same 48-character slug rule the ledger already uses for
  every other task source (`/led task`, `cobus task`) — this isn't
  Logseq-specific.
- Import only recognizes the standard Logseq task markers
  (`TODO LATER NOW DOING DONE WAITING CANCELED CANCELLED IN-PROGRESS WAIT`)
  on a top-level bullet line (`- TODO ...`); markers embedded mid-sentence or
  on a non-bullet line are not task blocks and are ignored.
- The HTTP API push path talks to `logseq.DB.datascriptQuery` and
  `logseq.Editor.updateBlock`, which requires enabling Logseq's local HTTP
  API server (Settings → Features → Developer mode, then the HTTP APIs
  plugin) and generating a token for `LOGSEQ_API_TOKEN`. This is entirely
  optional; skipping it just means you see updates on the next file-watcher
  refresh (usually near-instant) instead of pushed live.

See also: `docs/LEDGER.md` (the shared-context layer this bridges),
`docs/BUS.md` (the fleet/presence data the fleet page renders),
`plugins/coordkit/commands/logseq.md` (the `/logseq` command spec),
`tests/logseq-bridge.sh` (the test suite this bridge ships with).
