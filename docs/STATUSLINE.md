# The statusline badge, and why it can't be auto-wired

`bus.sh badge` is the one coordkit surface the plugin manifest cannot install
for you. Everything else — hooks, slash commands, agents, skills — is declared
in `.claude-plugin/plugin.json` and arrives with the plugin. The badge does not,
and never will. This doc explains the seam, the failure mode it creates, what
coordkit now ships to mitigate it, and what stays manual permanently.

## 1. What the badge prints

`bus.sh badge` (see `plugins/coordkit/scripts/bus.sh`, the `badge` phase) does
two things per statusline refresh:

1. **A throttled heartbeat tick.** If this session's own heartbeat is older than
   `TICK_MIN = 10s`, it upserts `agents/<sid>.json` before counting. The badge
   is therefore not purely a reader — a session with the badge wired keeps its
   liveness fresh even while idle at the prompt.
2. **A liveness count**, derived from every `agents/*.json` heartbeat. Sessions
   are deduplicated by their 8-char sid and each is classified by its *freshest*
   heartbeat, so a duplicate or stub registration can't inflate the number.
   Heartbeats older than `STALE_HARD` (6h) are ignored entirely.

The three counters, and the exact output shape:

| Counter | Meaning | Rendered as |
| --- | --- | --- |
| `live` | sessions whose freshest heartbeat is within `STALE_SOFT` (15 min) — includes you | `🛰️ N live` when `N ≥ 2`, otherwise a bare `🛰️` |
| `idle` | sessions between `STALE_SOFT` and `STALE_HARD` | `· M idle` |
| `samebr` | *other* live sessions on your current branch | `· ⚠ K on this branch`, in red |

`samebr` deliberately excludes you, and doesn't count a branch of `""`,
`no-git`, or `detached` — those aren't a meaningful "same branch" collision.
The `⚠` segment is the one that matters operationally: it's the cheap, always-
visible signal that a sibling instance is about to fight you over the same
branch.

**The badge goes silent when you're alone.** If `live ≤ 1` and `idle == 0` it
prints nothing at all and exits 0, keeping a solo session's statusline clean.
That silence is a feature — and, as §3 explains, also exactly why the failure
mode below is invisible.

## 2. Why the plugin can't wire it

A Claude Code plugin manifest can register hooks (`SessionStart`,
`PreToolUse`, …) and slash commands. It cannot register a statusline.
`statusLine` is a **top-level key in the user's own `settings.json`** — a
machine-wide personal preference, scoped to the user, not to any installed
plugin. There is no manifest field for it, no append/merge mechanism, and no
plugin-install hook that may write it. This is a platform constraint, not a
coordkit backlog item: no future coordkit version will make it go away.

This is already flagged in the code, in `bus.sh`'s header comment (the
`badge` note, near the top of the file) — that comment and this doc are meant
to stay in sync.

The practical consequence: getting the badge on screen always requires a small
wrapper script that lives **outside** the plugin — conventionally
`~/.claude/hooks/coordkit-statusline.sh` — with `settings.json`'s
`statusLine.command` pointing at it. That wrapper is not in coordkit's git
repo, is not covered by coordkit version bumps, and cannot be touched by a
`git pull` or a marketplace update.

## 3. The failure mode: silent, indefinite degradation

Anything living outside the repo can drift out of sync with what's inside it,
and nothing detects the drift. A real occurrence:

1. A hand-written wrapper hardcoded an absolute path to the bus script.
2. Two unrelated coordkit-side renames landed over its lifetime: the
   marketplace directory `coordkit-marketplace` → `coordkit`, and the script
   itself `claude-bus.sh` → `bus.sh`.
3. The wrapper's baked-in path now pointed at nothing. `bash <missing>` wrote
   an error to stderr and printed **nothing** on stdout.
4. The statusline rendered no badge — and no error.

The reason this went unnoticed for a long time is structural, not careless:
**a statusline treats empty output as "nothing to report."** It has no way to
distinguish "the command ran and correctly decided you're working alone" (§1's
silent-when-alone behavior) from "the command doesn't exist." Both look like a
blank segment. Renaming anything on the coordkit side is a normal, correct
refactor; the wrapper is the thing that quietly rots, and its symptom is the
absence of a symptom.

## 4. What coordkit now ships

The supported path is:

```
/coordkit:statusline-setup install
```

It writes the wrapper to `~/.claude/hooks/coordkit-statusline.sh` and points
`settings.json` at it. Two design choices are worth stating explicitly, because
they're what make the §3 incident non-repeatable:

**The wrapper glob-discovers `bus.sh` at run time** rather than baking in a
path — it resolves
`~/.claude/plugins/marketplaces/*/plugins/coordkit/scripts/bus.sh` on every
invocation. A future rename of the marketplace directory, or of coordkit's own
layout above `scripts/`, therefore self-heals: the next statusline refresh
picks up the new location with no reinstall. And if the glob genuinely matches
nothing, the wrapper prints a visible `⚠️ coordkit bus.sh not found` instead of
staying silent — converting the invisible failure of §3 into a loud one.

**The wrapper chains rather than replaces.** `statusLine` is the user's key,
and a user may already have a custom statusline command in it. The installer
preserves that command and appends the badge to its output, so wiring coordkit
never costs you a statusline you already had.

Run `/coordkit:statusline-setup check` to verify the wiring without changing
anything. coordkit's `SessionStart` hook also does a passive drift check and
notes it if the wiring looks wrong.

## 5. What stays manual, permanently

The installer removes the *maintenance* burden, not the *bootstrap* one:

- A fresh Claude Code install, a new machine without your dotfiles, or a
  manually deleted `~/.claude/hooks/coordkit-statusline.sh` all leave you with
  no badge until you run `/coordkit:statusline-setup install` once.
- coordkit cannot detect "I was just installed for the first time" and self-wire,
  because the constraint in §2 applies to install-time hooks too. There is no
  point in the plugin lifecycle at which coordkit may write `statusLine`.

So: one manual command, once per machine. That is the floor, and it is not
going to drop.

## 6. If the badge silently stops showing

Work down this list — it's ordered by how often each turns out to be the cause:

1. **Confirm you're not simply alone.** Two-plus live sessions in the repo, or
   at least one idle one, are required for the badge to print anything (§1).
   `/bus` shows the same liveness set without the silence rule.
2. **Run `/coordkit:statusline-setup check`.** It reports whether
   `settings.json`'s `statusLine` points at the wrapper and whether the wrapper
   resolves a `bus.sh`.
3. **Look for `⚠️ coordkit bus.sh not found` in the statusline.** If it's there,
   the wrapper is installed and running but the glob matched nothing — the
   plugin is uninstalled, or installed somewhere the glob doesn't cover.
4. **Run the wrapper by hand:** `bash ~/.claude/hooks/coordkit-statusline.sh`.
   stderr is invisible in a statusline but not in a shell, so a broken path,
   a missing `jq`, or a permissions problem surfaces here immediately.
5. **Check for a hand-written wrapper with a hardcoded path** — the §3 shape.
   If your wrapper predates the installer, re-run
   `/coordkit:statusline-setup install` to replace it with the
   glob-discovering one.
6. **Confirm the heartbeats exist:** `ls <repo>/.coordkit-bus/agents/`. If it's
   empty or absent, the problem is upstream of the badge — the hooks aren't
   firing at all, and `/bus` will be equally blank.
