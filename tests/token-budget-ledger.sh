#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-ledger-budget.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
trap 'status=$?; printf "token-budget-ledger: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

jq -e '
  .name == "coordkit-protocol"
  and (.entities | index("agent"))
  and (.entities | index("session"))
  and (.entities | index("event"))
  and (.entities | index("message"))
  and (.invariants | index("history is append-only"))
' "$ROOT/packages/protocol/protocol.json" >/dev/null
COORDKIT_CORE_ROOT="$ROOT/packages/core" bash -c '
  set -euo pipefail
  . "$COORDKIT_CORE_ROOT/scripts/common.sh"
  test "$(ck_protocol_root)" = "'"$ROOT/packages/protocol"'"
  test "$(ck_protocol_schema_path agent)" = "'"$ROOT/packages/protocol/agent.schema.json"'"
  test "$(ck_protocol_schema_path event)" = "'"$ROOT/packages/protocol/event.schema.json"'"
  test "$(ck_protocol_schema_path message)" = "'"$ROOT/packages/protocol/message.schema.json"'"
'
test "$(jq -r '."$id"' "$ROOT/packages/protocol/agent.schema.json")" = 'https://coordkit/schema/agent/1.0'
jq -e '.title == "coordkit agent definition" and (.required | index("name")) and (.required | index("role_type"))' \
  "$ROOT/packages/protocol/agent.schema.json" >/dev/null
test "$(jq -r '."$id"' "$ROOT/packages/protocol/event.schema.json")" = 'https://coordkit/schema/event/2.0'
jq -e '.title == "coordkit session state" and (.required | index("sid")) and (.required | index("last_seen"))' \
  "$ROOT/packages/protocol/session.schema.json" >/dev/null
jq -e '.title == "coordkit claim envelope" and (.required | index("kind")) and (.required | index("owner"))' \
  "$ROOT/packages/protocol/claim.schema.json" >/dev/null
jq -e '.title == "coordkit task projection" and (.required | index("subject")) and (.required | index("status"))' \
  "$ROOT/packages/protocol/task.schema.json" >/dev/null
jq -e '
  .["$id"] == "https://coordkit/schema/message/1.0"
  and .title == "coordkit message envelope"
  and (.required | index("sender"))
  and (.required | index("target"))
' "$ROOT/packages/protocol/message.schema.json" >/dev/null
jq -e '.title == "coordkit transport family" and (.required | index("mode")) and (.required | index("storage"))' \
  "$ROOT/packages/protocol/transport.schema.json" >/dev/null
grep -Fq '`agent` is now first-class in `packages/protocol/`' "$ROOT/packages/protocol/README.md"
grep -Fq '`message` is now a first-class protocol object' "$ROOT/packages/protocol/README.md"
grep -Fq 'packages/protocol/message.schema.json' "$ROOT/packages/protocol/README.md"
jq -e '
  .current_implementation.agent_schema == "packages/protocol/agent.schema.json"
  and .current_implementation.message_schema == "packages/protocol/message.schema.json"
  and .current_implementation.session_schema == "packages/protocol/session.schema.json"
  and .current_implementation.claim_schema == "packages/protocol/claim.schema.json"
  and .current_implementation.task_schema == "packages/protocol/task.schema.json"
  and .current_implementation.transport_schema == "packages/protocol/transport.schema.json"
' "$ROOT/packages/protocol/protocol.json" >/dev/null

git -C "$tmp" init -q
mkdir -p "$tmp/.coordkit-bus" "$tmp/.claude/coord"
printf '*\n' > "$tmp/.coordkit-bus/.gitignore"

ledger="$tmp/.coordkit-bus/ledger.jsonl"

