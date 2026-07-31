# Trigger Types - Complete Guide

Complete reference for configuring skill triggers in coordkit's skill
auto-activation system.

coordkit matches on the **text of the user's prompt only**. There are two
trigger types, both living under `promptTriggers`: keywords and intent patterns.
File-path and file-content triggers are not supported — the hook never sees a
file path. See [HOOK_MECHANISMS.md](HOOK_MECHANISMS.md) for why.

## Table of Contents

- [Keyword Triggers (Explicit)](#keyword-triggers-explicit)
- [Intent Pattern Triggers (Implicit)](#intent-pattern-triggers-implicit)
- [Choosing Between Them](#choosing-between-them)
- [Best Practices Summary](#best-practices-summary)

---

## Keyword Triggers (Explicit)

### How It Works

Case-insensitive substring matching against the user's prompt. Both the prompt
and the keyword are lowercased before comparison, and there is **no word
boundary** — the keyword `"grid"` also matches "gridlock".

### Use For

Topic-based activation where the user explicitly mentions the subject.

### Configuration

```json
"promptTriggers": {
  "keywords": ["skill rules", "skill-rules.json", "skill activation"]
}
```

### Example

- User prompt: "how do I change the **skill activation** rules?"
- Matches: the `"skill activation"` keyword
- Suggests: `coordkit:skill-developer`

### Best Practices

- Use specific, unambiguous terms — preferably multi-word phrases
- Include common variations ("skill rules", "skill-rules.json")
- Avoid generic words ("system", "work", "create"), which fire on every prompt
- Remember substrings match inside other words; prefer longer keywords
- Test with real prompts

---

## Intent Pattern Triggers (Implicit)

### How It Works

Case-insensitive regex matching against the prompt, to catch the user's intent
even when they never name the topic. Patterns are evaluated by `jq`'s
`test($re; "i")`, so the syntax is Oniguruma (a superset of POSIX ERE that
supports the usual Perl-style shorthands). A pattern that fails to compile is
caught and treated as "no match" — silently, so test yours.

### Use For

Action-based activation, where the user describes what they want to do rather
than the specific topic.

### Configuration

```json
"promptTriggers": {
  "intentPatterns": [
    "(create|add|build|write).*?skill",
    "(how does|explain).*?(hook|activation)"
  ]
}
```

### Examples

**Skill authoring:**
- User prompt: "add a new one of those auto-triggering things"
- Matches: `(create|add|build|write).*?skill` — only if "skill" appears; this one
  would *not* match, which is exactly the kind of gap to find by testing

**Debugging:**
- User prompt: "why isn't my skill triggering?"
- Matches: `skill.*?(trigger|activate|not activating)`

### Best Practices

- Capture common action verbs: `(create|add|modify|build|implement)`
- Include domain-specific nouns: `(hook|trigger|skill|rule)`
- Use non-greedy matching: `.*?` rather than `.*`
- Test patterns with a regex tester (https://regex101.com/) **and** against the
  real hook — see below
- Don't make patterns too broad (false positives on every prompt)
- Don't make them too specific (they never fire)

### Common Pattern Shapes

```regex
# Explanations
(how does|how do|explain|what is|describe).*?(topic|other-topic)

# Creation
(create|add|make|build|implement).*?(thing|other-thing)

# Debugging
(fix|debug|why (is|isn't)|troubleshoot).*?(error|failing|not working)

# Modification
(modify|update|change|rename).*?(config|rule|setting)
```

---

## Choosing Between Them

| Situation                                        | Use              |
| ------------------------------------------------ | ---------------- |
| The user will name the topic outright            | `keywords`       |
| A distinctive filename or identifier is involved | `keywords`       |
| The user describes an action, not the topic      | `intentPatterns` |
| You need several near-synonyms in one rule       | `intentPatterns` |

A skill matches if **any** keyword **or any** pattern matches, so most entries
usefully carry both.

---

## Best Practices Summary

### DO:
✅ Use specific, unambiguous keywords
✅ Test every pattern with real prompts
✅ Include common variations
✅ Use non-greedy regex: `.*?`
✅ Prefer multi-word keywords over single common words

### DON'T:
❌ Use overly generic keywords ("system", "work")
❌ Make intent patterns too broad (false positives)
❌ Make patterns too specific (false negatives)
❌ Assume a bad regex will error — it just silently never matches
❌ Use greedy regex: `.*` instead of `.*?`

### Testing Your Triggers

Feed the hook a prompt exactly as Claude Code would:

```bash
echo '{"prompt":"your test prompt"}' \
  | bash plugins/coordkit/scripts/skill-activation.sh
```

A match prints the "SKILL ACTIVATION CHECK" block naming your skill; no match
prints nothing. Test both the prompts that *should* fire it and a few that
should not.

---

**Related Files:**
- [SKILL.md](SKILL.md) - Main skill guide
- [SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md) - Complete skill-rules.json schema
- [PATTERNS_LIBRARY.md](PATTERNS_LIBRARY.md) - Ready-to-use pattern library
