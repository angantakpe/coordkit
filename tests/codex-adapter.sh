#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-codex-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
trap 'status=$?; printf "codex-adapter: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR
git -C "$tmp" init -q
printf 'alpha\n' > "$tmp/demo.txt"

hook() {
  local phase="$1" payload="$2"
  PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$tmp/plugin-data" \
    bash "$PLUGIN/adapters/hook.sh" "$phase" <<<"$payload"
}

start="$(jq -nc --arg cwd "$tmp" '{session_id:"codex-one",cwd:$cwd,hook_event_name:"SessionStart",source:"startup",model:"test"}')"
hook session-start "$start" >/dev/null
jq -e '.host == "codex" and .sid == "codex-one"' "$tmp/.coordkit-bus/agents/codex-one.json" >/dev/null
jq -e '
  .schema_version == 2
  and (.agents | length) == 10
  and ([.agents[] | select(.role_type == "orchestration")] | length) == 5
  and ([.agents[] | select(.role_type == "system")] | length) == 5
' "$tmp/plugin-data/agents/catalog.json" >/dev/null
test ! -e "$tmp/plugin-data/agents/catalog.error.json"
COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/plugin-data" \
  COORDKIT_PROJECT_DIR="$tmp" COORDKIT_SESSION_ID=codex-one COORDKIT_HOST=codex \
  bash "$PLUGIN/scripts/ledger.sh" note "host identity" >/dev/null
jq -e '.host == "codex" and .sid == "codex-one"' "$tmp/.coordkit-bus/ledger.jsonl" >/dev/null

read_event="$(jq -nc --arg cwd "$tmp" '{session_id:"codex-one",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Bash",tool_use_id:"read-one",tool_input:{command:"sed -n '\''1,20p'\'' demo.txt"},tool_response:{success:true}}')"
COORDKIT_ENFORCEMENT=guard hook posttool-bash "$read_event" >/dev/null

# Hook work must scale with batches rather than re-entering the dispatcher for
# every tracked/read/edited file. Keep this gate below the host's 10s timeout.
batch_files=()
for i in $(seq 1 32); do
  printf 'batch-%s\n' "$i" > "$tmp/batch-$i.txt"
  batch_files+=("batch-$i.txt")
done
batch_read_cmd="cat ${batch_files[*]}"
batch_pre_bash="$(jq -nc --arg cwd "$tmp" --arg command "$batch_read_cmd" \
  '{session_id:"codex-one",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Bash",tool_use_id:"batch-bash",tool_input:{command:$command}}')"
batch_post_bash="$(jq -nc --arg cwd "$tmp" --arg command "$batch_read_cmd" \
  '{session_id:"codex-one",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Bash",tool_use_id:"batch-bash",tool_input:{command:$command},tool_response:{success:true}}')"
PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$tmp/plugin-data" COORDKIT_ENFORCEMENT=guard \
  timeout 5 bash "$PLUGIN/adapters/hook.sh" pretool-bash <<<"$batch_pre_bash" >/dev/null
PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$tmp/plugin-data" COORDKIT_ENFORCEMENT=guard \
  timeout 5 bash "$PLUGIN/adapters/hook.sh" posttool-bash <<<"$batch_post_bash" >/dev/null

batch_patch='*** Begin Patch'
for i in $(seq 1 24); do
  batch_patch+=$'\n*** Update File: batch-'"$i"'.txt'
done
batch_patch+=$'\n*** End Patch'
batch_pre_write="$(jq -nc --arg cwd "$tmp" --arg command "$batch_patch" \
  '{session_id:"codex-one",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"apply_patch",tool_use_id:"batch-write",tool_input:{command:$command}}')"
batch_post_write="$(jq -nc --arg cwd "$tmp" --arg command "$batch_patch" \
  '{session_id:"codex-one",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"apply_patch",tool_use_id:"batch-write",tool_input:{command:$command},tool_response:{success:true}}')"
test -z "$(PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$tmp/plugin-data" COORDKIT_ENFORCEMENT=warn \
  timeout 5 bash "$PLUGIN/adapters/hook.sh" pretool-write <<<"$batch_pre_write")"
PLUGIN_ROOT="$PLUGIN" PLUGIN_DATA="$tmp/plugin-data" COORDKIT_ENFORCEMENT=warn \
  timeout 5 bash "$PLUGIN/adapters/hook.sh" posttool-write <<<"$batch_post_write" >/dev/null

patch_event="$(jq -nc --arg cwd "$tmp" '{session_id:"codex-one",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"apply_patch",tool_use_id:"patch-one",tool_input:{command:"*** Begin Patch\n*** Update File: demo.txt\n@@\n-alpha\n+beta\n*** End Patch"}}')"
test -z "$(COORDKIT_ENFORCEMENT=guard hook pretool-write "$patch_event")"

printf 'external\n' > "$tmp/demo.txt"
denied="$(COORDKIT_ENFORCEMENT=guard hook pretool-write "$patch_event")"
printf '%s' "$denied" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

claude_start="$(jq -nc --arg cwd "$tmp" '{session_id:"claude-two",cwd:$cwd,hook_event_name:"SessionStart"}')"
CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$tmp/plugin-data" \
  bash "$PLUGIN/scripts/swarm.sh" session-start <<<"$claude_start" >/dev/null
claude_edit="$(jq -nc --arg cwd "$tmp" --arg file "$tmp/demo.txt" '{session_id:"claude-two",cwd:$cwd,hook_event_name:"PostToolUse",tool_name:"Edit",tool_input:{file_path:$file}}')"
CLAUDE_PLUGIN_ROOT="$PLUGIN" CLAUDE_PLUGIN_DATA="$tmp/plugin-data" \
  bash "$PLUGIN/scripts/swarm.sh" posttool-write <<<"$claude_edit" >/dev/null
warning="$(COORDKIT_ENFORCEMENT=warn hook pretool-write "$patch_event")"
printf '%s' "$warning" | jq -e '.hookSpecificOutput.additionalContext | contains("host=claude-code")' >/dev/null
printf '%s' "$warning" | jq -e '.hookSpecificOutput.additionalContext | contains("Use $coordkit")' >/dev/null

sub_start="$(jq -nc --arg cwd "$tmp" '{session_id:"codex-one",cwd:$cwd,hook_event_name:"SubagentStart",turn_id:"turn",agent_id:"agent-123",agent_type:"explorer"}')"
hook subagent-start "$sub_start" >/dev/null
test -f "$tmp/.coordkit-bus/subagents/codex-one/agent-123.json"
sub_stop="$(jq -nc --arg cwd "$tmp" '{session_id:"codex-one",cwd:$cwd,hook_event_name:"SubagentStop",turn_id:"turn",agent_id:"agent-123",agent_type:"explorer"}')"
hook subagent-stop "$sub_stop" >/dev/null
test ! -f "$tmp/.coordkit-bus/subagents/codex-one/agent-123.json"

hook session-end "$(jq -nc --arg cwd "$tmp" '{session_id:"codex-one",cwd:$cwd,hook_event_name:"SessionEnd",reason:"other"}')" >/dev/null
test ! -f "$tmp/.coordkit-bus/agents/codex-one.json"

echo "codex adapter: ok"
