# Troubleshooting - Skill Activation Issues

Debugging guide for coordkit's skill activation
(`plugins/coordkit/scripts/skill-activation.sh`).

## Table of Contents

- [First: The Silence Problem](#first-the-silence-problem)
- [Skill Not Triggering](#skill-not-triggering)
- [False Positives](#false-positives)
- [Hook Not Executing](#hook-not-executing)
- [Performance Issues](#performance-issues)

---

## First: The Silence Problem

Almost every failure mode here looks identical from the outside: **nothing
happens**. The hook always exits `0`, suppresses `jq`'s stderr, and prints
nothing when it has nothing to say. A missing rules file, a JSON syntax error, a
missing `jq`, and a simply-non-matching prompt are indistinguishable in normal
use.

So start every investigation by running the hook by hand, where you *can* see
the error:

```bash
echo '{"prompt":"your test prompt here"}' \
  | bash plugins/coordkit/scripts/skill-activation.sh
```

And validate the rules files directly, which is where the error will actually
be reported:

```bash
jq . ~/.claude/skills/skill-rules.json
jq . "$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json"
```

---

## Skill Not Triggering

**Symptoms:** you ask a question, but no skill suggestion appears.

### 1. Keywords Don't Match

**Check:** `promptTriggers.keywords` in `skill-rules.json`. Matching is
case-insensitive substring — no word boundaries, no stemming.

```json
"keywords": ["skill rules", "activation"]
```
- "how do the **skill rules** work?" → ✅ matches
- "how does **activation** work?" → ✅ matches
- "how do I **activate** a skill?" → ❌ no match ("activate" ≠ "activation")
- "how does it work?" → ❌ no match

**Fix:** add the variations people actually type, or cover them with an intent
pattern instead.

### 2. Intent Patterns Too Specific

**Check:** `promptTriggers.intentPatterns`. Test the regex both at
https://regex101.com/ and against the real hook.

```json
"intentPatterns": ["(create|add).*?(new skill file)"]
```
- "create a new skill file" → ✅ matches
- "add a skill" → ❌ doesn't match

**Fix:** broaden it:
```json
"intentPatterns": ["(create|add).*?skill"]
```

### 3. Invalid Regex (Fails Silently)

A pattern that doesn't compile is caught by the hook and treated as "no match".
It never raises an error. If a pattern seems inert, verify it compiles:

```bash
jq -n '"test string" | test("your(pattern")'
```

**Fix:** correct the pattern. Watch for unbalanced parentheses and brackets, and
for backslashes that need doubling inside a JSON string (`\\.` not `\.`).

### 4. Skill Name Doesn't Match the Skill Tool

The name is used verbatim in the suggestion, so a wrong name produces a
suggestion Claude cannot act on. Plugin skills need the plugin-qualified form.

```yaml
# SKILL.md
name: skill-developer
```
```json
// skill-rules.json — for a skill shipped by the coordkit plugin
"coordkit:skill-developer": { }
```

**Fix:** use exactly the name the Skill tool accepts.

### 5. JSON Syntax Error

See [First: The Silence Problem](#first-the-silence-problem). Common causes:
trailing commas, single quotes, missing quotes on keys, unescaped backslashes.

### 6. Entry in the Wrong Place

Every skill must live under the top-level `skills` object. An entry placed at
the root of the file is silently ignored.

### 7. The Prompt Was a Slash Command

The hook returns early for any prompt starting with `/` — a slash command
already names its skill. This is intended, not a bug.

### 8. Overridden by the Project Layer

A project `skill-rules.json` entry **replaces** the global entry of the same
name outright. If a global skill stopped firing in one repo, check whether that
repo's file redefines it with narrower triggers.

---

## False Positives

**Symptoms:** the skill is suggested on prompts that have nothing to do with it.

### 1. Keywords Too Generic

**Problem:**
```json
"keywords": ["user", "system", "create"]
```
Fires on "user manual", "file system", "create directory". Worse, because
matching is substring-based, `"user"` also matches "users", "superuser" and
"perused".

**Solution:** be specific, and prefer phrases.
```json
"keywords": ["user authentication", "user tracking"]
```

### 2. Intent Patterns Too Broad

**Problem:**
```json
"intentPatterns": ["(create)"]
```

**Solution:** add context.
```json
"intentPatterns": ["(create|add).*?(skill|trigger|rule)"]
```

### 3. Suggestion Noise Across a Long Conversation

The hook is stateless — it re-evaluates every prompt independently and has no
memory of what it suggested last turn. A skill matching an ongoing topic will be
suggested on *every* turn of that conversation.

**Solution:** narrow the keywords so they match the moment the skill is
genuinely needed rather than the topic in general, or drop the entry's priority
so it appears lower in the block.

### 4. Right Skill, Too Loud

If a skill is genuinely relevant but shouldn't dominate, lower its `priority`
from `critical`/`high` to `medium`/`low`. Note that lowering it does not reduce
how often it fires — only which heading it appears under.

---

## Hook Not Executing

**Symptoms:** nothing happens even for a prompt you have verified matches when
running the script by hand.

### 1. `jq` Not Installed

This is the most common cause. The hook's first act is to check for `jq` and
exit silently if it's missing.

```bash
command -v jq && jq --version
```

**Fix:** install `jq` (`apt install jq`, `brew install jq`, …).

### 2. Neither Rules File Exists

```bash
ls -l ~/.claude/skills/skill-rules.json
ls -l "$CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json"
```

**Fix:** copy the template:
```bash
cp plugins/coordkit/templates/skill-rules.example.json \
   ~/.claude/skills/skill-rules.json
```

### 3. Hook Not Registered

The hook is registered by the plugin, in
`plugins/coordkit/hooks/hooks.json`:

```bash
jq '.hooks.UserPromptSubmit' plugins/coordkit/hooks/hooks.json
```

Expected: an entry invoking `bash ${CLAUDE_PLUGIN_ROOT}/scripts/skill-activation.sh`.

**Fix:** if it's absent, the plugin install is incomplete — reinstall coordkit
rather than hand-editing settings.

### 4. Script Missing or Unreadable

```bash
ls -l plugins/coordkit/scripts/skill-activation.sh
```

The hook is invoked as `bash <script>`, so the file does not need its executable
bit set — but it does need to exist and be readable.

### 5. `CLAUDE_PROJECT_DIR` Not What You Expect

The project rules path is built from `$CLAUDE_PROJECT_DIR`, falling back to
`$PWD`. In a git worktree or a nested repo, that may not be the directory you
assume.

```bash
echo "${CLAUDE_PROJECT_DIR:-$PWD}"
```

---

## Performance Issues

**Symptoms:** a noticeable delay before each prompt is processed.

The hook runs one `jq` process and re-reads both rules files on every prompt.
`hooks.json` gives it a 5-second timeout; the target is under 100ms.

### 1. Too Many Entries or Patterns

Every entry's keywords and patterns are evaluated on every prompt.

**Solution:** prune unused skills from the rules file; combine near-duplicate
patterns; prefer keywords over regex where either would do.

### 2. Complex Regex

**Problem:**
```regex
(create|add|modify|update|implement|build).*?(feature|endpoint|route|service|controller|component|UI|page)
```
Long alternations on both sides of a wildcard backtrack badly on long prompts.

**Solution:** simplify.
```regex
(create|add).*?(feature|endpoint)
```

Avoid nested quantifiers (`(a+)+`) entirely — they are the classic catastrophic
backtracking shape, and a long pasted prompt is exactly the input that triggers it.

### Measure It

```bash
time (echo '{"prompt":"test"}' | bash plugins/coordkit/scripts/skill-activation.sh)
```

**Target:** < 100ms.

---

**Related Files:**
- [SKILL.md](SKILL.md) - Main skill guide
- [HOOK_MECHANISMS.md](HOOK_MECHANISMS.md) - How the hook works
- [SKILL_RULES_REFERENCE.md](SKILL_RULES_REFERENCE.md) - Configuration reference
