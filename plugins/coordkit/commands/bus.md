---
description: Show the Claude command center — who else is live in this repo, what they're working on, and which files they're touching
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh dashboard:*)
---

Run the command center dashboard for the current repo and present it to me.

!`${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh dashboard "$CLAUDE_PROJECT_DIR"`

Show the dashboard output above. Then, in one or two lines:
- Call out any file I'm about to work on that another **live** agent is also touching (collision risk).
- If another agent's task overlaps with mine, say so and suggest how to divide the work or which branch to use.
If no other agents are live, just say the coast is clear.
