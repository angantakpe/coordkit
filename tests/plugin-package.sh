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
  "$PLUGIN/.lsp.json"
do
  test -f "$companion"
  jq -e . "$companion" >/dev/null
done
# Each monitor line wakes the model for a full turn, so the package must not
# register one. The statusline and UserPromptSubmit hook carry this state.
jq -e '.experimental.monitors == null' "$PLUGIN/.claude-plugin/plugin.json" >/dev/null
test ! -e "$PLUGIN/monitors"
test -x "$PLUGIN/adapters/hook.sh"
test -x "$PLUGIN/scripts/repo-memory-gate.sh"
test -x "$PLUGIN/scripts/agent-runtime.py"
test -x "$PLUGIN/bin/coordkit-subagent-statusline"
# Since "collapse duplicate coordkit wrappers", plugins/coordkit/scripts/*.sh
# are thin delegating wrappers (not literal copies) around
# plugins/coordkit/scripts/core/scripts/*.sh — only non-.sh runtime files
# (e.g. agent-runtime.py) are still expected to be byte-identical copies.
for runtime in "$ROOT/plugins/coordkit/scripts/core/scripts"/*; do
  name="${runtime##*/}"
  dist="$PLUGIN/scripts/$name"
  case "$name" in
    # claude-mem drops a gitignored per-directory context stub (see .gitignore);
    # it is a session artifact, not a runtime file, so it must not fail drift.
    CLAUDE.local.md) continue ;;
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

# Shell distribution files are wrappers, not copies. Keep this assertion so a
# future byte-for-byte drift check cannot reject every valid wrapper.
! cmp -s "$PLUGIN/scripts/core/scripts/bootstrap.sh" "$PLUGIN/scripts/bootstrap.sh" || {
  printf 'expected plugins/coordkit/scripts/bootstrap.sh to be a templated wrapper, not byte-identical to core/scripts/bootstrap.sh (5ed99c5 regression?)\n' >&2
  exit 1
}

# bus.sh and guard.sh must work both as sourced libraries and direct commands.
# The marker proves sourcing did not replace the caller with `exec`.
source_probe="$(mktemp "${TMPDIR:-/tmp}/coordkit-source-probe.XXXXXX")"
cat > "$source_probe" <<PROBE
. "${PLUGIN}/scripts/guard.sh" || exit 1
. "${PLUGIN}/scripts/bus.sh" || exit 1
type guard_check >/dev/null 2>&1 || { echo "guard_check not defined after sourcing" >&2; exit 1; }
type guard_record_files >/dev/null 2>&1 || { echo "guard_record_files not defined after sourcing" >&2; exit 1; }
type bus_run >/dev/null 2>&1 || { echo "bus_run not defined after sourcing" >&2; exit 1; }
echo SOURCE_PROBE_ALIVE
PROBE
source_out="$(bash "$source_probe")"
rm -f "$source_probe"
test "$source_out" = "SOURCE_PROBE_ALIVE" || {
  printf 'sourcing plugins/coordkit/scripts/guard.sh and bus.sh did not behave as libraries (exec may have replaced the shell, or functions were not defined); got: %s\n' "$source_out" >&2
  exit 1
}

# Direct execution must still match the core scripts.
exec_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-exec-probe.XXXXXX")"
git -C "$exec_probe_dir" init -q
guard_dist_out="$(cd "$exec_probe_dir" && bash "$PLUGIN/scripts/guard.sh" status 2>&1)"
guard_core_out="$(cd "$exec_probe_dir" && bash "$PLUGIN/scripts/core/scripts/guard.sh" status 2>&1)"
test "$guard_dist_out" = "$guard_core_out" || {
  printf 'plugins/coordkit/scripts/guard.sh (direct exec) output diverged from core/scripts/guard.sh\n' >&2
  exit 1
}
bus_dist_out="$(cd "$exec_probe_dir" && bash "$PLUGIN/scripts/bus.sh" nonexistent-phase-xyz </dev/null 2>&1)"
bus_core_out="$(cd "$exec_probe_dir" && bash "$PLUGIN/scripts/core/scripts/bus.sh" nonexistent-phase-xyz </dev/null 2>&1)"
test "$bus_dist_out" = "$bus_core_out" || {
  printf 'plugins/coordkit/scripts/bus.sh (direct exec) output diverged from core/scripts/bus.sh\n' >&2
  exit 1
}
rm -rf "$exec_probe_dir"

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

python3 "$ROOT/scripts/validate-package.py" "$ROOT" >/dev/null

# Maintainers may add an external validator explicitly, but package validation
# never depends on tools installed outside this repository.
if [ -n "${VALIDATE_PLUGIN:-}" ]; then
  [ -f "$VALIDATE_PLUGIN" ] || {
    printf 'VALIDATE_PLUGIN does not name a file: %s\n' "$VALIDATE_PLUGIN" >&2
    exit 1
  }
  python3 "$VALIDATE_PLUGIN" "$PLUGIN" >/dev/null
fi

echo "plugin package: ok"
