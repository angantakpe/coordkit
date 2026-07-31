---
description: Morning routine — sync repo, orient on current branch/ticket, list my open YouTrack issues
argument-hint: "[module name, e.g. intranet] (optional; defaults to current dir's repo)"
allowed-tools: Bash(git:*), Bash(basename:*), mcp__youtrack__get_current_user, mcp__youtrack__search_issues, mcp__youtrack__get_issue
tags: [routine, standup, sync]
---

You are running the developer **morning routine** (stage 1: Sync & Orient).

Target repo: if `$ARGUMENTS` names a module, work in `modules/$ARGUMENTS`; otherwise use the current working directory's git repo.

## 1. Sync the repo
- `git -C <repo> rev-parse --show-toplevel` and `basename` it → note which module (e.g. `intranet`, `processor`).
- `git -C <repo> fetch --all --prune`
- `git -C <repo> status -sb` and `git -C <repo> branch --show-current`
- `git -C <repo> log --oneline -5`
- Report anything that changed on the remote tracking branch overnight (ahead/behind counts).

## 2. Map branch → YouTrack ticket
- Current branch name maps to a YouTrack issue: parse the **leading letters + digits** (see [[feedback_branch_youtrack_pattern]]). e.g. `intra33-...` → `INTRA-33`.
- If the branch matches, call `mcp__youtrack__get_issue` for that ID and summarize: title, state, description, latest comments.
- If the branch does **not** match the pattern (e.g. `fix-500-...`), say so and skip — don't guess a ticket.

## 3. List my open work
- `mcp__youtrack__get_current_user` to resolve me.
- `mcp__youtrack__search_issues` with a query like `for: me Status: -Resolved -Done -New order by: updated desc` (limit ~15), passing `customFieldsToReturn: ["Status","Assignee","Priority"]`.
  - ⚠️ In the **Intra** project the state field is named **`Status`**, not `State` — filter on `Status:` or the `New` exclusion silently does nothing.
- **Workable-ticket rule (see [[feedback_youtrack_workable_tickets]]):**
  - **Never treat issues in the `New` column/status as workable** — they're untriaged. Exclude them from the actionable list (or list them in a separate "⛔ Not ready — do not touch" group, never as a suggestion).
  - **Only consider a ticket actionable if it has a proper description** — a real spec/acceptance criteria, not an empty or one-line stub. The list query does **not** return descriptions, so `get_issue` each top candidate to confirm it has one; flag description-less tickets as "needs detail" and keep them out of the suggested-focus list.
- Present a short prioritized list of **workable** tickets: `ID — summary — status`.

## 4. Brief
Output a tight standup-style summary:
- **Repo / branch** and sync state (ahead/behind, uncommitted changes).
- **Active ticket** (if branch maps to one) with its current state.
- **My open issues** (top few), flagging anything In Progress or blocked.
- **Suggested focus** for today (1–2 items), and the next command to run (`/plan-ticket <ID>`).

Keep it scannable. Do not start coding — this is orientation only.
