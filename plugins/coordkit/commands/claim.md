---
description: Claim a task on the shared command-center board so other Claude instances in this repo know you own it
argument-hint: <short task description>
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh claim:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh tasks:*)
---

Claim this task on the shared board, then show the current board.

The task description I want to claim is:

$ARGUMENTS

Claim it by calling the Bash tool with the script below, passing my description
as ONE single-quoted argument. Escape any single quote embedded in the text as
`'\''` so arbitrary content (double quotes, `$(...)`, backticks, `;`) stays
literal and is never interpreted by the shell — do NOT interpolate the text
unquoted:

`${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh claim '<description, single-quoted>'`

Then, so the board reflects the claim you just made, run the board display (it
takes no arguments):

`${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh tasks`

Confirm to me what I claimed and whether any open task on the board overlaps with it.
