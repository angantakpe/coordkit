#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
MANIFEST="${PLUGIN}/.codex-plugin/plugin.json"
HOOKS="${PLUGIN}/hooks/hooks.json"

# Codex discovers the default hook file automatically. Keeping hooks out of the
# manifest also keeps the package compatible with the strict plugin validator.
jq -e 'has("hooks") | not' "$MANIFEST" >/dev/null
jq -e '.skills == "./skills/"' "$MANIFEST" >/dev/null
test "$(jq -r '.version' "$MANIFEST")" = "5.2.1"
test "$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")" = "5.2.1"
test -f "$HOOKS"
jq -e '
  .hooks.PreToolUse[].hooks[].command
  | test("\\$\\{COORDKIT_PLUGIN_ROOT:-\\$\\{PLUGIN_ROOT:-\\$\\{CLAUDE_PLUGIN_ROOT\\}\\}\\}")
' "$HOOKS" >/dev/null
test -x "$PLUGIN/adapters/hook.sh"
test -x "$PLUGIN/scripts/repo-memory-gate.sh"
test -x "$PLUGIN/scripts/agent-runtime.py"
for runtime in "$ROOT/packages/core/scripts"/*; do
  name="${runtime##*/}"
  cmp -s "$runtime" "$PLUGIN/scripts/$name" || {
    printf 'plugin runtime drift: packages/core/scripts/%s != plugins/coordkit/scripts/%s\n' "$name" "$name" >&2
    exit 1
  }
done
for protocol in "$ROOT/packages/protocol"/*; do
  name="${protocol##*/}"
  [ -f "$protocol" ] || continue
  cmp -s "$protocol" "$PLUGIN/protocol/$name" || {
    printf 'plugin protocol drift: packages/protocol/%s != plugins/coordkit/protocol/%s\n' "$name" "$name" >&2
    exit 1
  }
done
COORDKIT_PLUGIN_ROOT="$PLUGIN" "$PLUGIN/bin/cobus" swarm --help >/dev/null
test -f "$PLUGIN/skills/agent-orchestrator/SKILL.md"
test "$(find "$PLUGIN/agents" -maxdepth 1 -name '*.md' | wc -l)" -eq 10
test -f "$PLUGIN/agents/work-graph-planner.md"
test -f "$PLUGIN/agents/goal-verifier.md"
test -f "$PLUGIN/agents/transport-reliability-debugger.md"
test -z "$(find "$PLUGIN/agents" -maxdepth 1 -type f \( \
  -name 'auth-route-debugger.md' -o -name 'auth-route-tester.md' -o \
  -name 'auto-error-resolver.md' -o -name 'code-architecture-reviewer.md' -o \
  -name 'code-refactor-master.md' -o -name 'documentation-architect.md' -o \
  -name 'frontend-error-fixer.md' -o -name 'plan-reviewer.md' -o \
  -name 'refactor-planner.md' -o -name 'web-research-specialist.md' \
\) -print -quit)"

# Spill thresholds are a last line of defence, not the context budget itself.
jq -e '
  ([.hooks.SessionStart[]?.hooks[]?.additionalContextLimit // empty] | all(. <= 800))
  and ([.hooks.UserPromptSubmit[]?.hooks[]?.additionalContextLimit // empty] | all(. <= 400))
  and ([.hooks.PreToolUse[]?.hooks[]?.additionalContextLimit // empty] | all(. <= 200))
  and ([.hooks.SessionEnd[]?.hooks[]?.timeout // empty] | all(. <= 3))
' "$HOOKS" >/dev/null

python3 /home/anga/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py "$PLUGIN" >/dev/null

echo "plugin package: ok"
