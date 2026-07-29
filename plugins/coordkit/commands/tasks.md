---
description: Show the shared command-center task board for this repo (who has claimed what)
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh tasks:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh done:*)
---

!`${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh tasks`

Summarize the open vs done tasks above. To mark one done, call the Bash tool with `${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh done '<text to match>'`, passing the match text as one single-quoted argument (escape any embedded single quote as `'\''`) so it is never interpreted by the shell.
