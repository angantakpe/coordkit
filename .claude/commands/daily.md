---
description: Walk the full developer daily routine top-to-bottom, pausing for input at each stage
argument-hint: "[YouTrack ID or module to focus on] (optional)"
allowed-tools: Bash(git:*), Bash(make:*), Bash(php:*), Bash(glab:*), Bash(kubectl:*), Bash(basename:*), Read, Edit, mcp__youtrack__get_current_user, mcp__youtrack__search_issues, mcp__youtrack__get_issue, mcp__youtrack__get_issue_comments, mcp__youtrack__change_issue_assignee, mcp__youtrack__log_work, mcp__youtrack__update_issue, mcp__youtrack__add_issue_comment
tags: [routine, orchestrator]
---

You are the **full daily-routine orchestrator**. Walk the developer day end-to-end, but treat it as a guided flow: do one stage, summarize, and **pause for the user's go-ahead before moving to the next**. Never chain destructive/outbound actions (branch create, commit, push, MR, prod) without explicit confirmation.

This command composes the per-stage commands — apply the same logic each defines rather than duplicating it:

1. **Sync & orient** — run the `/day-start` logic: fetch, status, branch→ticket mapping, list my open YouTrack issues, brief. If `$ARGUMENTS` names a ticket/module, focus there.
2. **Plan** — run the `/plan-ticket` logic for the chosen ticket: read it, break into tasks, propose a branch off the correct base (intranet→`staging2`, processor→`staging`). Confirm before creating the branch.
3. **Code** — this stage is interactive. Help implement the planned tasks, but let the user drive. Stop and hand control back; don't auto-write large changes.
4. **Verify** — run the `/verify-change` logic: tests, linters, manual repro. Report evidence.
5. **Review & MR** — run the `/open-mr` logic: commit (referencing the ticket), push, open the `glab` MR to the correct target branch. Confirm first.
6. **Ship to staging** — run the `/ship-staging` logic: confirm merge, smoke-test on staging, check logs.
7. **Wrap up** — run the `/day-end` logic: log work to YouTrack, push WIP, write a resume-tomorrow note.

## How to drive it
- Announce the current stage, do its work, then show a one-line status and ask **"continue to <next stage>?"**
- If the user only wants part of the day (e.g. they're mid-ticket), start at the relevant stage instead of stage 1 — ask which stage to resume from if it's ambiguous.
- Respect all the repo rules and memory links the per-stage commands rely on ([[feedback_intranet_staging_branch]], [[feedback_processor_staging_branch]], [[feedback_branch_youtrack_pattern]], [[reference_intranet_environments]]).
- **Workable-ticket rule ([[feedback_youtrack_workable_tickets]]):** only ever pick up tickets that are out of the `New` column **and** have a proper description. Never select, plan, or work a `New`-column or description-less ticket — flag it and move on.
- Prod release is **not** part of this flow — that's the separate `/release-prod` command, run deliberately.
