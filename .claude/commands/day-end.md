---
description: Evening routine — log work to YouTrack, push WIP so nothing is stranded, leave a next-steps note
argument-hint: "[hours worked and/or what you did today] (optional)"
allowed-tools: Bash(git:*), Bash(basename:*), mcp__youtrack__get_issue, mcp__youtrack__log_work, mcp__youtrack__update_issue, mcp__youtrack__add_issue_comment, mcp__youtrack__get_current_user
tags: [routine, wrapup, standup]
---

You are running the developer **evening routine** (stage 8: Wrap up).

## 1. Take stock
- `git -C <repo> status -sb` and `git -C <repo> log --oneline @{u}.. 2>/dev/null` to see today's local commits and any uncommitted work.
- Identify the active ticket from the branch name (leading letters+digits → e.g. `intra33-...` → `INTRA-33`, per [[feedback_branch_youtrack_pattern]]).

## 2. Don't strand work
- If there are uncommitted changes, summarize them and offer to commit as WIP (referencing the ticket) and `git push` so nothing lives only on this machine. Confirm before committing.
- If there are unpushed commits, offer to push them.

## 3. Update YouTrack
- For the active ticket: `mcp__youtrack__log_work` with today's effort (use `$ARGUMENTS` for hours/description; if not given, estimate from commit activity and ask to confirm).
- If the work advanced the ticket, propose a state change via `mcp__youtrack__update_issue` (e.g. In Progress → In Review) and/or an `add_issue_comment` summarizing progress + where I left off. Confirm before writing.

## 4. Tomorrow note
- Produce a short end-of-day summary: what got done, what's in flight, the exact next step to resume (file/function/command), and any blockers to raise at standup.
- Keep it copy-pasteable so `/day-start` tomorrow picks up cleanly.
