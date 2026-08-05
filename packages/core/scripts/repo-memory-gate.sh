#!/usr/bin/env bash
# shellcheck shell=bash
# Filter memory candidates to the active repository boundary before any semantic
# retrieval runs. Future memory loaders can pipe candidate NDJSON through this
# gate so cross-repo notes never reach the model.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_ROOT="${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}"
# shellcheck source=./common.sh
. "${SCRIPT_ROOT}/scripts/common.sh" 2>/dev/null || exit 0

mode="${1:-filter}"
case "$mode" in
  --identity|identity)
    shift || true
    cwd="${1:-$(ck_project_dir)}"
    task="${2:-}"
    ck_repo_identity_json "$cwd" "$task"
    exit 0
    ;;
esac

cwd="${1:-$(ck_project_dir)}"
task="${2:-}"
input="$(cat)"
[ -n "$input" ] || exit 0

while IFS= read -r row; do
  [ -n "$row" ] || continue
  ck_repo_memory_gate "$row" "$cwd" "$task" && printf '%s\n' "$row"
done <<< "$input"

exit 0
