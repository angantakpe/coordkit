---
description: Send a message to another live Claude instance in this repo (delivered on its next turn)
argument-hint: <all|sid8|branch:name> <message text>
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh msg:*)
---

Deliver this message to the target instance(s). First argument is the target
(`all`, an 8-char session-id prefix shown in /bus, or `branch:<name>`); the rest is the message.

!`${CLAUDE_PLUGIN_ROOT}/scripts/claude-bus.sh msg $ARGUMENTS`

Confirm delivery to me. The recipient will see the message at the start of its next turn.
