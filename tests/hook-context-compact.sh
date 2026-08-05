#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-hook-context-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q

export COORDKIT_PLUGIN_ROOT="$PLUGIN"
export COORDKIT_PROJECT_DIR="$tmp"
export COORDKIT_BUS_ROOT="$tmp"
export COORDKIT_PLUGIN_DATA="$tmp/plugin-data"
export COORDKIT_CONTEXT_MODE=compact
export COORDKIT_CONTEXT_MAX_PEERS=5
export COORDKIT_CONTEXT_MAX_MESSAGES=3
export COORDKIT_CONTEXT_EVENT_BODY_CHARS=40
export COORDKIT_CONTEXT_REPEAT_TTL_SECONDS=900
export COORDKIT_CONTEXT_METRICS_MAX_BYTES=512

mkdir -p "$tmp/.coordkit-bus/agents"
now="$(date +%s)"
for n in 1 2 3 4 5 6 7 8; do
  jq -n --arg sid "peer-${n}" --arg br "feature-${n}" --argjson ts "$now" \
    --arg file1 "src/a-${n}" --arg file2 "src/b-${n}" \
    --arg task "peer task ${n} with deliberately verbose details that must be shortened" \
    '{sid:$sid,host:"codex",branch:$br,cwd:"/private/path/that/must/not/be/injected",task:$task,files:[$file1, $file2],last_seen:$ts}' \
    > "$tmp/.coordkit-bus/agents/peer-${n}.json"
done

start="$(jq -nc --arg cwd "$tmp" '{session_id:"compact-one",cwd:$cwd,hook_event_name:"SessionStart"}')"
test -z "$(bash "$PLUGIN/scripts/swarm.sh" session-start <<<"$start")"

# Invalid numeric environment values do not mask valid TOML controls.
mkdir -p "$tmp/.claude/coord"
printf '[context]\nmax_messages = 2\n' > "$tmp/.claude/coord/coord.toml"
mkdir -p "$tmp/.coordkit-bus/inbox/compact-one"
for n in 1 2 3 4; do printf 'sender: message %s with safe body\n' "$n" > "$tmp/.coordkit-bus/inbox/compact-one/${n}.msg"; done
prompt="$(jq -nc --arg cwd "$tmp" '{session_id:"compact-one",cwd:$cwd,prompt:"continue"}')"
invalid_out="$(COORDKIT_CONTEXT_MAX_MESSAGES=not-a-number bash "$PLUGIN/scripts/swarm.sh" prompt-submit <<<"$prompt")"
invalid_ctx="$(printf '%s' "$invalid_out" | jq -r '.hookSpecificOutput.additionalContext')"
test "$(printf '%s' "$invalid_ctx" | grep -o 'sender: message' | wc -l)" -eq 2
test "$(find "$tmp/.coordkit-bus/inbox/compact-one" -type f | wc -l)" -eq 2

# The merged hook cap is measured on final UTF-8 bytes, including the plugin
# prefix, and never emits a split multibyte sequence.
unicode_prompt="$(jq -nc --arg cwd "$tmp" '{session_id:"unicode-one",cwd:$cwd,prompt:"continue"}')"
mkdir -p "$tmp/.coordkit-bus/inbox/unicode-one"
printf 'sender: %s\n' "$(printf 'é%.0s' $(seq 1 400))" > "$tmp/.coordkit-bus/inbox/unicode-one/unicode.msg"
unicode_out="$(COORDKIT_CONTEXT_MODE=debug COORDKIT_CONTEXT_PROMPT_TOKENS=32 \
  COORDKIT_CONTEXT_BYTES_PER_TOKEN=1 bash "$PLUGIN/scripts/swarm.sh" prompt-submit <<<"$unicode_prompt")"
unicode_ctx="$(printf '%s' "$unicode_out" | jq -r '.hookSpecificOutput.additionalContext')"
test "$(printf '%s' "$unicode_ctx" | wc -c)" -le 32
COORDKIT_CONTEXT_MODE=debug bash "$PLUGIN/scripts/swarm.sh" session-end <<<"$unicode_prompt" >/dev/null

# Quiet mode suppresses non-critical peer summaries entirely.
quiet_start="$(jq -nc --arg cwd "$tmp" '{session_id:"quiet-one",cwd:$cwd,hook_event_name:"SessionStart"}')"
test -z "$(COORDKIT_CONTEXT_MODE=quiet bash "$PLUGIN/scripts/swarm.sh" session-start <<<"$quiet_start")"
COORDKIT_CONTEXT_MODE=quiet bash "$PLUGIN/scripts/swarm.sh" session-end <<<"$quiet_start" >/dev/null