# Stress every materialized category. Bodies are deliberately much larger than
# a useful hook payload, and the final five tasks are blocked so the governor's
# salience ordering has to lift them above the older open work.
jq -nc '
  def ev($seq; $type; $subject; $body):
    {seq:$seq,ts:1,sid:"writer",sid8:"writer01",host:"codex",branch:"main",
     type:$type,subject:$subject,body:$body,refs:[],tags:[],lease:0};
  (range(1; 41) as $i
    | ev($i; "task"; "task-\($i)"; ("task body \($i) " + ("x" * 800)))),
  (range(41; 81) as $i
    | ev($i; "decision"; "decision-\($i)"; ("decision body \($i) " + ("y" * 800)))),
  (range(81; 121) as $i
    | ev($i; "question"; "question-\($i)"; ("question body \($i) " + ("z" * 800)))),
  (range(121; 126) as $i
    | ev($i; "block"; "task-\($i - 85)"; "blocked for stress test"))
' > "$ledger"

payload() {
  jq -nc --arg cwd "$tmp" --arg sid "$1" --arg event "$2" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:$event}'
}

run_ledger() {
  local phase="$1" sid="$2" event="$3"
  shift 3
  env COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/plugin-data" \
    COORDKIT_HOST=codex "$@" bash "$PLUGIN/scripts/ledger.sh" "$phase" \
    <<<"$(payload "$sid" "$event")"
}

context_bytes() {
  jq -j '.hookSpecificOutput.additionalContext' | LC_ALL=C wc -c | tr -d ' '
}

# Top-K is independent for tasks, decisions, and questions. Use an intentionally
# large byte budget here so the category assertions test selection, not final
# truncation. Blocked work must win over open work even though it arrived last.
wide="$(run_ledger start reader-wide SessionStart \
  COORDKIT_CONTEXT_SESSION_START_TOKENS=10000 \
  COORDKIT_CONTEXT_MAX_TASKS=5 \
  COORDKIT_CONTEXT_MAX_DECISIONS=3 \
  COORDKIT_CONTEXT_MAX_QUESTIONS=3 \
  COORDKIT_CONTEXT_MAX_EVENTS=4 \
  COORDKIT_CONTEXT_EVENT_BODY_CHARS=80)"
wide_ctx="$(printf '%s' "$wide" | jq -r '.hookSpecificOutput.additionalContext')"
[ "$(printf '%s\n' "$wide_ctx" | grep -c '^    [▸~!] ' || true)" -eq 5 ]
[ "$(printf '%s\n' "$wide_ctx" | grep -c '^    • decision-' || true)" -eq 3 ]
[ "$(printf '%s\n' "$wide_ctx" | grep -c '^    • question-' || true)" -eq 3 ]
printf '%s' "$wide_ctx" | grep -q 'task-36 (BLOCKED)'
printf '%s' "$wide_ctx" | grep -Eq '\+[0-9]+ more tasks'
printf '%s' "$wide_ctx" | grep -Eq '\+[0-9]+ more decisions'
printf '%s' "$wide_ctx" | grep -Eq '\+[0-9]+ more questions'

# The default SessionStart budget is 600 estimated tokens at four bytes/token.
# This assertion is on the decoded final additionalContext, including the safety
# frame, headings, hints, and truncation marker—not an intermediate digest.
bounded="$(run_ledger start reader-bounded SessionStart)"
[ -n "$bounded" ]
[ "$(printf '%s' "$bounded" | context_bytes)" -le 2400 ]

# Append a burst containing 100 unrelated notes plus repeated state changes for
# one subject. Prompt selection must keep only the latest decision for that
# subject, cap the candidate page, and cap final context at 250*4 bytes.
jq -nc '
  def ev($seq; $type; $subject; $body):
    {seq:$seq,ts:2,sid:"peer",sid8:"peer0001",host:"claude-code",branch:"main",
     type:$type,subject:$subject,body:$body,refs:[],tags:[],lease:0};
  (range(126; 226) as $i
    | ev($i; "note"; "note-\($i)"; ("long note \($i) " + ("🧠" * 300)))),
  (range(226; 246) as $i
    | ev($i; "decision"; "same-subject"; "revision-\($i)"))
' >> "$ledger"

