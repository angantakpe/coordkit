#!/usr/bin/env bash
# shellcheck shell=bash
# Codex hook adapter. It translates Codex-native hook payloads into the compact
# Claude-compatible event contract consumed by the shared swarm.sh runtime.
set -uo pipefail

phase="${1:-}"
input="$(cat)"

ROOT="${PLUGIN_ROOT:-${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}}}"
[ -f "${ROOT}/scripts/swarm.sh" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$cwd" ] || cwd="$PWD"
[ -n "$sid" ] || sid="codex-nosession"

export COORDKIT_PLUGIN_ROOT="$ROOT"
export CODEX_PLUGIN_ROOT="$ROOT"
export COORDKIT_HOST="codex"
export COORDKIT_PROJECT_DIR="$cwd"
export CODEX_PROJECT_DIR="$cwd"
export COORDKIT_SESSION_ID="$sid"
export CODEX_SESSION_ID="$sid"
if [ -n "${PLUGIN_DATA:-}" ]; then
  export COORDKIT_PLUGIN_DATA="$PLUGIN_DATA"
  export CODEX_PLUGIN_DATA="$PLUGIN_DATA"
fi

run_coord() { # <phase> <json>
  printf '%s' "$2" | bash "${ROOT}/scripts/swarm.sh" "$1"
}

emit_context() { # <Codex event> <zero or more NDJSON blobs on stdin>
  local event="$1" ctx
  ctx="$(jq -Rrs '
    split("\n")
    | map(select(length > 0) | (try fromjson catch null))
    | map(select(type == "object") | .hookSpecificOutput.additionalContext // empty)
    | map(select(length > 0))
    | join("\n")
  ' 2>/dev/null)"
  [ -n "$ctx" ] || return 0
  jq -nc --arg ev "$event" --arg ctx "$ctx" \
    '{hookSpecificOutput:{hookEventName:$ev,additionalContext:$ctx}}'
}

absolute_path() { # <path>
  local path="$1" dir base
  case "$path" in
    /*) ;;
    *) path="${cwd%/}/$path" ;;
  esac
  dir="$(dirname "$path")"; base="$(basename "$path")"
  if [ -d "$dir" ]; then
    dir="$(cd "$dir" 2>/dev/null && pwd)" || true
    printf '%s/%s' "$dir" "$base"
  else
    printf '%s' "$path"
  fi
}

patch_paths() {
  printf '%s' "$input" \
    | jq -r '.tool_input.command // empty' 2>/dev/null \
    | sed -nE 's/^\*\*\* (Add|Update|Delete) File: //p; s/^\*\*\* Move to: //p' \
    | awk 'NF && !seen[$0]++' \
    | while IFS= read -r path; do absolute_path "$path"; printf '\n'; done
}

record_guard_reads() {
  local file
  [ "$#" -gt 0 ] || return 0
  ROOT="$ROOT" CODEX_PLUGIN_ROOT="$ROOT" COORDKIT_PLUGIN_ROOT="$ROOT" \
    COORDKIT_HOST="codex" COORDKIT_PROJECT_DIR="$cwd" CODEX_PROJECT_DIR="$cwd" \
    COORDKIT_SESSION_ID="$sid" CODEX_SESSION_ID="$sid" \
    bash -s -- "$@" <<'EOF'
set -uo pipefail
ROOT="${COORDKIT_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}}}"
[ -f "${ROOT}/scripts/guard.sh" ] || exit 0
# shellcheck source=../scripts/common.sh
. "${ROOT}/scripts/common.sh" 2>/dev/null || exit 0
# shellcheck source=../scripts/guard.sh
. "${ROOT}/scripts/guard.sh" 2>/dev/null || exit 0
ev="$(jq -nc --arg cwd "$COORDKIT_PROJECT_DIR" --arg sid "$COORDKIT_SESSION_ID" \
  '{session_id:$sid,cwd:$cwd,tool_input:{}}' 2>/dev/null)" || exit 0
guard_record_files "$ev" "$@" >/dev/null
EOF
}

run_write_batch() { # <pre|post> <absolute-path>...
  local write_phase="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  ROOT="$ROOT" CODEX_PLUGIN_ROOT="$ROOT" COORDKIT_PLUGIN_ROOT="$ROOT" \
    COORDKIT_HOST="codex" COORDKIT_PROJECT_DIR="$cwd" CODEX_PROJECT_DIR="$cwd" \
    COORDKIT_SESSION_ID="$sid" CODEX_SESSION_ID="$sid" \
    bash -s -- "$write_phase" "$@" <<'EOF'
set -uo pipefail
phase="$1"; shift
ROOT="${COORDKIT_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." 2>/dev/null && pwd)}}}"
[ -f "${ROOT}/scripts/common.sh" ] || exit 0
. "${ROOT}/scripts/common.sh" 2>/dev/null || exit 0
. "${ROOT}/scripts/bus.sh" 2>/dev/null || exit 0
. "${ROOT}/scripts/guard.sh" 2>/dev/null || exit 0
files_json="$(jq -nc '$ARGS.positional' --args -- "$@" 2>/dev/null)" || files_json='[]'
batch_ev="$(jq -nc --arg cwd "$COORDKIT_PROJECT_DIR" --arg sid "$COORDKIT_SESSION_ID" --argjson files "$files_json" \
  '{session_id:$sid,cwd:$cwd,tool_name:"Edit",tool_input:{file_paths:$files},coordkit_adapter:"codex"}' \
  2>/dev/null)" || exit 0
if [ "$phase" = "pre" ]; then
  if [ "$(ck_enforcement_mode)" = "guard" ]; then
    for file in "$@"; do
      [ -n "$file" ] || continue
      ev="$(jq -nc --arg cwd "$COORDKIT_PROJECT_DIR" --arg sid "$COORDKIT_SESSION_ID" --arg file "$file" \
        '{session_id:$sid,cwd:$cwd,tool_name:"Edit",tool_input:{file_path:$file},coordkit_adapter:"codex"}' \
        2>/dev/null)" || continue
      guard_check "$ev" || exit 0
    done
  fi
  bus_run check-batch <<<"$batch_ev"
else
  guard_record_files "$batch_ev" "$@" >/dev/null
  bus_run record-batch <<<"$batch_ev" >/dev/null
fi
EOF
}

emit_pretool_results() {
  local raw="$1" deny
  [ -n "$raw" ] || return 0
  deny="$(printf '%s\n' "$raw" | jq -Rrs '
    split("\n") | map(select(length > 0) | (try fromjson catch null))
    | map(select(type == "object" and .hookSpecificOutput.permissionDecision == "deny"))
    | first // empty
  ' 2>/dev/null)"
  if [ -n "$deny" ]; then
    printf '%s\n' "$deny"
    return 0
  fi
  printf '%s\n' "$raw" | jq -Rrs '
    split("\n") | map(select(length > 0) | (try fromjson catch null))
    | map(select(type == "object")) as $rows
    | [$rows[].systemMessage // empty] | map(select(length > 0)) | join("\n") as $sys
    | [$rows[].hookSpecificOutput.additionalContext // empty] | map(select(length > 0)) | join("\n") as $ctx
    | if ($sys == "" and $ctx == "") then empty
      else ({hookSpecificOutput:{hookEventName:"PreToolUse"}}
            + (if $sys == "" then {} else {systemMessage:$sys} end)
            | .hookSpecificOutput += (if $ctx == "" then {} else {additionalContext:$ctx} end))
      end
  ' 2>/dev/null
}

case "$phase" in
  session-start)
    run_coord session-start "$input" | emit_context SessionStart
    ;;
  prompt-submit)
    run_coord prompt-submit "$input" | emit_context UserPromptSubmit
    ;;
  pretool-bash)
    run_coord pretool-bash "$input" >/dev/null
    ;;
  posttool-bash)
    run_coord posttool-bash "$input" >/dev/null
    # A Codex file read normally happens inside Bash. Record explicit file
    # arguments from conservative read-only commands so guard mode has a real
    # "last observed" fingerprint instead of denying every first patch forever.
    if command -v python3 >/dev/null 2>&1; then
      mapfile -t read_paths < <(printf '%s' "$input" | python3 "${ROOT}/adapters/codex/extract-read-paths.py" 2>/dev/null)
      [ "${#read_paths[@]}" -gt 0 ] && record_guard_reads "${read_paths[@]}"
    fi
    ;;
  pretool-write)
    mapfile -t write_paths < <(patch_paths)
    results="$(run_write_batch pre "${write_paths[@]}")"
    emit_pretool_results "$results"
    ;;
  posttool-write)
    # Known failure shapes are skipped; unknown host response shapes remain
    # fail-open and are recorded from the actual on-disk result.
    if printf '%s' "$input" | jq -e '
      .tool_response.isError == true or .tool_response.is_error == true or .tool_response.success == false
    ' >/dev/null 2>&1; then
      exit 0
    fi
    mapfile -t write_paths < <(patch_paths)
    run_write_batch post "${write_paths[@]}" >/dev/null
    ;;
  subagent-start)
    ev="$(printf '%s' "$input" | jq -c '
      .tool_use_id = (.agent_id // .tool_use_id // "")
      | .tool_input = {
          subagent_type:(.agent_type // "codex"),
          description:(.description // ("Codex subagent " + (.agent_id // "")))
        }
      | .coordkit_adapter = "codex"
    ' 2>/dev/null)"
    out="$(run_coord pretool-task "$ev")"
    printf '%s\n' "$out" | emit_context SubagentStart
    ;;
  subagent-stop)
    ev="$(printf '%s' "$input" | jq -c '
      .tool_use_id = (.agent_id // .tool_use_id // "")
      | .tool_input = {subagent_type:(.agent_type // "codex")}
      | .coordkit_adapter = "codex"
    ' 2>/dev/null)"
    run_coord posttool-task "$ev" >/dev/null
    ;;
  session-end)
    run_coord session-end "$input" >/dev/null
    ;;
  *) ;;
esac

exit 0
