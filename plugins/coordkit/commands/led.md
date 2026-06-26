---
description: Write to / drive the shared cross-instance ledger — note, decide, ask, answer, task, claim, next, done, block, board
argument-hint: <note|decide|ask|answer|task|claim|next|done|block|board> [subject] [text]
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/claude-ledger.sh:*)
---

Run the ledger subcommand the user asked for against this repo's shared context, then confirm the result.

!`${CLAUDE_PLUGIN_ROOT}/scripts/claude-ledger.sh $ARGUMENTS`

Subcommands (the shared ledger lives in `<repo>/.claude-bus/ledger.jsonl`, read by every instance):
- `note "<text>"` — drop a durable note all instances will see
- `decide <subject> "<text>"` — record a decision (latest per subject wins)
- `ask <subject> "<q>"` / `answer <subject> "<a>"` — open/close a question thread
- `task "<desc>"` — queue work (add `dep:<subject>` in the text to order it)
- `next` — auto-claim the first open task whose deps are satisfied (work-stealing)
- `claim <subject>` / `done <subject>` / `block <subject> "<why>"`
- `board` — show the projected task queue

After running, tell me what changed and, if I just created or finished a task, whether `/led next` has anything for me to pick up next.