# Establish the reader at the old watermark, then request the burst as a delta.
mkdir -p "$tmp/.coordkit-bus/cursors"
printf '{"seq":125}\n' > "$tmp/.coordkit-bus/cursors/prompt-reader.json"
prompt="$(run_ledger prompt prompt-reader UserPromptSubmit)"
[ -n "$prompt" ]
[ "$(printf '%s' "$prompt" | context_bytes)" -le 1000 ]
prompt_ctx="$(printf '%s' "$prompt" | jq -r '.hookSpecificOutput.additionalContext')"
[ "$(printf '%s\n' "$prompt_ctx" | grep -c 'decision/same-subject' || true)" -le 1 ]
if printf '%s' "$prompt_ctx" | grep -q 'revision-244'; then
  echo "stale coalesced decision leaked into prompt context" >&2
  exit 1
fi
printf '%s' "$prompt_ctx" | grep -q 'revision-245'
printf '%s' "$prompt_ctx" | grep -Eq '\+[0-9]+ more event'

# No new peer event means no JSON and no additionalContext at all.
unchanged="$(run_ledger prompt prompt-reader UserPromptSubmit)"
[ -z "$unchanged" ]

# Query-aware retrieval should prefer a prompt-matching event over newer noise.
jq -nc '
  def ev($seq; $type; $subject; $body):
    {seq:$seq,ts:3,sid:"peer",sid8:"peer0001",host:"claude-code",branch:"main",
     type:$type,subject:$subject,body:$body,refs:[],tags:[],lease:0};
  ev(246; "decision"; "alpha-target"; "alpha target details"),
  ev(247; "decision"; "noise-one"; "unrelated noise"),
  ev(248; "decision"; "noise-two"; "unrelated noise"),
  ev(249; "decision"; "noise-three"; "unrelated noise")
' >> "$ledger"
ranked_payload="$(jq -nc --arg cwd "$tmp" --arg prompt "please use alpha target details" \
  '{session_id:"prompt-reader",cwd:$cwd,hook_event_name:"UserPromptSubmit",prompt:$prompt}')"
ranked="$(env COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/plugin-data" \
  COORDKIT_HOST=codex bash "$PLUGIN/scripts/ledger.sh" prompt <<<"$ranked_payload")"
ranked_ctx="$(printf '%s' "$ranked" | jq -r '.hookSpecificOutput.additionalContext')"
printf '%s' "$ranked_ctx" | grep -q 'decision/alpha-target'
printf '%s' "$ranked_ctx" | grep -q 'alpha target details'

# Cross-machine logstore cursors use the total-order watermark, never the
# replica-local seq. A newly arrived remote event with seq=1 must still surface
# after a reader has already consumed a local event with seq=100.
shared="$tmp/shared"
git -C "$shared" init -q 2>/dev/null || { mkdir -p "$shared"; git -C "$shared" init -q; }
mkdir -p "$shared/.coordkit-bus/log/actor-a" "$shared/.coordkit-bus/log/actor-b"
jq -nc '
  {schema_version:"2.0",eid:"sha256:wm-local",actor:"actor-a",clock:{p:100,c:1},seq:100,ts:1,
   sid:"peer-a",sid8:"peer-a",host:"codex",branch:"main",type:"decision",subject:"shared-decision",
   body:"initial-value",refs:[],tags:[],lease:null},
  {schema_version:"2.0",eid:"sha256:wm-task",actor:"actor-a",clock:{p:110,c:2},seq:101,ts:1,
   sid:"peer-a",sid8:"peer-a",host:"codex",branch:"main",type:"task",subject:"shared-task",
   body:"shared task",refs:[],tags:[],lease:null},
  {schema_version:"2.0",eid:"sha256:wm-claim",actor:"actor-a",clock:{p:120,c:3},seq:102,ts:1,
   sid:"peer-a",sid8:"peer-a",host:"codex",branch:"main",type:"claim",subject:"shared-task",
   body:"claimed",refs:[],tags:[],lease:{until:4102444800,owner:"actor-a",sid8:"peer-a"}}
