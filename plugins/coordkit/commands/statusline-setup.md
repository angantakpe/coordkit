---
description: Install or check the coordkit statusline badge (🛰️ N live · ⚠ M on this branch) in your settings.json
argument-hint: install | check
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh install:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh check:*)
---

Wire (or verify) coordkit's command-center **statusline badge**.

My argument (`install` or `check` — treat anything else, including empty, as
`check`):

$ARGUMENTS

Run exactly one of these by calling the Bash tool. The subcommand is a fixed
token and takes no free text, so no quoting is needed:

`${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh check`
`${CLAUDE_PLUGIN_ROOT}/scripts/statusline-setup.sh install`

A plugin manifest can't register `settings.json`'s top-level `statusLine` key,
so the badge is the one part of coordkit that has to be wired into the user's
own config. `install` does that for me:

- writes `~/.claude/hooks/coordkit-statusline.sh`, a wrapper that discovers
  `bus.sh` **by glob at run time** — so a future marketplace or script rename
  self-heals instead of silently blanking the badge;
- points `settings.json`'s `statusLine` at that wrapper, **backing the file up
  first** and **chaining** whatever command was already there (my own
  statusline runs first, then the badge after a `│` separator) — it is never
  replaced;
- is idempotent: re-running after a coordkit update or on a fresh machine is a
  no-op when everything is already correct.

`check` changes nothing: it reports whether `statusLine` is wired, whether it
points at the coordkit wrapper, whether that wrapper's glob currently resolves
to a real `bus.sh`, and prints a badge preview. An empty preview is normal and
means no other instance is live in this repo.

After running, tell me in one or two lines: what state the statusline is in
now, what changed (or that nothing needed to change), and — if my own
statusline command was chained — which command is running before the badge.
