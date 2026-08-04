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
test -f "$HOOKS"
test -x "$PLUGIN/adapters/hook.sh"
test -x "$PLUGIN/scripts/repo-memory-gate.sh"

# Spill thresholds are a last line of defence, not the context budget itself.
jq -e '
  ([.hooks.SessionStart[]?.hooks[]?.additionalContextLimit // empty] | all(. <= 800))
  and ([.hooks.UserPromptSubmit[]?.hooks[]?.additionalContextLimit // empty] | all(. <= 400))
  and ([.hooks.PreToolUse[]?.hooks[]?.additionalContextLimit // empty] | all(. <= 200))
  and ([.hooks.SessionEnd[]?.hooks[]?.timeout // empty] | all(. <= 3))
' "$HOOKS" >/dev/null

python3 /home/anga/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py "$PLUGIN" >/dev/null

echo "plugin package: ok"
