---
name: skill-developer
description: Create and manage Claude Code skills following Anthropic best practices. Use when creating new skills, modifying skill-rules.json, understanding trigger patterns, working with hooks, debugging skill activation, or implementing progressive disclosure. Covers skill structure, YAML frontmatter, prompt trigger types (keywords, intent patterns), priority levels, coordkit's UserPromptSubmit skill-activation hook, and the 500-line rule.
---

# Skill Developer Guide

## Purpose

Guide for creating and managing skills in Claude Code, and for wiring them into
coordkit's skill auto-activation hook. Follows Anthropic's official best
practices including the 500-line rule and progressive disclosure.

## When to Use This Skill

Automatically activates when you mention:
- Creating or adding skills
- Modifying skill triggers or rules
- Understanding how skill activation works
- Debugging skill activation issues
- Working with skill-rules.json
- Hook system mechanics
- Claude Code best practices
- Progressive disclosure
- YAML frontmatter
- 500-line rule

---

## System Overview

### Single-Hook Architecture

coordkit's skill auto-activation is one dependency-free bash script wired to one
hook event. There is no TypeScript, no `npx tsx`, no Stop hook, and no
PreToolUse blocking of edits on behalf of a skill.

**UserPromptSubmit Hook** (proactive suggestions)
- **Script**: `plugins/coordkit/scripts/skill-activation.sh` (bash + `jq`)
- **Registration**: `plugins/coordkit/hooks/hooks.json`, under `UserPromptSubmit`
- **Trigger**: before Claude sees the user's prompt
- **Purpose**: suggest relevant skills based on keywords + intent patterns
- **Method**: prints a plain-text reminder block on **stdout**, which Claude Code
  injects as context for the turn. It does *not* emit a JSON
  `hookSpecificOutput` wrapper.
- **Exit code**: always `0` — the hook never blocks anything, in line with
  coordkit's WARN-only philosophy.

**Behaviour worth knowing:**
- If `jq` is not installed, the hook exits silently and does nothing.
- Prompts starting with `/` are skipped — a slash command already names its skill.
- Matching is case-insensitive (the prompt is lowercased before matching).
- If nothing matches, the hook prints nothing.

Note that coordkit registers *other* hooks in the same `hooks.json`
(`SessionStart`, `PreToolUse`, `PostToolUse`, `SessionEnd`) — those belong to the
coordination bus and anti-clobber guard (`swarm.sh`), not to skill activation.
`skill-activation.sh` is stateless and independent of them.

### Configuration File

Rules are layered, and both layers use the same schema:

1. **Global**: `~/.claude/skills/skill-rules.json`
2. **Project**: `$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json`

Both files are read; their `skills` objects are merged, and a project entry
**overrides** the global entry with the same skill name. If neither file exists,
the hook does nothing.

A starting point ships at `plugins/coordkit/templates/skill-rules.example.json`.

Each entry defines:
- The skill name **exactly as the Skill tool invokes it** (use the
  plugin-qualified form for plugin skills, e.g. `coordkit:skill-developer`)
- `type`, `priority`, `description`
- `promptTriggers.keywords` (substring match) and
  `promptTriggers.intentPatterns` (regex)

`enforcement` is accepted in the schema but is **reserved** — v1 is suggest-only
and every match is rendered as a suggestion regardless of its value.

---

## Skill Types

`type` is descriptive metadata for humans reading the rules file; it does not
change hook behaviour today.

### 1. Guardrail Skills

**Purpose:** flag critical best practices that prevent errors

**Characteristics:**
- Type: `"guardrail"`
- Priority: `"critical"` or `"high"` — surfaces under the
  "⚠️ CRITICAL SKILLS (REQUIRED)" or "📚 RECOMMENDED SKILLS" heading
- Advisory in practice: the hook suggests, it does not block the edit

**When to Use:**
- Mistakes that cause runtime errors
- Data integrity concerns
- Critical compatibility issues

### 2. Domain Skills

**Purpose:** provide comprehensive guidance for a specific area

**Characteristics:**
- Type: `"domain"`
- Priority: `"high"`, `"medium"` or `"low"`
- Topic or domain-specific, comprehensive documentation

**When to Use:**
- Complex systems requiring deep knowledge
- Best practices documentation
- Architectural patterns
- How-to guides

---

## Quick Start: Creating a New Skill

### Step 1: Create Skill File

**Location:** `.claude/skills/{skill-name}/SKILL.md` (project skill),
`~/.claude/skills/{skill-name}/SKILL.md` (global), or a plugin's `skills/`
directory.

**Template:**
```markdown
---
name: my-new-skill
description: Brief description including keywords that trigger this skill. Mention topics, file types, and use cases. Be explicit about trigger terms.
---

# My New Skill

## Purpose
What this skill helps with

## When to Use
Specific scenarios and conditions

## Key Information
The actual guidance, documentation, patterns, examples
```

**Best Practices:**
- ✅ **Name**: Lowercase, hyphens, gerund form (verb + -ing) preferred
- ✅ **Description**: Include ALL trigger keywords/phrases (max 1024 chars)
- ✅ **Content**: Under 500 lines - use reference files for details
- ✅ **Examples**: Real code examples
- ✅ **Structure**: Clear headings, lists, code blocks

### Step 2: Add to skill-rules.json

See [SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md) for the complete schema.

**Basic Template:**
```json
{
  "skills": {
    "my-new-skill": {
      "type": "domain",
      "enforcement": "suggest",
      "priority": "medium",
      "description": "One line, for humans reading this file",
      "promptTriggers": {
        "keywords": ["keyword1", "keyword2"],
        "intentPatterns": ["(create|add).*?something"]
      }
    }
  }
}
```

### Step 3: Test Triggers

