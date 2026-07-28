# Changelog

All notable changes to **skillkit** are documented here. This project follows
[Semantic Versioning](https://semver.org/).

## 1.0.2

### Fixed
- **Hook has no timeout bound.** `hooks/hooks.json`'s `UserPromptSubmit` hook
  (`skill-activation.sh`) had no `timeout`, so a slow jq or a wedged process
  could stall every prompt indefinitely. Added `"timeout": 5`.

## 1.0.1

### Fixed
- **`agents/README.md` was loading as a phantom agent.** The plugin loader
  treats every `.md` file in `agents/` as an agent definition; the
  documentation README had no frontmatter, so it surfaced as a selectable
  agent named "README" with empty metadata (confirmed via
  `claude plugin details skillkit@coordkit-marketplace`). Removed — agent
  documentation lives in the plugin's top-level `README.md` instead.

## 1.0.0

Initial release — the claude-code-infrastructure-showcase auto-activation
system, integrated into the coordkit-marketplace as a first-class plugin.

### Added
- **Skill auto-activation engine** (`scripts/skill-activation.sh`,
  UserPromptSubmit): matches prompts against `skill-rules.json` keyword +
  intent-pattern triggers and injects grouped-by-priority skill reminders.
  Ported from the showcase's `npx tsx` implementation to dependency-free
  bash + jq (single jq pass per prompt; exits silently if jq is absent, the
  prompt is a slash command, or no rules file exists).
- **Layered rules resolution**: `~/.claude/skills/skill-rules.json` (global)
  merged with `<project>/.claude/skills/skill-rules.json` (project overrides
  global per skill name). The showcase supported project-only.
- **10 agents** copied verbatim from the showcase (architecture review,
  refactoring, documentation, error-fixing, auth-route testing/debugging,
  web research).
- **3 commands**: `dev-docs`, `dev-docs-update` (three-file task docs that
  survive context resets), `route-research-for-testing`.
- **skill-developer meta-skill** (7 resource files): skill authoring, the
  500-line modular rule, trigger design, `skill-rules.json` reference.
- `templates/skill-rules.example.json` starter rules file.

### Not carried over (deliberately)
- `post-tool-use-tracker.sh` — overlaps coordkit's PostToolUse file tracking.
- Stop-hook build checkers (`tsc-check`, `trigger-build-resolver`,
  `stop-build-check-enhanced`, `error-handling-reminder`) — TypeScript-
  monorepo-specific; candidates for a future opt-in plugin.
- `backend-dev-guidelines` / `frontend-dev-guidelines` / `route-tester` /
  `error-tracking` skills — Express/Prisma/MUI teaching content, per-project
  material rather than global.
