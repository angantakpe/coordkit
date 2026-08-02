---
description: Show the cross-repo fleet view — which OTHER repos on this machine have live coordkit sessions right now
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh fleet:*)
---

Run the cross-repo fleet view and present it to me.

!`${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh fleet "$CLAUDE_PROJECT_DIR"`

Show the fleet output above. Then, in one or two lines:
- Call out any other repo with live sessions I might want to check on.
- If nothing is registered yet, say so plainly — a repo only shows up here after
  it registers itself on its next coordkit heartbeat.

This is a read-only, local-only discovery view (see `docs/BUS.md`). It does not
dispatch tasks across repos — for that, go work in the other repo directly.
