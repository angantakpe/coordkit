# skillkit

Skill auto-activation + orchestration toolkit for Claude Code. Solves the
"skills don't activate automatically" problem: a `UserPromptSubmit` hook
matches every prompt against `skill-rules.json` trigger definitions and
injects a "use this skill BEFORE responding" reminder into the turn's context.

Ported into coordkit (the marketplace) from
[claude-code-infrastructure-showcase](https://github.com/codehornets/claude-code-infrastructure-showcase)
with two changes:

1. **Dependency-free engine.** The original hook shelled out to `npx tsx` (a
   TypeScript runtime) on every prompt. The matcher is re-implemented in
   bash + jq — a single `jq` pass, no node, no `npm install`.
2. **Layered rules resolution.** Rules merge from two locations, project
   overriding global per skill name:
   - `~/.claude/skills/skill-rules.json` — global, applies everywhere
   - `<project>/.claude/skills/skill-rules.json` — per-project

Like coordkit, skillkit is **suggest-only — it never blocks a tool call.**

## What ships

| Component | What it is |
| --- | --- |
| `scripts/skill-activation.sh` | The engine (UserPromptSubmit hook) |
| `templates/skill-rules.example.json` | Starter rules file — copy and edit |
| `agents/` (10) | code-architecture-reviewer, code-refactor-master, refactor-planner, plan-reviewer, documentation-architect, web-research-specialist, frontend-error-fixer, auto-error-resolver, auth-route-tester, auth-route-debugger |
| `commands/` (3) | `/skillkit:dev-docs`, `/skillkit:dev-docs-update` (context-reset-surviving task docs), `/skillkit:route-research-for-testing` |
| `skills/skill-developer/` | Meta-skill: authoring skills, the 500-line modular rule, trigger design, full `skill-rules.json` reference |

## skill-rules.json

```jsonc
{
  "skills": {
    "<skill-name-as-invocable-by-the-Skill-tool>": {   // e.g. "skillkit:skill-developer"
      "type": "domain",              // or "guardrail"
      "enforcement": "suggest",      // reserved; v1 is suggest-only
      "priority": "high",            // critical | high | medium | low → reminder grouping
      "promptTriggers": {
        "keywords": ["substring match", "case-insensitive"],
        "intentPatterns": ["(create|add).*?skill"]      // case-insensitive regex
      }
    }
  }
}
```

Skill names must be what the `Skill` tool can invoke — plugin-qualified where
applicable (`last30days:last30days`, `coordkit:ctx`, plain `dataviz`).

Trigger-design guidance (from six months of production use, via the
skill-developer meta-skill): prefer precise multi-word keywords over broad
single words — a keyword like `"api"` fires on nearly every prompt and trains
you to ignore the reminders.

## Install

```bash
/plugin install skillkit@coordkit
```

Then create your global rules file:

```bash
cp ${CLAUDE_PLUGIN_ROOT}/templates/skill-rules.example.json ~/.claude/skills/skill-rules.json
```

## Relationship to the other plugins

coordkit answers "who else is working here" and, in opt-in guard mode, stops
cross-instance clobbers; **skillkit answers "which of my installed skills
should fire for this prompt."** Both follow the marketplace's layering
contract: skillkit only observes and surfaces, never blocks; coordkit's guard
mode is the one thing in this marketplace that can deny a tool call, and only
when a repo has explicitly opted in.
