---
description: Turn the hard anti-clobber guard on or off for this repo, or show which enforcement mode is in effect and where it came from
argument-hint: on | off | status
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh on:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh off:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh status:*)
---

Set or report coordkit's **enforcement mode** for this repo.

My argument (`on`, `off`, or `status` — treat anything else, including empty, as `status`):

$ARGUMENTS

Run exactly one of these by calling the Bash tool. The subcommand is a fixed
token and takes no free text, so no quoting is needed:

`${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh status`
`${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh on`
`${CLAUDE_PLUGIN_ROOT}/scripts/guard.sh off`

What the two modes mean:

- **`warn`** — coordkit's default and its standing contract: the bus and ledger
  observe who else is live, what they're touching, and warn softly on a
  collision, but **never block a tool call**.
- **`guard`** — everything `warn` does, plus a hard anti-clobber check: a
  Write/Edit to a file that changed on disk since this session last Read it (or
  that this session has never Read) is **denied** until you re-Read and
  reconcile it. This is the former `coordguard` plugin, now built in.

`on` and `off` write `mode = "guard"` / `"warn"` into this repo's
`.claude/coord/coord.toml` under an `[enforcement]` table, creating the file or
the table if needed and leaving any existing git-mode transport settings
untouched. Because the file is committed, the setting is per-repo and shared
with anyone who clones it.

`status` reports the mode actually in effect and which precedence level supplied
it: `COORDKIT_ENFORCEMENT` in the environment > this repo's `coord.toml`
`[enforcement].mode` > `enforcement=` in the per-user config > the built-in
`warn` default.

Note that enforcement is a separate axis from coordkit's *transport* mode
(`COORDKIT_MODE` / the top-level `mode` key, which selects local/git/relay
sharing). Setting one never affects the other.

After running, tell me in one or two lines: which mode is now in effect, where
that came from, and — if I just turned it **on** — that files this session
hasn't Read yet will be denied on first Write/Edit until I Read them once.
