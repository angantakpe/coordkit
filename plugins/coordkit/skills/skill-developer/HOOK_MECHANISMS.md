# Hook Mechanisms - Deep Dive

Technical deep dive into how coordkit's skill-activation hook works.

## Table of Contents

- [UserPromptSubmit Hook Flow](#userpromptsubmit-hook-flow)
- [Rule Layering and Merge Order](#rule-layering-and-merge-order)
- [Matching Semantics](#matching-semantics)
- [Exit Code and Stream Behavior](#exit-code-and-stream-behavior)
- [Performance Considerations](#performance-considerations)
- [What This Hook Does Not Do](#what-this-hook-does-not-do)

---

## UserPromptSubmit Hook Flow

Skill activation is a single stateless bash script,
`plugins/coordkit/scripts/skill-activation.sh`, registered under
`UserPromptSubmit` in `plugins/coordkit/hooks/hooks.json`.

### Execution Sequence

```
User submits prompt
    ↓
hooks.json registers the hook (UserPromptSubmit)
    ↓
bash skill-activation.sh executes
    ↓
jq present?  no → exit 0, silently
    ↓ yes
Read stdin (JSON), extract .prompt
    ↓
Prompt empty, or starts with "/"?  → exit 0, no output
    ↓
Lowercase the prompt
    ↓
Load global ~/.claude/skills/skill-rules.json (if present)
Load project $CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json (if present)
    ↓
Neither present? → exit 0
    ↓
Merge the two "skills" objects (project wins on name collision)
    ↓
Select entries whose keywords or intentPatterns match the prompt
    ↓
Group matches by priority (critical → high → medium → low)
    ↓
Print the formatted block to stdout
    ↓
stdout is injected as context for the turn
    ↓
Claude sees: [skill suggestion] + user's prompt
```

### Key Points

- **Exit code**: always `0`. The hook cannot block a prompt.
- **stdout**: injected as context for the turn, as plain text — the script does
  **not** wrap its output in a JSON `hookSpecificOutput` object.
- **Timing**: runs before Claude processes the prompt.
- **Behaviour**: non-blocking, advisory only (coordkit's WARN-only philosophy).
- **State**: none. Every prompt is evaluated independently.

### Input Format

The hook reads one JSON object on stdin. Only `.prompt` is used; the rest is
ignored.

```json
{
  "session_id": "abc-123",
  "transcript_path": "/path/to/transcript.json",
  "cwd": "/path/to/your/repo",
  "permission_mode": "normal",
  "hook_event_name": "UserPromptSubmit",
  "prompt": "how do I add a new skill?"
}
```

### Output Format (to stdout)

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎯 SKILL ACTIVATION CHECK (skillkit)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📚 RECOMMENDED SKILLS:
  → coordkit:skill-developer

ACTION: Invoke the matching Skill tool BEFORE responding
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

Only the priority buckets that actually have matches are printed. When nothing
matches, the script prints nothing at all.

---

## Rule Layering and Merge Order

Two files are read, in this order:

1. `~/.claude/skills/skill-rules.json` (global)
2. `$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json` (project) — falls back
   to `$PWD` when `CLAUDE_PROJECT_DIR` is unset

The project file is skipped if it resolves to the same path as the global one.
The `skills` objects from each file are merged with the later file winning, so a
project entry **replaces** the global entry of the same skill name outright — it
is not a deep merge, so a project entry must restate every field it needs.

Both files use the identical schema; see
[SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md).

---

## Matching Semantics

A skill matches if **either** condition holds:

- **`promptTriggers.keywords`** — any keyword is a *substring* of the prompt.
  Both sides are lowercased, so matching is case-insensitive. There is no word
  boundary: the keyword `"ci"` matches the word "specific".
- **`promptTriggers.intentPatterns`** — any pattern matches the prompt as a
  case-insensitive regex (`jq`'s `test($re; "i")`, i.e. Oniguruma syntax). An
  invalid regex is caught and treated as "no match" rather than erroring out.

Missing `keywords` or `intentPatterns` are treated as empty lists. An entry with
neither can never match.

---

## Exit Code and Stream Behavior

| Situation                  | Exit code | stdout                 | Effect on the turn        |
| -------------------------- | --------- | ---------------------- | ------------------------- |
| Match found                | 0         | reminder block         | Injected as context       |
| No match                   | 0         | (empty)                | Nothing injected          |
| No rules files             | 0         | (empty)                | Nothing injected          |
| `jq` missing               | 0         | (empty)                | Nothing injected          |
| Prompt is a slash command  | 0         | (empty)                | Nothing injected          |

There is no non-zero path. The script uses `set -uo pipefail` (deliberately not
`-e`) and suppresses `jq` stderr, so a malformed rules file degrades to silence
rather than to a broken turn. That is convenient in production and inconvenient
while debugging — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for how to
surface the error.

---

## Performance Considerations

**Target**: < 100ms. The hook is registered with a 5-second timeout in
`hooks.json`.

The cost is one `jq` process plus reading both rules files, on every prompt.
Practical guidance:

- Keep `skill-rules.json` small — it is re-read and re-parsed each prompt.
- Prefer keywords over regex where either would do; substring matching is
  cheaper than compiling a pattern.
- Keep `intentPatterns` simple. Avoid nested quantifiers, which can backtrack
  badly on long prompts.
- There is no caching layer, so the number of entries is the main lever.

---

## What This Hook Does Not Do

Skill activation in coordkit is deliberately narrow. It does **not**:

- Block, deny, or modify any tool call
- Inspect file paths or file contents
- Run on `PreToolUse`, `PostToolUse`, or `Stop`
- Track session state, or remember what it suggested last turn
- Detect whether Claude actually invoked the suggested skill

coordkit *does* register `SessionStart`, `PreToolUse`, `PostToolUse` and
`SessionEnd` hooks in the same `hooks.json`, but those run `swarm.sh` for the
coordination bus and anti-clobber guard. They are unrelated to skill activation.

---

**Related Files:**
- [SKILL.md](SKILL.md) - Main skill guide
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Debug hook issues
- [SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md) - Configuration reference
