---
description: Claim a task on the shared command-center board so other Claude instances in this repo know you own it
argument-hint: <short task description>
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh claim:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh tasks:*)
---

Claim this task on the shared board, then show the current board.

!`${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh claim "$ARGUMENTS"`
!`${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh tasks`

Confirm to me what I claimed and whether any open task on the board overlaps with it.
