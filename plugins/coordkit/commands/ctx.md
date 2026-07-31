---
description: Show the shared cross-instance context layer — task queue, current decisions, open questions, and recent ledger events
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh digest:*), Bash(${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh board:*)
---

Show me the shared-context ledger for this repo (what every live instance in this repo knows).

!`${CLAUDE_PLUGIN_ROOT}/scripts/ledger.sh digest`

Present the output above. Then in one or two lines:
- Flag any **open** task whose deps are satisfied that I could pick up (`/led next`).
- Call out any **open question** or **blocked** task that needs a human or another instance.
If the ledger is empty, say so and suggest seeding it with `/led decide` or `/led task`.
