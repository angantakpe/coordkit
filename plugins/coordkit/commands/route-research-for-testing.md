---
description: Map edited routes & launch tests
argument-hint: "[/extra/path …]"
allowed-tools: Bash(cat:*), Bash(awk:*), Bash(grep:*), Bash(sort:*), Bash(xargs:*), Bash(sed:*)
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
3. **Now call the `Task` tool** using:

```json
{
    "tool": "Task",
    "parameters": {
        "description": "route smoke tests",
        "prompt": "Run the auth-route-tester sub-agent on the JSON above."
    }
}
```
