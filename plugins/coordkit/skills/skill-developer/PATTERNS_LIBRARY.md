# Common Patterns Library

Ready-to-use keyword and regex patterns for `promptTriggers`. Copy and customize
for your skills.

All of these match against the **text of the user's prompt** — that is the only
thing coordkit's skill-activation hook sees. Glob and file-content patterns have
no equivalent here; see [TRIGGER_TYPES.md](TRIGGER_TYPES.md).

---

## Intent Patterns (Regex)

Case-insensitive. Use non-greedy `.*?` between the verb group and the noun group.

### Feature/Endpoint Creation
```regex
(add|create|implement|build).*?(feature|endpoint|route|service|controller)
```

### Component Creation
```regex
(create|add|make|build).*?(component|UI|page|modal|dialog|form)
```

### Database Work
```regex
(add|create|modify|update).*?(table|column|field|schema|migration)
(database|prisma).*?(change|update|query)
```

### Error Handling
```regex
(fix|handle|catch|debug).*?(error|exception|bug)
(add|implement).*?(try|catch|error.*?handling)
```

### Explanation Requests
```regex
(how does|how do|explain|what is|describe|tell me about).*?(your-topic|synonym)
```

Note the trailing group: a bare `(how does|explain).*?` matches essentially every
question a user asks, and will suggest your skill constantly.

### Debugging an Existing Thing
```regex
(debug|troubleshoot|fix|why (is|isn't)).*?(your-topic)
```

### Testing
```regex
(write|create|add).*?(test|spec|unit.*?test)
```

---

## Keyword Lists

Keywords are case-insensitive substrings with no word boundaries, so favour
multi-word phrases and distinctive identifiers over short common words.

### Good: distinctive and specific
```json
"keywords": [
  "skill-rules.json",
  "skill activation",
  "hooks.json",
  "UserPromptSubmit"
]
```

### Bad: fires on unrelated prompts
```json
"keywords": ["user", "create", "system", "file"]
```

`"user"` alone also matches "users", "superuser" and "perused"; `"create"`
matches almost any request to make something.

### Pattern: filenames and identifiers
Exact filenames, config keys, and API names make excellent keywords — they are
long, distinctive, and people type them verbatim when they need the skill.

---

## Usage Example

```json
{
  "skills": {
    "my-skill": {
      "type": "domain",
      "enforcement": "suggest",
      "priority": "medium",
      "description": "Guidance for building UI components",
      "promptTriggers": {
        "keywords": [
          "design system",
          "component library"
        ],
        "intentPatterns": [
          "(create|add|build).*?(component|UI|page)"
        ]
      }
    }
  }
}
```

Verify it before relying on it:

```bash
echo '{"prompt":"build a new modal component"}' \
  | bash plugins/coordkit/scripts/skill-activation.sh
```

---

**Related Files:**
- [SKILL.md](SKILL.md) - Main skill guide
- [TRIGGER_TYPES.md](TRIGGER_TYPES.md) - Detailed trigger documentation
- [SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md) - Complete schema
