---
description: Send a message to another live instance in this repo (delivered on its next turn)
argument-hint: <all|sid8|branch:name> <message text>
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh msg:*)
---

Deliver this message to the target instance(s). The first whitespace-separated
token of my input is the target (`all`, an 8-char session-id prefix shown in
/bus, or `branch:<name>`); everything after it is the message text.

My input:

$ARGUMENTS

Send it by calling the Bash tool with the script below. Pass the target as its
own argument, and pass the ENTIRE message as ONE single-quoted argument —
escaping any single quote embedded in it as `'\''`. This keeps double quotes,
`$(...)`, backticks, and `;` in my message literal so the shell never
interprets them; do NOT interpolate the message unquoted:

`${CLAUDE_PLUGIN_ROOT}/scripts/bus.sh msg <target> '<message, single-quoted>'`

Confirm delivery to me. The recipient will see the message at the start of its next turn.
