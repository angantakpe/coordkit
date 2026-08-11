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

# Regression coverage for commit 5ed99c5 ("fix bootstrap.sh dist-copy
# drift-check false positive"): before that fix, the loop above did an
# unconditional `cmp -s core/scripts/X.sh scripts/X.sh` for EVERY *.sh dist
# wrapper. Since "collapse duplicate coordkit wrappers" (2c0a2fd) made every
# plugins/coordkit/scripts/*.sh a templated delegating wrapper — never
# byte-identical to its core/scripts counterpart — that plain cmp always
# failed, a false positive on every .sh wrapper including bootstrap.sh (the
# catch-all `exec bash core/scripts/bootstrap.sh "$@"` template, no special
# case like common.sh/bus.sh/guard.sh). Assert directly that bootstrap.sh's
# dist copy is NOT byte-identical to its core script — proving this test file
# exercises the exact condition that used to false-positive, so a regression
# back to plain `cmp -s` for .sh files would fail this assertion immediately.
! cmp -s "$PLUGIN/scripts/core/scripts/bootstrap.sh" "$PLUGIN/scripts/bootstrap.sh" || {
  printf 'expected plugins/coordkit/scripts/bootstrap.sh to be a templated wrapper, not byte-identical to core/scripts/bootstrap.sh (5ed99c5 regression?)\n' >&2
  exit 1
}

# Behavioral check for the bus.sh/guard.sh dual-mode wrapper (COORD-0001,
# commit 3030519). The drift-check loop above only compares the wrapper's
# TEXT against the expected template — it can't catch the wrapper actually
# *misbehaving* when sourced, which is exactly how the original bug hid: an
# unconditional `exec` silently replaced the SOURCING shell's own process
# (adapters/codex/hook.sh does `. scripts/guard.sh` / `. scripts/bus.sh`),
# so guard_check/guard_record_files/bus_run were never defined and the
# anti-clobber guard + read-set fingerprinting silently no-opped.
#
# Source both dist wrappers exactly the way hook.sh does, from a throwaway
# script, and assert: (1) the functions they exist to define actually land
# in the sourcing shell's scope, and (2) the sourcing shell is still alive
# afterward — proven by a marker printed AFTER the `.` lines, which would
# never print if sourcing had exec-replaced the process instead.
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

# Direct execution (cbus/cobus: `exec bus.sh <phase>`) must still behave
# exactly like invoking core/scripts/*.sh directly — the dual-mode branch
# must not have broken the top-level-script path while fixing the sourced one.
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
