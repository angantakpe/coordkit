---
description: Show the shared command-center task board for this repo (who has claimed what)
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh tasks:*)
---

!`${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh tasks`

Summarize the open vs done tasks above. To mark one done, I can run `${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh done "<text>"`.