# Same-branch peers stay informational on SessionStart, but a real overlapping
# file claim still produces a collision warning on PreToolUse.
cur_branch="$(git -C "$tmp" symbolic-ref --short HEAD)"
collision_path="$tmp/src/shared.txt"
mkdir -p "$tmp/src"
: > "$collision_path"
jq -n --argjson ts "$now" \
  --arg br "$cur_branch" \
  --arg path "$collision_path" \
  '{sid:"collision-peer",host:"claude-code",branch:$br,cwd:"/private",task:"editing",files:[$path],last_seen:$ts}' \
  > "$tmp/.coordkit-bus/agents/collision-peer.json"
collision_key="$(printf '%s' "$collision_path" | sha1sum | awk '{print $1}')"
jq -n --arg path "$collision_path" --arg sid "collision-peer" --argjson ts "$now" \
  '{path:$path,sid:$sid,ts:$ts}' > "$tmp/.coordkit-bus/claims/${collision_key}.json"
collision_event="$(jq -nc --arg cwd "$tmp" --arg file "$collision_path" \
  '{session_id:"compact-one",cwd:$cwd,hook_event_name:"PreToolUse",tool_name:"Edit",tool_use_id:"edit-one",tool_input:{file_path:$file}}')"
collision_out="$(bash "$PLUGIN/scripts/swarm.sh" pretool-write <<<"$collision_event")"
printf '%s' "$collision_out" | jq -e '.hookSpecificOutput.additionalContext | contains("CK COLLISION") or contains("collision")' >/dev/null

# Inbox delivery is capped and excess messages remain queued for the next turn.
mkdir -p "$tmp/.coordkit-bus/inbox/compact-one"
for n in 1 2 3 4 5; do printf 'sender: message %s with safe body\n' "$n" > "$tmp/.coordkit-bus/inbox/compact-one/${n}.msg"; done
prompt="$(jq -nc --arg cwd "$tmp" '{session_id:"compact-one",cwd:$cwd,prompt:"continue"}')"
prompt_out="$(bash "$PLUGIN/scripts/swarm.sh" prompt-submit <<<"$prompt")"
prompt_ctx="$(printf '%s' "$prompt_out" | jq -r '.hookSpecificOutput.additionalContext')"
test "$(printf '%s' "$prompt_ctx" | grep -o 'sender: message' | wc -l)" -eq 3
printf '%s' "$prompt_ctx" | grep -q '+2 queued'
test "$(find "$tmp/.coordkit-bus/inbox/compact-one" -type f | wc -l)" -eq 2

# Skill activation is one compact line, top-K, and suppresses each repeated
# session/skill suggestion for the configured TTL.
skill_home="$tmp/home"
mkdir -p "$skill_home/.claude/skills"
jq -n '{skills:{
  critical:{priority:"critical",promptTriggers:{keywords:["optimize"]}},
  high:{priority:"high",promptTriggers:{keywords:["optimize"]}},
  medium:{priority:"medium",promptTriggers:{keywords:["optimize"]}},
  low:{priority:"low",promptTriggers:{keywords:["optimize"]}},
  last:{priority:"low",promptTriggers:{keywords:["optimize"]}}
}}' > "$skill_home/.claude/skills/skill-rules.json"
skill_input="$(jq -nc --arg cwd "$tmp" '{session_id:"skill-one",cwd:$cwd,prompt:"please optimize this"}')"
skill_first="$(HOME="$skill_home" COORDKIT_CONTEXT_SKILL_TOP_K=3 bash "$PLUGIN/scripts/skill-activation.sh" <<<"$skill_input")"
test "$(printf '%s\n' "$skill_first" | wc -l)" -eq 1
printf '%s' "$skill_first" | grep -q 'critical'
printf '%s' "$skill_first" | grep -q 'high'
printf '%s' "$skill_first" | grep -q 'medium'
! printf '%s' "$skill_first" | grep -q 'low'
skill_second="$(HOME="$skill_home" COORDKIT_CONTEXT_SKILL_TOP_K=3 bash "$PLUGIN/scripts/skill-activation.sh" <<<"$skill_input")"
printf '%s' "$skill_second" | grep -q 'low'
printf '%s' "$skill_second" | grep -q 'last'
test -z "$(HOME="$skill_home" COORDKIT_CONTEXT_SKILL_TOP_K=3 bash "$PLUGIN/scripts/skill-activation.sh" <<<"$skill_input")"

# Metrics contain counts only (no prompt/context text) and rotate at a bounded
# size. Tiny test cap intentionally forces rotation.
metrics="$tmp/.coordkit-bus/metrics/context.ndjson"
test -s "$metrics"
jq -e 'has("bytes") and has("estimated_tokens") and has("suppressed") and has("reason")' "$metrics" >/dev/null
! grep -q 'please optimize\|sender: message\|peer task' "$metrics"
test -e "${metrics}.1"
test "$(wc -c < "$metrics")" -le 1024

echo "hook context compact: ok"