' > "$shared/.coordkit-bus/log/actor-a/seg.ndjson"
shared_payload() {
  jq -nc --arg cwd "$shared" --arg sid "$1" --arg event "$2" \
    '{session_id:$sid,cwd:$cwd,hook_event_name:$event}'
}
shared_ledger() {
  local phase="$1" sid="$2" event="$3"
  COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/shared-data" \
    COORDKIT_BUS_ROOT="$shared" COORDKIT_USE_LOGSTORE=1 COORDKIT_MODE=local COORDKIT_HOST=codex \
    bash "$PLUGIN/scripts/ledger.sh" "$phase" <<<"$(shared_payload "$sid" "$event")"
}
shared_ledger start wm-reader SessionStart >/dev/null
jq -e '.watermark == "120:3:actor-a"' "$shared/.coordkit-bus/cursors/wm-reader.json" >/dev/null
jq -nc '
  {schema_version:"2.0",eid:"sha256:wm-remote",actor:"actor-b",clock:{p:200,c:1},seq:1,ts:2,
   sid:"peer-b",sid8:"peer-b",host:"claude-code",branch:"main",type:"decision",subject:"shared-decision",
   body:"remote-low-seq-wins",refs:[],tags:[],lease:null},
  {schema_version:"2.0",eid:"sha256:wm-done",actor:"actor-b",clock:{p:210,c:2},seq:2,ts:2,
   sid:"peer-b",sid8:"peer-b",host:"claude-code",branch:"main",type:"done",subject:"shared-task",
   body:"completed remotely",refs:[],tags:[],lease:null}
' > "$shared/.coordkit-bus/log/actor-b/seg.ndjson"
wm_prompt="$(shared_ledger prompt wm-reader UserPromptSubmit)"
printf '%s' "$wm_prompt" | jq -e '.hookSpecificOutput.additionalContext | contains("remote-low-seq-wins")' >/dev/null
jq -e '.seq == 102 and .watermark == "210:2:actor-b"' "$shared/.coordkit-bus/cursors/wm-reader.json" >/dev/null
shared_board="$(shared_ledger board wm-reader ignored)"
printf '%s' "$shared_board" | grep -Eq '\[x\][[:space:]]+shared-task[[:space:]]+done'

# A newly synchronized actor can carry a wall clock older than the global
# watermark. Its monotonic actor counter must still make the note visible.
mkdir -p "$shared/.coordkit-bus/log/actor-c"
jq -nc '{schema_version:"2.0",eid:"sha256:wm-late-before",actor:"actor-c",clock:{p:50,c:1},seq:1,ts:3,
  sid:"peer-c",sid8:"peer-c",host:"cli",branch:"main",type:"note",subject:"late-note",
  body:"late-before-global-watermark",refs:[],tags:[],lease:null}' > "$shared/.coordkit-bus/log/actor-c/seg.ndjson"
late_prompt="$(shared_ledger prompt wm-reader UserPromptSubmit)"
printf '%s' "$late_prompt" | jq -e '.hookSpecificOutput.additionalContext | contains("late-before-global-watermark")' >/dev/null
jq -e '.watermark == "210:2:actor-b"' "$shared/.coordkit-bus/cursors/wm-reader.json" >/dev/null
wm_fresh="$(shared_ledger start wm-fresh SessionStart)"
wm_fresh_ctx="$(printf '%s' "$wm_fresh" | jq -r '.hookSpecificOutput.additionalContext')"
printf '%s' "$wm_fresh_ctx" | grep -q 'remote-low-seq-wins'
! printf '%s' "$wm_fresh_ctx" | grep -q 'initial-value'

