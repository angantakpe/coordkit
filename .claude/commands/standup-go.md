---
description: Standup recap, then (on your trigger) spin up a team of agents to fully execute today's tasks — implement, push, and open MRs
argument-hint: [days=1]
allowed-tools: Bash, Read, Edit, Write, Task, mcp__youtrack__get_current_user, mcp__youtrack__search_issues, mcp__youtrack__get_issue
---

Produce a standup, then offer to dispatch a team of agents that **fully ship**
today's tasks. This composes existing routines: the standup half is `/standup`;
the task list merges git activity with my workable YouTrack tickets (the
`/day-start` gate); each agent composes `/plan-ticket` → `/verify-change` →
`/open-mr`.

Lookback window (days): $ARGUMENTS

## Stage 1 — Standup (read-only)

1. **Resolve the window** — parse `$ARGUMENTS` as a positive integer; default `1`.
   Call it `N`, `since="N days ago"`.

2. **Gather git** in the current repo (run `git rev-parse --is-inside-work-tree`
   first; if not a repo, say so and skip git, but still fetch YouTrack):
   - Commits: `git log --since="<since>" --pretty=format:'%h %s'`
   - Churn: `git diff --stat "@{N.days.ago}"` (fall back to
     `git log --since="<since>" --shortstat --pretty=format:''`).

3. **Gather YouTrack** — `mcp__youtrack__get_current_user`, then
   `mcp__youtrack__search_issues` for `for: me order by: updated desc` with
   `customFieldsToReturn: ["Status","State","Assignee","Priority"]`.
   ⚠️ In the **Intra** project the state field is **`Status`**, not `State`.
   Apply the `/day-start` **workable-ticket gate**: keep only tickets I can act
   on now (e.g. `In progress`, `Confirmed`, `Open`, `Task Assigned`); drop
   `New`, `Validated`, `Staging`, `Deployed`, `Resolved`, `Closed`.

4. **Merge into a task list** — correlate commits to tickets by explicit key
   (`Intra-33`, `CS-12`) or branch→key (`intra33-…` → `Intra-33`, per
   [[feedback_branch_youtrack_pattern]]). The merged "Today" list = workable
   tickets, annotated with whether recent commits already touched them
   (in-flight) or not (fresh).

5. **Write the standup** — **Yesterday** (commits that landed) / **Today** (the
   merged workable-ticket list) / **Blockers** (stalled or uncertain; "None"
   otherwise). Keep it channel-paste tight; show the Today tickets as a numbered
   list with key, summary, status, and in-flight/fresh tag.

## Stage 2 — Trigger gate (ask the user)

Do **not** dispatch anything automatically. After printing the standup, use
**AskUserQuestion** to ask whether to launch the agent team:
- **Ship all** — one agent per Today ticket.
- **Pick a subset** — let me name which ticket numbers to run.
- **Cancel** — stop here; standup only.

If the user cancels, end after the standup. Honor any subset they choose.

## Stage 3 — Dispatch the agent team (only after trigger)

Spawn **one agent per chosen ticket, in parallel** (a single message with
multiple `Task` calls), each with `isolation: "worktree"` so they don't collide
in the shared tree. Give each agent this brief:

> You own ticket **<KEY>** end-to-end. Working in your isolated worktree under
> `effenco/modules/<module>` (resolve the module from the ticket's recent
> commits/branch, else ask):
> 1. Read the ticket via `mcp__youtrack__get_issue`. Plan it the `/plan-ticket`
>    way: break into tasks, create the correctly-named branch off the right base
>    (branch name encodes the key per [[feedback_branch_youtrack_pattern]]).
> 2. Implement the change. Match surrounding code style.
> 3. Verify like `/verify-change`: run the module's tests + lint; exercise the
>    fix/feature. Do not proceed if verification fails — report the failure.
> 4. Ship like `/open-mr`: push the branch and open the merge request against
>    the correct target branch.
> Return: the branch name, MR URL, test/lint result, and a one-line summary.
> Never force-push, never touch another ticket's branch, never merge.

## Stage 4 — Report

Collect the agents' results into a table: **Ticket · Module · Branch · MR ·
Tests · Status**. Call out any agent that stopped on a verification failure or
needed a decision — those need my attention. List the MR URLs so I can review
and merge.

## Notes
- The trigger gate in Stage 2 is the authorization for the push/MR in Stage 3 —
  agents still branch first and never commit to a default branch.
- Stage 1 is always safe to run; Stage 3 mutates repos and opens MRs, so it only
  runs on an explicit trigger.
- Respect repo rules and memory ([[feedback_branch_youtrack_pattern]],
  [[reference_intranet_environments]]).
