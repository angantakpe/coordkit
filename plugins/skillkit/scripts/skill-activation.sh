#!/usr/bin/env bash
# skillkit — skill auto-activation engine (UserPromptSubmit hook)
#
# Ported from claude-code-infrastructure-showcase's skill-activation-prompt.ts
# (npx tsx per prompt) to dependency-free bash+jq, and extended with layered
# rules resolution:
#
#   1. global   ~/.claude/skills/skill-rules.json
#   2. project  $CLAUDE_PROJECT_DIR/.claude/skills/skill-rules.json
#
# Both files use the same schema; a project entry overrides the global entry
# of the same skill name. Matching is suggest-only: stdout is injected as
# context for the turn. This hook never blocks anything (coordkit-marketplace
# WARN-only philosophy).
#
# skill-rules.json shape (per skill):
#   {
#     "skills": {
#       "<skill-name-as-invocable-by-Skill-tool>": {
#         "type": "domain" | "guardrail",
#         "enforcement": "suggest",           # reserved; v1 is suggest-only
#         "priority": "critical|high|medium|low",
#         "description": "...",
#         "promptTriggers": {
#           "keywords": ["substring", ...],           # case-insensitive
#           "intentPatterns": ["regex", ...]          # case-insensitive
#         }
#       }
#     }
#   }
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat) || exit 0
prompt=$(jq -r '.prompt // empty' <<<"$input" 2>/dev/null) || exit 0
[[ -z "$prompt" ]] && exit 0
# Slash commands already name their skill — nothing to suggest.
[[ "$prompt" == /* ]] && exit 0

prompt_lc="${prompt,,}"

global_rules="${HOME}/.claude/skills/skill-rules.json"
project_rules="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/skills/skill-rules.json"

files=()
[[ -f "$global_rules" ]] && files+=("$global_rules")
[[ -f "$project_rules" && "$project_rules" != "$global_rules" ]] && files+=("$project_rules")
[[ ${#files[@]} -eq 0 ]] && exit 0

jq -rs --arg p "$prompt_lc" '
  (map(.skills // {}) | add // {}) as $skills
  | [ $skills | to_entries[]
      | select(
          ((.value.promptTriggers.keywords // [])
            | any(. as $kw | ($p | contains($kw | ascii_downcase))))
          or
          ((.value.promptTriggers.intentPatterns // [])
            | any(. as $re | (try ($p | test($re; "i")) catch false)))
        )
      | {name: .key, priority: (.value.priority // "medium")}
    ]
  | if length == 0 then empty else
      def bucket($pri; $hdr):
        [.[] | select(.priority == $pri) | "  → " + .name] as $rows
        | if ($rows | length) > 0 then $hdr + "\n" + ($rows | join("\n")) + "\n\n" else "" end;
      "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
      + "🎯 SKILL ACTIVATION CHECK (skillkit)\n"
      + "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"
      + bucket("critical"; "⚠️ CRITICAL SKILLS (REQUIRED):")
      + bucket("high";     "📚 RECOMMENDED SKILLS:")
      + bucket("medium";   "💡 SUGGESTED SKILLS:")
      + bucket("low";      "📌 OPTIONAL SKILLS:")
      + "ACTION: Invoke the matching Skill tool BEFORE responding\n"
      + "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    end
' "${files[@]}" 2>/dev/null

exit 0
