#!/usr/bin/env bash
# shellcheck shell=bash
# Default plugin hook entrypoint shared by Claude Code and Codex. Codex exposes
# PLUGIN_ROOT (and a CLAUDE_PLUGIN_ROOT compatibility alias); Claude Code exposes
# CLAUDE_PLUGIN_ROOT. Keep host-specific payload translation in its adapter.
set -uo pipefail

phase="${1:-}"
input="$(cat)"
ROOT="${COORDKIT_PLUGIN_ROOT:-${PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}"

[ -f "${ROOT}/scripts/swarm.sh" ] || exit 0

if [ -n "${PLUGIN_ROOT:-}" ] || [ "${COORDKIT_HOST:-}" = codex ]; then
  printf '%s' "$input" | bash "${ROOT}/adapters/codex/hook.sh" "$phase"
  exit 0
fi

export COORDKIT_PLUGIN_ROOT="$ROOT"
export COORDKIT_HOST="${COORDKIT_HOST:-claude-code}"

case "$phase" in
  prompt-submit)
    printf '%s' "$input" | bash "${ROOT}/scripts/swarm.sh" prompt-submit
    # Skill auto-activation is a Claude compatibility feature. Codex performs
    # native skill selection and therefore never pays for this second context.
    printf '%s' "$input" | bash "${ROOT}/scripts/skill-activation.sh"
    ;;
  subagent-start|subagent-stop)
    # Claude's Task tool phases below already track subagents; avoid duplicates
    # if a newer Claude host also recognizes the native Codex event names.
    ;;
  *)
    printf '%s' "$input" | bash "${ROOT}/scripts/swarm.sh" "$phase"
    ;;
esac

exit 0
