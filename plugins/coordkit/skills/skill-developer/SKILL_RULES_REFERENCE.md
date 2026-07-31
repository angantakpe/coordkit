# skill-rules.json - Complete Reference

Complete schema and configuration reference for `skill-rules.json`, the file
coordkit's skill-activation hook reads.

## Table of Contents

- [File Location](#file-location)
- [Complete Schema](#complete-schema)
- [Field Guide](#field-guide)
- [Example: Guardrail Skill](#example-guardrail-skill)
- [Example: Domain Skill](#example-domain-skill)
- [Validation](#validation)

---

## File Location

Two layers, both optional, both using the identical schema:

| Layer   | Path                                                     |
| ------- | -------------------------------------------------------- |
| Global  | `~/.claude/skills/skill-rules.json`                       |
| Project | `$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json`     |

Both are read and their `skills` objects merged; a project entry **replaces**
the global entry with the same skill name (a whole-entry override, not a deep
merge). A ready-to-copy starting point ships at
`plugins/coordkit/templates/skill-rules.example.json`.

---

## Complete Schema

```jsonc
{
  "version": "1.0",              // free-form; not interpreted by the hook
  "skills": {
    "<skill-name>": {            // must match what the Skill tool invokes;
                                 // plugin-qualified for plugin skills,
                                 // e.g. "coordkit:skill-developer"
      "type": "domain",          // "domain" | "guardrail" — metadata only
      "enforcement": "suggest",  // reserved; v1 is suggest-only
      "priority": "medium",      // "critical" | "high" | "medium" | "low"
      "description": "...",      // for humans reading this file
      "promptTriggers": {
        "keywords": ["..."],        // case-insensitive substring match
        "intentPatterns": ["..."]   // case-insensitive regex
      }
    }
  }
}
```

Only `skills[].priority` and `skills[].promptTriggers` affect hook behaviour.
Everything else is documentation for whoever maintains the file.

> There is no `fileTriggers`, `blockMessage`, or `skipConditions` support.
> Activation is driven entirely by the text of the user's prompt, and it never
> blocks a tool call. See [HOOK_MECHANISMS.md](HOOK_MECHANISMS.md).

---

## Field Guide

### Top Level

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | Optional | Schema version marker for humans; unread by the hook |
| `skills` | object | Yes | Map of skill name → SkillRule. Absent/empty means nothing ever matches |

### SkillRule Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Optional | `"guardrail"` or `"domain"`. Descriptive only |
| `enforcement` | string | Optional | Reserved for a future release; every match is a suggestion today |
| `priority` | string | Optional | `"critical"`, `"high"`, `"medium"` (default), or `"low"`. Chooses the heading the suggestion appears under |
| `description` | string | Optional | One-line note for maintainers |
| `promptTriggers` | object | Optional | Match conditions. An entry without it can never match |

### promptTriggers Fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `keywords` | string[] | Optional | Substring matches, case-insensitive, no word boundaries |
| `intentPatterns` | string[] | Optional | Regex patterns, case-insensitive. An invalid pattern silently never matches |

A skill matches if **any** keyword **or any** intent pattern matches. Omitting
one of the two lists is equivalent to supplying an empty one.

---

## Example: Guardrail Skill

A `guardrail` entry looks the same as any other; the difference is the
`critical` priority, which surfaces it under the most prominent heading.

```json
{
  "skills": {
    "database-verification": {
      "type": "guardrail",
      "enforcement": "suggest",
      "priority": "critical",
      "description": "Verify table/column names before writing queries",
      "promptTriggers": {
        "keywords": [
          "prisma",
          "database",
          "table",
          "column",
          "schema",
          "query",
          "migration"
        ],
        "intentPatterns": [
          "(modify|update|change).*?(table|column|schema|field)",
          "database.*?(change|update|modify|migration)"
        ]
      }
    }
  }
}
```

### Key Points for Guardrails

1. **priority**: use `"critical"` or `"high"` so it lands in the top buckets
2. **keywords**: name the technology and the nouns people actually type
3. It still only *suggests* — if the practice truly must be enforced, that
   belongs in a `PreToolUse` hook of its own, not in `skill-rules.json`

---

## Example: Domain Skill

```json
{
  "skills": {
    "coordkit:skill-developer": {
      "type": "domain",
      "enforcement": "suggest",
      "priority": "high",
      "description": "Meta-skill for creating and managing Claude Code skills",
      "promptTriggers": {
        "keywords": [
          "create skill",
          "new skill",
          "skill rules",
          "skill-rules.json",
          "skill triggers",
          "skill activation"
        ],
        "intentPatterns": [
          "(create|add|build|write).*?skill",
          "skill.*?(trigger|activate|not activating)"
        ]
      }
    }
  }
}
```

### Key Points for Domain Skills

1. **priority**: `"high"` or `"medium"`
2. **keywords**: prefer multi-word phrases — single common words fire constantly
3. **intentPatterns**: catch the phrasings that never mention the topic by name

---

## Validation

### Check JSON Syntax

```bash
jq . ~/.claude/skills/skill-rules.json
```

If valid, jq pretty-prints the file. If invalid, it prints the error. This
matters more than usual here: the hook suppresses jq's stderr, so a malformed
rules file makes activation silently stop working rather than fail loudly.

### Check That It Actually Matches

```bash
echo '{"prompt":"how do I create a new skill?"}' \
  | bash plugins/coordkit/scripts/skill-activation.sh
```

### Common JSON Errors

**Trailing comma:**
```json
{
  "keywords": ["one", "two",]
}
```

**Missing quotes on a key:**
```json
{
  type: "guardrail"
}
```

**Single quotes (invalid JSON):**
```json
{
  'type': 'guardrail'
}
```

### Validation Checklist

- [ ] JSON syntax valid (use `jq`)
- [ ] Every entry sits under the top-level `skills` object
- [ ] Skill names match exactly what the Skill tool expects (plugin-qualified for plugin skills)
- [ ] Intent patterns are valid regex
- [ ] Keywords are specific enough not to match unrelated prompts
- [ ] Priority matches how urgently the skill should be surfaced
- [ ] No duplicate skill names within a file

---

**Related Files:**
- [SKILL.md](SKILL.md) - Main skill guide
- [TRIGGER_TYPES.md](TRIGGER_TYPES.md) - Complete trigger documentation
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) - Debugging configuration issues
