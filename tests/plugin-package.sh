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
PLUGIN_VERSION="$(jq -r '.version' "$MANIFEST")"
test "$PLUGIN_VERSION" = "$(jq -r '.version' "$PLUGIN/.claude-plugin/plugin.json")"
test -f "$HOOKS"
jq -e '
  .hooks.PreToolUse[].hooks[].command
  | test("\\$\\{COORDKIT_PLUGIN_ROOT:-\\$\\{PLUGIN_ROOT:-\\$\\{CLAUDE_PLUGIN_ROOT\\}\\}\\}")
' "$HOOKS" >/dev/null
for companion in \
  "$PLUGIN/.mcp.json" \
  "$PLUGIN/.lsp.json" \
  "$PLUGIN/monitors/monitors.json"
do
  test -f "$companion"
  jq -e . "$companion" >/dev/null
done
test -x "$PLUGIN/adapters/hook.sh"
test -x "$PLUGIN/scripts/repo-memory-gate.sh"
test -x "$PLUGIN/scripts/agent-runtime.py"
test -x "$PLUGIN/bin/coordkit-monitor"
test -x "$PLUGIN/bin/coordkit-subagent-statusline"
# Since "collapse duplicate coordkit wrappers", plugins/coordkit/scripts/*.sh
# are thin delegating wrappers (not literal copies) around
# plugins/coordkit/scripts/core/scripts/*.sh — only non-.sh runtime files
# (e.g. agent-runtime.py) are still expected to be byte-identical copies.
for runtime in "$ROOT/plugins/coordkit/scripts/core/scripts"/*; do
  name="${runtime##*/}"
  dist="$PLUGIN/scripts/$name"
  case "$name" in
    *.sh)
      case "$name" in
        common.sh)
          # Library-only: no CLI dispatch of its own, so sourcing is always safe.
          expected="$(cat <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash
script_dir="\$(cd "\$(dirname "\${BASH_SOURCE[0]:-\$0}")" && pwd)"
. "\${script_dir}/core/scripts/${name}" || exit 1
return 0 2>/dev/null || exit 0
EOF
)"
          ;;
        bus.sh|guard.sh)
          # Both executed directly (cbus/cobus: `exec bus.sh <phase>`) and
          # sourced for their functions (adapters/codex/hook.sh). `exec`ing
          # unconditionally here would replace the sourcing shell's process
          # instead of defining functions in it, so branch on whether this
          # wrapper itself was invoked as the top-level script or sourced.
          expected="$(cat <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash
script_dir="\$(cd "\$(dirname "\${BASH_SOURCE[0]:-\$0}")" && pwd)"
if [ "\${BASH_SOURCE[0]:-\$0}" = "\$0" ]; then
  exec bash "\${script_dir}/core/scripts/${name}" "\$@"
fi
. "\${script_dir}/core/scripts/${name}" || return 1
EOF
)"
          ;;
        *)
          expected="$(cat <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash
script_dir="\$(cd "\$(dirname "\${BASH_SOURCE[0]:-\$0}")" && pwd)"
exec bash "\${script_dir}/core/scripts/${name}" "\$@"
EOF
)"
          ;;
      esac
      [ -f "$dist" ] && [ "$(cat "$dist")" = "$expected" ] || {
        printf 'plugin runtime wrapper drift: plugins/coordkit/scripts/%s is not a thin wrapper delegating to core/scripts/%s\n' "$name" "$name" >&2
        exit 1
      }
      ;;
    *)
      cmp -s "$runtime" "$dist" || {
        printf 'plugin runtime drift: plugins/coordkit/scripts/core/scripts/%s != plugins/coordkit/scripts/%s\n' "$name" "$name" >&2
        exit 1
      }
      ;;
  esac
done
for protocol in "$PLUGIN/protocol"/*; do
  [ -f "$protocol" ] || continue
  case "$protocol" in
    *.json) jq -e . "$protocol" >/dev/null ;;
  esac
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

VALIDATE_PLUGIN="${VALIDATE_PLUGIN:-}"
if [ -z "$VALIDATE_PLUGIN" ] && command -v validate_plugin.py >/dev/null 2>&1; then
  VALIDATE_PLUGIN="$(command -v validate_plugin.py)"
fi

if [ -z "$VALIDATE_PLUGIN" ]; then
  for skill_root in \
    "${CODEX_HOME:-$HOME/.codex}/skills" \
    "${AGENTS_HOME:-$HOME/.agents}/skills"
  do
    [ -d "$skill_root" ] || continue
    VALIDATE_PLUGIN="$(
      find "$skill_root" \
        -path '*/plugin-creator/scripts/validate_plugin.py' \
        -type f \
        | LC_ALL=C sort \
        | head -n 1
    )"
    if [ -n "$VALIDATE_PLUGIN" ]; then
      break
    fi
  done
fi

if [ -z "$VALIDATE_PLUGIN" ] || [ ! -f "$VALIDATE_PLUGIN" ]; then
  printf 'validate_plugin.py not found; set VALIDATE_PLUGIN to a local plugin-creator validator\n' >&2
  exit 1
fi

python3 "$VALIDATE_PLUGIN" "$PLUGIN" >/dev/null

echo "plugin package: ok"