Feed the hook a prompt on stdin, exactly as Claude Code would:

```bash
echo '{"prompt":"your test prompt"}' \
  | bash plugins/coordkit/scripts/skill-activation.sh
```

A match prints the "SKILL ACTIVATION CHECK" block; no match prints nothing.
Validate the rules file itself with `jq . ~/.claude/skills/skill-rules.json`.

### Step 4: Refine Patterns

Based on testing:
- Add missing keywords
- Refine intent patterns to reduce false positives
- Re-run the test command above against several realistic prompts

### Step 5: Follow Anthropic Best Practices

✅ Keep SKILL.md under 500 lines
✅ Use progressive disclosure with reference files
✅ Add table of contents to reference files > 100 lines
✅ Write detailed description with trigger keywords
✅ Test with 3+ real scenarios before documenting
✅ Iterate based on actual usage

---

## Priority Levels

`priority` decides which heading a matched skill appears under in the injected
reminder. It does not change enforcement — everything is a suggestion.

| Priority   | Heading in the injected block     |
| ---------- | --------------------------------- |
| `critical` | ⚠️ CRITICAL SKILLS (REQUIRED)      |
| `high`     | 📚 RECOMMENDED SKILLS              |
| `medium`   | 💡 SUGGESTED SKILLS (the default)  |
| `low`      | 📌 OPTIONAL SKILLS                 |

An entry with no `priority` is treated as `medium`.

---

## Turning Activation Off

There is no per-skill skip marker, session state, or opt-out environment
variable — the hook is stateless and holds no memory between prompts. To stop a
skill being suggested, remove or narrow its entry in `skill-rules.json`. To
disable activation entirely, remove the rules files (or the
`skill-activation.sh` entry from `hooks.json`).

Because the hook re-evaluates every prompt independently, a skill whose keywords
match a long-running topic will be suggested on *every* turn of that
conversation. If that is noisy, tighten the keywords or move the concept into an
`intentPatterns` regex.

---

## Testing Checklist

When creating a new skill, verify:

- [ ] Skill file created at `{skills-dir}/{name}/SKILL.md`
- [ ] Proper frontmatter with name and description
- [ ] Entry added to `skill-rules.json` under `skills`
- [ ] Skill name matches what the Skill tool expects (plugin-qualified if a plugin skill)
- [ ] Keywords tested with real prompts
- [ ] Intent patterns tested with variations
- [ ] Priority level matches importance
- [ ] No false positives in testing
- [ ] No false negatives in testing
- [ ] JSON syntax validated: `jq . skill-rules.json`
- [ ] **SKILL.md under 500 lines** ⭐
- [ ] Reference files created if needed
- [ ] Table of contents added to files > 100 lines

---

## Reference Files

For detailed information on specific topics, see:

### [TRIGGER_TYPES.md](TRIGGER_TYPES.md)
Complete guide to the supported trigger types:
- Keyword triggers (explicit topic matching)
- Intent patterns (implicit action detection)
- Best practices and examples for each
- Common pitfalls and testing strategies

### [SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md)
Complete skill-rules.json schema:
- Field-by-field explanations
- Complete guardrail and domain examples
- Validation guide and common errors

### [HOOK_MECHANISMS.md](HOOK_MECHANISMS.md)
Deep dive into hook internals:
- The UserPromptSubmit flow, step by step
- How the rules layers are merged
- Exit code and output-stream behaviour
- Performance considerations

### [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
Debugging guide:
- Skill not triggering
- False positives (too many triggers)
- Hook not executing at all
- Performance issues

### [PATTERNS_LIBRARY.md](PATTERNS_LIBRARY.md)
Ready-to-use pattern collection:
- Intent pattern library (regex)
- Keyword library
- Organized by use case, copy-paste ready

### [ADVANCED.md](ADVANCED.md)
Future enhancements and ideas:
- Dynamic rule updates
- Skill dependencies
- Skill analytics
- Skill versioning

---

## Quick Reference Summary

### Create New Skill (5 Steps)

1. Create `{skills-dir}/{name}/SKILL.md` with frontmatter
2. Add an entry to `skill-rules.json`
3. Test with `echo '{"prompt":"..."}' | bash .../skill-activation.sh`
4. Refine patterns based on testing
5. Keep SKILL.md under 500 lines

### Trigger Types

- **Keywords**: explicit topic mentions (case-insensitive substring)
- **Intent patterns**: implicit action detection (case-insensitive regex)

See [TRIGGER_TYPES.md](TRIGGER_TYPES.md) for complete details.

### Anthropic Best Practices

✅ **500-line rule**: Keep SKILL.md under 500 lines
✅ **Progressive disclosure**: Use reference files for details
✅ **Table of contents**: Add to reference files > 100 lines
✅ **One level deep**: Don't nest references deeply
✅ **Rich descriptions**: Include all trigger keywords (max 1024 chars)
✅ **Test first**: Build 3+ evaluations before extensive documentation
✅ **Gerund naming**: Prefer verb + -ing (e.g., "processing-pdfs")

### Troubleshoot

Test the hook manually:
```bash
echo '{"prompt":"test"}' | bash plugins/coordkit/scripts/skill-activation.sh
```

See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for the complete debugging guide.

---

## Related Files

**Configuration:**
- `~/.claude/skills/skill-rules.json` - global rules
- `<project>/.claude/skills/skill-rules.json` - project rules (override global)
- `plugins/coordkit/templates/skill-rules.example.json` - starting template
- `plugins/coordkit/hooks/hooks.json` - hook registration

**Hook:**
- `plugins/coordkit/scripts/skill-activation.sh` - UserPromptSubmit, suggest-only

**Skill content:**
- `{skills-dir}/*/SKILL.md`