# Append-only read paths must survive a mix of duplicated events, raw garbage,
# and a partially written tail line without losing the valid lines around them.
mkdir -p "$shared/.coordkit-bus/log/actor-d" "$shared/.coordkit-bus/log/actor-e"
jq -nc '
  {schema_version:"2.0",eid:"sha256:append-dup",actor:"actor-d",clock:{p:300,c:1},seq:1,ts:4,
   sid:"peer-d",sid8:"peer-d",host:"codex",branch:"main",type:"note",subject:"dup-subject",
   body:"dedup-me",refs:[],tags:[],lease:null},
  {schema_version:"2.0",eid:"sha256:append-dup",actor:"actor-e",clock:{p:301,c:1},seq:2,ts:4,
   sid:"peer-e",sid8:"peer-e",host:"codex",branch:"main",type:"note",subject:"dup-subject",
   body:"dedup-me-too",refs:[],tags:[],lease:null},
  {schema_version:"2.0",eid:"sha256:append-good",actor:"actor-d",clock:{p:302,c:2},seq:3,ts:4,
   sid:"peer-d",sid8:"peer-d",host:"codex",branch:"main",type:"decision",subject:"good-subject",
   body:"still-visible",refs:[],tags:[],lease:null}
' > "$shared/.coordkit-bus/log/actor-d/seg.ndjson"
printf '%s\n' '{"schema_version":"2.0","eid":"sha256:append-garbage","id":"broken"' \
  > "$shared/.coordkit-bus/log/actor-e/seg.ndjson"
printf '%s\n' '{"schema_version":"2.0","eid":"sha256:append-garbage","id":"broken"' \
  >> "$shared/.coordkit-bus/log/actor-e/seg.ndjson"
printf '%s\n' '{"schema_version":"2.0","eid":"sha256:append-good-2","id":"ok","actor":"actor-e","clock":{"p":303,"c":1},"seq":4,"ts":4,"sid":"peer-e","sid8":"peer-e","host":"codex","branch":"main","type":"note","subject":"good-subject-2","body":"tail survives","refs":[],"tags":[],"lease":null}' \
  >> "$shared/.coordkit-bus/log/actor-e/seg.ndjson"
append_readall="$(
  COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_BUS_ROOT="$shared" COORDKIT_USE_LOGSTORE=1 \
    COORDKIT_MODE=local COORDKIT_HOST=codex bash -c '
      . "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"
      logstore_readall
    '
)"
printf '%s' "$append_readall" | grep -q 'still-visible'
printf '%s' "$append_readall" | grep -q 'tail survives'
test "$(printf '%s\n' "$append_readall" | grep -c 'sha256:append-dup' || true)" -eq 1
printf '%s' "$append_readall" | grep -q '{"schema_version":"2.0","eid":"sha256:append-garbage","id":"broken"'

# Concurrent writers must serialize cleanly. Exercise the live append path with
# many background processes targeting the same actor partition, then prove the
# resulting file still parses as JSON line-by-line and every event survives.
concurrent="$tmp/concurrent"
mkdir -p "$concurrent"
for i in $(seq 1 24); do
  COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_BUS_ROOT="$concurrent" \
    COORDKIT_USE_LOGSTORE=1 COORDKIT_MODE=local COORDKIT_HOST=codex \
    bash -c '
      set -euo pipefail
      . "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"
      n="$1"
      line="$(jq -nc --arg eid "sha256:race-$n" --argjson n "$n" \
        "{schema_version:\"2.0\",eid:\$eid,id:\$eid,actor:\"race-actor\",clock:{p:\$n,c:1},seq:\$n,ts:4,sid:\"race\",sid8:\"race\",host:\"codex\",branch:\"main\",type:\"note\",subject:(\"race-\" + (\$n|tostring)),body:(\"body \" + (\$n|tostring)),refs:[],tags:[],lease:null}")"
      logstore_append "$line"
    ' _ "$i" &
done
wait
race_file="$concurrent/.coordkit-bus/log/race-actor/seg.ndjson"
test "$(wc -l < "$race_file" | tr -d ' ')" -eq 24
test "$(jq -Rr 'fromjson | select(type=="object") | .eid' "$race_file" | sort -u | wc -l | tr -d ' ')" -eq 24
race_readall="$(
  COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_BUS_ROOT="$concurrent" \
    COORDKIT_USE_LOGSTORE=1 COORDKIT_MODE=local COORDKIT_HOST=codex \
    bash -c '
      . "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"
      logstore_readall
    '
)"
test "$(printf '%s\n' "$race_readall" | grep -c 'sha256:race-' || true)" -eq 24

echo "ledger token governor: ok"
