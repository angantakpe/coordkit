---
description: Map edited routes & launch tests
argument-hint: "[/extra/path …]"
allowed-tools: Bash(cat:*), Bash(awk:*), Bash(grep:*), Bash(sort:*), Bash(xargs:*), Bash(sed:*), Task
model: sonnet
---

## Context

This command assumes an HTTP service whose handlers live under a `routes/` directory and
whose edited-file log is written to `$CLAUDE_PROJECT_DIR/.claude/tsc-cache`. Adjust the
paths and grep pattern below to match the project's actual layout before running it.

Changed route files this session (auto-generated):

!cat "$CLAUDE_PROJECT_DIR/.claude/tsc-cache"/\*/edited-files.log \
 | awk -F: '{print $2}' \
 | grep '/routes/' \
 | sort -u

User-specified additional routes: `$ARGUMENTS`

## Your task

Follow the numbered steps **exactly**:

1. Combine the auto list with `$ARGUMENTS`, dedupe, and resolve any prefixes
   defined wherever the app registers its routers (e.g. `src/app.ts`).
2. For each final route, output a JSON record with the path, method, expected
   request/response shapes, and valid + invalid payload examples.
3. Call the `Task` tool with `subagent_type` set to `goal-verifier`. Pass the
   JSON records as the complete test target and ask it to verify the routes
   against their expected request/response contracts. Keep the subagent
   read-only and require command evidence for every verdict.

```json
{
    "subagent_type": "goal-verifier",
    "description": "route contract verification",
    "prompt": "Verify the route records above. Run safe smoke checks, report evidence per route, and do not modify code."
}
```
