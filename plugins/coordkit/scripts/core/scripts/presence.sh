#!/usr/bin/env bash
# shellcheck shell=bash
# presence.sh — machine presence + realtime tail for multi-machine coordkit.
#
#   heartbeat [--task <id>] [--cap <k[=v]>]... [--ttl <s>] [--loop <s>] [--json]
#       Emit ONE `heartbeat` event into the shared log (every transport mode).
#       Carries: machine name, actor, pid/session, cwd/repo, git branch, current
#       task/claim, capabilities, ts, ttl_s. `--loop <s>` re-emits forever in
#       the foreground (tmux pane / bin/coordkit-monitor / systemd), flushing the
#       relay outbox each tick in relay mode.
#   peers [--json] [--all] [--summary]
#       Projection over heartbeat events: one row per (machine, actor, session)
#       — last seen, age, alive|stale (age > ttl_s), task, branch, caps, repo.
#   watch [--since <duration|all|watermark|actor-cursors-json>]
#         [--filter <type,...>] [--exclude <type,...>] [--json|--pretty]
#         [--interval <s>] [--once]
#       Live follow of the shared event stream across machines. relay: server
#       long-poll (`?wait=`); git: __git_sync at --interval; local: re-read the
#       segments at --interval. Exits 0 on SIGINT/SIGTERM.
#
# EVENT SHAPE (v2 envelope, plugins/coordkit/protocol/event.schema.json):
#   type:"heartbeat"  subject:"<machine>/<actor>"  lease:null  NO `seq`
#   top-level contract fields (read by `cobus dispatch` and `peers`):
#     machine (string)  actor (string)  caps (object k->string|true)
#     task (string|null)  ttl_s (int)  ts (epoch s, already in the envelope)
#   plus `presence:{machine,pid,session,cwd,repo:{root,name,remote},branch,
#     task,caps,ttl_s}` — the superset record.
#   `host` is NOT the machine name: it stays the adapter identity
#   (claude-code|codex|cli) exactly as every other event. Machine name lives in
#   `machine` (env COORDKIT_MACHINE > coord.toml [machine] name > hostname -s).
#
# WHY NO `seq`: every ledger.sh projection (digest delta, board, cursors) keys
# off a NUMERIC .seq. Omitting it makes heartbeats invisible to the shared-
# context digest that hooks inject on every prompt (a 30s heartbeat from every
# machine would otherwise flood it), and means heartbeats never contend for the
# seq-allocation lock. Presence is a side channel over the same durable log.
#
# WHY eid INCLUDES ts: each heartbeat is a fresh liveness signal. Two identical
# heartbeats 30s apart MUST both survive dedup, so `ts` is part of the identity
# hash — the deliberate opposite of note/decision events.
#
# Defensive: internal trouble -> exit 0 (never wedge a caller); --loop / watch
# exit 0 on SIGINT/SIGTERM.
set -uo pipefail

# shellcheck source=./common.sh
. "${COORDKIT_CORE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}/scripts/common.sh" || exit 0
_pr_plugin_root="$(ck_plugin_root)"
_pr_lib="${_pr_plugin_root}/transports/lib.sh"
if [ ! -f "$_pr_lib" ]; then
  echo "presence: transports/lib.sh not found under ${_pr_plugin_root}" >&2
  exit 0
fi
# shellcheck source=../../../transports/lib.sh
. "$_pr_lib" 2>/dev/null || exit 0
command -v logstore_readall >/dev/null 2>&1 || exit 0

DEFAULT_TTL=90
now() { date +%s; }

usage() {
  cat <<'EOF'
cobus presence — who is alive on which machine, and a live event tail

  cobus heartbeat [--task <id>] [--cap <k[=v]>]... [--ttl <secs>] [--loop <secs>] [--json]
  cobus peers     [--json] [--all] [--summary]
  cobus watch     [--since <10m|2h|all|<watermark>|<actor-cursors-json>>]
                  [--filter <type,...>] [--exclude <type,...>] [--json|--pretty]
                  [--interval <secs>] [--once]

Machine name:  COORDKIT_MACHINE > coord.toml [machine] name > hostname -s
Capabilities:  coord.toml [machine] caps ("k=v,k2" | ["a","b"] | [machine.caps] table)
               < env COORDKIT_CAPS="k=v,k2=v2" < --cap k[=v]   (bare key -> true)
TTL:           --ttl > COORDKIT_HEARTBEAT_TTL > coord.toml [machine] ttl_s > 90
See docs/PRESENCE.md.
EOF
}

# ── config: machine / caps / ttl ────────────────────────────────────────────
_pr_root() { resolve_root "$(ck_project_dir)"; }
_pr_toml() { ck_coord_toml "$(_pr_root)"; }

pr_machine() {
  local m="${COORDKIT_MACHINE:-}"
  [ -n "$m" ] || m="$(ck_toml_table_get "$(_pr_toml)" machine name 2>/dev/null)"
  [ -n "$m" ] || m="$(hostname -s 2>/dev/null)"
  [ -n "$m" ] || m="${HOSTNAME:-}"
  [ -n "$m" ] || m="unknown"
  printf '%s' "$m"
}

# "k=v,k2,k3=v3" -> JSON object (bare key -> true)
_pr_caps_from_kv() {
  printf '%s' "${1:-}" | tr ',' '\n' | jq -Rsc '
    split("\n") | map(gsub("^[[:space:]]+|[[:space:]]+$"; "") | select(length > 0))
    | map(if index("=") then {key: .[:index("=")], value: .[index("=")+1:]}
          else {key: ., value: true} end)
    | map(select(.key | length > 0)) | from_entries' 2>/dev/null || printf '{}'
}

# caps from coord.toml [machine]: caps = "k=v,..." | caps = ["a","b"] | [machine.caps] table
_pr_caps_from_toml() {
  local f raw out='{}' tbl
  f="$(_pr_toml)"; [ -f "$f" ] || { printf '{}'; return; }
  raw="$(ck_toml_table_get "$f" machine caps 2>/dev/null)"
  if [ -n "$raw" ]; then
    case "$raw" in
      \[*) out="$(printf '%s' "$raw" | jq -c 'if type=="array" then map(tostring) | map({key:., value:true}) | from_entries else {} end' 2>/dev/null || printf '{}')" ;;
      *)   out="$(_pr_caps_from_kv "$raw")" ;;
    esac
  fi
  # [machine.caps] table: every `k = v` line inside it
  tbl="$(awk '
    { t=$0; sub(/^[ \t]+/, "", t)
      if (t ~ /^\[/) { h=t; sub(/^\[[ \t]*/, "", h); sub(/[ \t]*\].*$/, "", h); intbl=(h=="machine.caps"); next }
      if (!intbl || t ~ /^#/ || t !~ /=/) next
      k=t; sub(/[ \t]*=.*$/, "", k); v=t; sub(/^[^=]*=[ \t]*/, "", v)
      if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
      else if (v ~ /^'"'"'/) { sub(/^'"'"'/, "", v); sub(/'"'"'.*$/, "", v) }
      else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]*$/, "", v) }
      printf "%s=%s\n", k, v
    }' "$f" 2>/dev/null | paste -sd, -)"
  [ -n "$tbl" ] && out="$(jq -nc --argjson a "$out" --argjson b "$(_pr_caps_from_kv "$tbl")" '$a + $b' 2>/dev/null || printf '%s' "$out")"
  printf '%s' "${out:-{\}}"
}

pr_ttl() {
  local t="${1:-}"
  [ -n "$t" ] || t="${COORDKIT_HEARTBEAT_TTL:-}"
  [ -n "$t" ] || t="$(ck_toml_table_get "$(_pr_toml)" machine ttl_s 2>/dev/null)"
  case "$t" in ''|*[!0-9]*) t="$DEFAULT_TTL" ;; esac
  [ "$t" -gt 0 ] || t="$DEFAULT_TTL"
  printf '%s' "$t"
}

# repo identity: {root,name,remote}
pr_repo_json() {
  local root remote
  root="$(_pr_root)"
  remote="$(git -C "$root" config --get remote.origin.url 2>/dev/null)"
  jq -nc --arg root "$root" --arg name "${root##*/}" --arg remote "${remote:-}" \
    '{root:$root, name:$name, remote:(if $remote=="" then null else $remote end)}' 2>/dev/null
}

# Current task: explicit > env > bus agents/<sid>.json .task > latest live claim by this actor.
pr_detect_task() { # <sid> <actor> <now>
  local sid="$1" actor="$2" t="$3" f task=""
  f="$(_pr_root)/.coordkit-bus/agents/${sid}.json"
  [ -f "$f" ] && task="$(jq -r '.task // empty' "$f" 2>/dev/null)"
  [ -n "$task" ] && { printf '%s' "$task"; return; }
  [ "${COORDKIT_PRESENCE_DETECT_TASK:-1}" = 1 ] || return 0
  logstore_readall 2>/dev/null | jq -Rnr --arg me "$actor" --arg sid "$sid" --argjson now "$t" '
    [inputs | fromjson? | select(type=="object")] as $all
    | ($all | map(select(.type=="done") | .subject)) as $done
    | [ $all[] | select(.type=="claim")
        | select((.actor // "") == $me or ((.sid // "") == $sid and $sid != "cli"))
        | select(((.lease | if type=="object" then (.until // 0) else (. // 0) end) // 0) > $now)
        | select(.subject as $s | ($done | index($s)) == null) ]
    | (last // {}) | .subject // empty' 2>/dev/null
}

# ── emit one heartbeat line (also prints it when $2 = 1) ────────────────────
pr_emit_heartbeat() { # <task> <caps-json> <ttl> <pid> <print-json 0|1>
  local task="$1" caps="$2" ttl="$3" pid="$4" show="${5:-0}"
  local actor host machine sid sid8 branch cwd repo p c t id base eid hcmd="sha256sum" hasher="sha256" body line
  command -v b3sum >/dev/null 2>&1 && { hasher="blake3"; hcmd="b3sum"; }
  actor="$(ck_actor)"; host="$(ck_host)"; machine="$(pr_machine)"
  sid="$(ck_session_id)"; sid8="${sid:0:8}"
  cwd="$(ck_project_dir)"; branch="$(branch_of "$cwd")"; repo="$(pr_repo_json)"
  t="$(now)"
  p="$(date +%s%3N 2>/dev/null)"; case "$p" in *[!0-9]*|'') p=$(( t * 1000 ));; esac
  c="$(ck_clock_c)"
  id="$(printf '%x%04x' "$t" "$(( ${RANDOM:-0} ))")"
  [ -z "$task" ] && task="$(pr_detect_task "$sid" "$actor" "$t")"
  body="heartbeat ${machine}/${actor} sid:${sid8} branch:${branch}${task:+ task:${task}} ttl:${ttl}s"
  base="$(jq -nc \
    --arg sv "2.0" --arg actor "$actor" --argjson p "$p" --argjson c "$c" --argjson ts "$t" \
    --arg sid "$sid" --arg sid8 "$sid8" --arg host "$host" --arg user "${USER:-}" --arg br "$branch" \
    --arg machine "$machine" --arg subject "${machine}/${actor}" --arg body "$body" \
    --arg task "$task" --argjson caps "$caps" --argjson ttl "$ttl" --argjson pid "$pid" \
    --arg cwd "$cwd" --argjson repo "$repo" --arg id "$id" '
    ($task | if . == "" then null else . end) as $tk
    | {schema_version:$sv, eid:"", id:$id, actor:$actor, clock:{p:$p,c:$c}, ts:$ts,
       sid:$sid, sid8:$sid8, host:$host, user:$user, branch:$br,
       type:"heartbeat", subject:$subject, body:$body, refs:[], tags:["presence"], lease:null,
       machine:$machine, caps:$caps, task:$tk, ttl_s:$ttl,
       presence:{machine:$machine, pid:$pid, session:$sid, cwd:$cwd, repo:$repo,
                 branch:$br, task:$tk, caps:$caps, ttl_s:$ttl},
       supersedes:null, sig:null}' 2>/dev/null)" || return 1
  [ -n "$base" ] || return 1
  # identity = logical content + ts (each tick is a distinct liveness signal)
  eid="${hasher}:$(printf '%s' "$base" | jq -Sc \
    '{schema_version,actor,sid,host,branch,type,subject,machine,task,caps,ttl_s,ts,presence}' 2>/dev/null \
    | "$hcmd" 2>/dev/null | cut -d' ' -f1 | cut -c1-32)"
  line="$(printf '%s' "$base" | jq -c --arg eid "$eid" '.eid=$eid' 2>/dev/null)"
  [ -n "$line" ] || return 1
  logstore_append "$line" || return 1
  [ "$show" = 1 ] && printf '%s\n' "$line"
  return 0
}

# ── heartbeat ───────────────────────────────────────────────────────────────
cmd_heartbeat() {
  local task="${COORDKIT_TASK:-}" ttl="" loop=0 show=0 caps flags='{}' kv
  while [ $# -gt 0 ]; do
    case "$1" in
      --task) shift; task="${1:-}" ;;
      --task=*) task="${1#--task=}" ;;
      --cap) shift; flags="$(jq -nc --argjson a "$flags" --argjson b "$(_pr_caps_from_kv "${1:-}")" '$a + $b')" ;;
      --cap=*) flags="$(jq -nc --argjson a "$flags" --argjson b "$(_pr_caps_from_kv "${1#--cap=}")" '$a + $b')" ;;
      --ttl) shift; ttl="${1:-}" ;;
      --ttl=*) ttl="${1#--ttl=}" ;;
      --loop) shift; loop="${1:-30}" ;;
      --loop=*) loop="${1#--loop=}" ;;
      --json) show=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "heartbeat: unknown argument: $1" >&2; usage >&2; return 2 ;;
    esac
    shift
  done
  ttl="$(pr_ttl "$ttl")"
  case "$loop" in ''|*[!0-9]*) loop=0 ;; esac
  # caps precedence: toml < env < flags
  kv='{}'; [ -n "${COORDKIT_CAPS:-}" ] && kv="$(_pr_caps_from_kv "$COORDKIT_CAPS")"
  caps="$(jq -nc --argjson t "$(_pr_caps_from_toml)" --argjson e "$kv" --argjson f "$flags" '$t + $e + $f' 2>/dev/null || printf '{}')"
  ck_ensure_site
  local mode; mode="$(logstore_mode)"
  if [ "$loop" -le 0 ]; then
    if pr_emit_heartbeat "$task" "$caps" "$ttl" "$PPID" "$show"; then
      [ "$show" = 1 ] || echo "💓 heartbeat $(pr_machine)/$(ck_actor) (ttl ${ttl}s, mode ${mode})${task:+ task:${task}}"
      return 0
    fi
    echo "presence: heartbeat could not be appended (mode ${mode})" >&2; return 1
  fi
  local running=1
  trap 'running=0' INT TERM
  [ "$show" = 1 ] || echo "💓 heartbeat loop every ${loop}s (ttl ${ttl}s, mode ${mode}) — Ctrl-C to stop" >&2
  while [ "$running" = 1 ]; do
    pr_emit_heartbeat "$task" "$caps" "$ttl" "$$" "$show" || echo "presence: heartbeat append failed; retrying next tick" >&2
    # logstore_append already flushes in relay mode; drain anything left over from
    # an earlier offline tick as well so the outbox never sits idle while we live.
    [ "$mode" = relay ] && command -v __relay_flush_outbox >/dev/null 2>&1 && __relay_flush_outbox
    [ "$running" = 1 ] || break
    sleep "$loop" & wait $! 2>/dev/null
  done
  [ "$show" = 1 ] || echo "💓 heartbeat loop stopped" >&2
  return 0
}

# ── peers ───────────────────────────────────────────────────────────────────
# Rows (JSON objects) from the union: latest heartbeat per (machine, actor, sid).
pr_peer_rows() { # <all 0|1>
  local all="${1:-0}" t; t="$(now)"
  logstore_readall 2>/dev/null | jq -Rnc --argjson now "$t" --argjson all "$all" '
    [inputs | fromjson? | select(type=="object") | select(.type=="heartbeat")]
    | map(. + {machine: (.machine // .presence.machine // .host // "?"),
               ttl_s: ((.ttl_s // .presence.ttl_s // 90) | tonumber),
               ts: ((.ts // ((.clock.p // 0) / 1000)) | floor)})
    | group_by([.machine, .actor, .sid]) | map(max_by([.ts, .clock.c // 0]))
    | map(. as $e | ($now - .ts) as $age
      | {machine, actor: (.actor // "?"), sid: (.sid // ""), sid8: (.sid8 // ""), host: (.host // "?"),
         user: (.user // ""), ts, age_s: $age, ttl_s,
         state: (if $age <= .ttl_s then "alive" else "stale" end),
         task: (.task // .presence.task // null), branch: (.branch // .presence.branch // ""),
         caps: (.caps // .presence.caps // {}), repo: (.presence.repo.name // ""),
         repo_root: (.presence.repo.root // ""), cwd: (.presence.cwd // ""), pid: (.presence.pid // null),
         last_seen: (.ts | strftime("%Y-%m-%dT%H:%M:%SZ"))})
    | map(select($all == 1 or .age_s <= 86400))
    | sort_by([(if .state == "alive" then 0 else 1 end), .machine, .actor, .sid])
    | .[]' 2>/dev/null
}

_pr_fmt_age() { # secs
  local s="$1"
  if [ "$s" -lt 0 ]; then printf '0s'
  elif [ "$s" -lt 120 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 7200 ]; then printf '%sm' $(( s / 60 ))
  elif [ "$s" -lt 172800 ]; then printf '%sh' $(( s / 3600 ))
  else printf '%sd' $(( s / 86400 )); fi
}

cmd_peers() {
  local json=0 all=0 summary=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1 ;; --all) all=1 ;; --summary) summary=1 ;;
      -h|--help) usage; return 0 ;;
      *) echo "peers: unknown argument: $1" >&2; return 2 ;;
    esac; shift
  done
  local rows; rows="$(pr_peer_rows "$all")"
  if [ "$json" = 1 ]; then
    printf '%s\n' "$rows" | jq -sc '.' 2>/dev/null || echo '[]'; return 0
  fi
  if [ "$summary" = 1 ]; then
    [ -n "$rows" ] || return 0
    printf '%s\n' "$rows" | jq -rs '
      (map(select(.state=="alive")) | map(.machine) | unique) as $a
      | (map(select(.state=="stale")) | map(.machine) | unique) as $s
      | "🌐 machines (shared log): \($a|length) alive\(if ($a|length)>0 then " (" + ($a|join(", ")) + ")" else "" end) · \($s|length) stale\(if ($s|length)>0 then " (" + ($s|join(", ")) + ")" else "" end) — cobus peers"' 2>/dev/null
    return 0
  fi
  if [ -z "$rows" ]; then
    echo "🌐 coordkit peers — no heartbeats in the shared log yet (mode $(logstore_mode)). Run: cobus heartbeat [--loop 30]"
    return 0
  fi
  local me; me="$(ck_actor)"
  printf '🌐 coordkit peers  %s  (mode %s)\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$(logstore_mode)"
  printf '  %-6s %-16s %-14s %-9s %-6s %-22s %-18s %s\n' STATE MACHINE ACTOR SESSION AGE TASK BRANCH "CAPS · REPO"
  local state machine actor sid8 age task branch caps repo mark
  while IFS=$'\x1f' read -r state machine actor sid8 age task branch caps repo; do
    [ -n "$state" ] || continue
    mark=""; [ "$actor" = "$me" ] && mark="*"
    printf '  %-6s %-16s %-14s %-9s %-6s %-22s %-18s %s%s\n' \
      "$state" "${machine:0:16}" "${actor:0:13}${mark}" "${sid8:-cli}" "$(_pr_fmt_age "$age")" \
      "${task:--}" "${branch:0:18}" "${caps:--}" "${repo:+ · ${repo}}"
  done < <(printf '%s\n' "$rows" | jq -r '[.state, .machine, .actor, .sid8, (.age_s|tostring), (.task // ""), .branch,
      (.caps | to_entries | map(if .value == true then .key else "\(.key)=\(.value)" end) | join(",")), .repo] | map(tostring | gsub("[[:cntrl:]]+"; " ")) | join("\u001f")' 2>/dev/null)
  echo "  (* = this machine's actor · stale = older than its ttl · --all to include >24h old · --json for the raw rows)"
}

# ── watch ───────────────────────────────────────────────────────────────────
_pr_duration_secs() { # "90", "90s", "10m", "2h", "1d" -> secs, or fail
  local v="$1" n unit
  case "$v" in
    *[!0-9smhd]*|'') return 1 ;;
  esac
  n="${v%[smhd]}"; unit="${v#"$n"}"
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  case "$unit" in
    ''|s) printf '%s' "$n" ;; m) printf '%s' $(( n * 60 )) ;;
    h) printf '%s' $(( n * 3600 )) ;; d) printf '%s' $(( n * 86400 )) ;;
  esac
}

# Filter a stream of raw JSON lines by type include/exclude lists.
_pr_type_filter() { # <include-csv> <exclude-csv>
  jq -Rr --arg inc "${1:-}" --arg exc "${2:-}" '
    ($inc | if . == "" then [] else split(",") end) as $i
    | ($exc | if . == "" then [] else split(",") end) as $x
    | . as $raw | (try fromjson catch null) as $e
    | (($e.type // "note") | tostring) as $t
    | select(($i | length) == 0 or ($i | index($t)) != null)
    | select(($x | index($t)) == null)
    | $raw' 2>/dev/null
}

_pr_render() { # <json 0|1> <color 0|1>
  if [ "$1" = 1 ]; then cat; return; fi
  jq -Rr --argjson color "$2" '
    def c($n): if $color == 1 then "\u001b[" + $n + "m" else "" end;
    def col($t): if $t=="heartbeat" then c("2") elif $t=="task" then c("36") elif $t=="claim" then c("33")
      elif $t=="done" then c("32") elif $t=="block" then c("31") elif $t=="decision" then c("35")
      elif ($t=="question" or $t=="answer") then c("34") else "" end;
    . as $raw | (try fromjson catch null) as $e
    | if ($e|type) != "object" then "?? " + $raw else
      (($e.ts // ((($e.clock.p // 0)/1000)|floor)) | if . > 0 then strflocaltime("%H:%M:%S") else "--:--:--" end) as $hh
      | (($e.type // "note") | tostring) as $t
      | ($e.machine // $e.presence.machine // "") as $m
      | (($e.actor // $e.sid8 // "?") | tostring) as $a
      | ($m + (if $m == "" then "" else "/" end) + $a + "@" + (($e.host // "?")|tostring)) as $who
      | (if $t == "heartbeat"
         then "branch:" + (($e.branch // "")|tostring) + (if ($e.task // null) != null then " task:" + ($e.task|tostring) else "" end)
              + " ttl:" + (($e.ttl_s // 0)|tostring) + "s"
         else (($e.body // "") | tostring | gsub("[[:cntrl:]]+"; " ")) end) as $body
      | "\($hh)  \(c("1"))\($who)\(c("0"))  \(col($t))\($t)/\(($e.subject // "")|tostring)\(c("0"))  \($body)"
      end' 2>/dev/null
}

cmd_watch() {
  local since="" inc="" exc="" json=0 interval="" once=0 color=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --since) shift; since="${1:-}" ;;      --since=*) since="${1#--since=}" ;;
      --filter) shift; inc="${1:-}" ;;       --filter=*) inc="${1#--filter=}" ;;
      --exclude) shift; exc="${1:-}" ;;      --exclude=*) exc="${1#--exclude=}" ;;
      --interval) shift; interval="${1:-}" ;; --interval=*) interval="${1#--interval=}" ;;
      --json) json=1 ;; --pretty) json=0 ;; --once) once=1 ;;
      --color) color=1 ;; --no-color) color=2 ;;
      -h|--help) usage; return 0 ;;
      *) echo "watch: unknown argument: $1" >&2; return 2 ;;
    esac; shift
  done
  case "$color" in 0) [ -t 1 ] && color=1 ;; 2) color=0 ;; esac
  local mode; mode="$(logstore_mode)"
  case "$interval" in ''|*[!0-9]*)
    case "$mode" in git) interval="${COORDKIT_WATCH_INTERVAL:-10}" ;; *) interval="${COORDKIT_WATCH_INTERVAL:-1}" ;; esac ;;
  esac
  case "$interval" in ''|*[!0-9]*) interval=1 ;; esac
  local wait_ms="${COORDKIT_WATCH_LONGPOLL_MS:-20000}"
  case "$wait_ms" in ''|*[!0-9]*) wait_ms=20000 ;; esac

  local snap running=1 cursors='{}' wm="" t
  snap="$(mktemp "${TMPDIR:-/tmp}/coordkit-watch.XXXXXX" 2>/dev/null)" || return 1
  trap 'running=0' INT TERM
  # shellcheck disable=SC2064
  trap "rm -f '$snap' 2>/dev/null" EXIT

  logstore_readall > "$snap" 2>/dev/null || : > "$snap"
  t="$(now)"
  # ── initial backfill according to --since ──
  local secs
  if [ -z "$since" ] || [ "$since" = 0 ] || [ "$since" = now ]; then
    :
  elif [ "$since" = all ]; then
    _pr_type_filter "$inc" "$exc" < "$snap" | _pr_render "$json" "$color"
  elif secs="$(_pr_duration_secs "$since")"; then
    jq -Rr --argjson cut "$(( t - secs ))" '
      . as $raw | (try fromjson catch null) as $e
      | (($e.ts // ((($e.clock.p // 0)/1000)|floor)) // 0) as $ts
      | select($ts >= $cut) | $raw' "$snap" 2>/dev/null | _pr_type_filter "$inc" "$exc" | _pr_render "$json" "$color"
  elif printf '%s' "$since" | jq -e 'type=="object"' >/dev/null 2>&1; then
    __filter_since_actor_cursors "$since" "" < "$snap" | _pr_type_filter "$inc" "$exc" | _pr_render "$json" "$color"
  else
    __filter_since "$since" < "$snap" | _pr_type_filter "$inc" "$exc" | _pr_render "$json" "$color"
  fi
  cursors="$(__actor_cursors_of < "$snap")"; [ -n "$cursors" ] || cursors='{}'
  wm="$(__watermark_of < "$snap")"
  [ "$json" = 1 ] || printf '%s\n' "── watching (mode ${mode}${inc:+, filter ${inc}}${exc:+, exclude ${exc}}) — Ctrl-C to stop ──" >&2
  [ "$once" = 1 ] && return 0

  while [ "$running" = 1 ]; do
    case "$mode" in
      relay)
        # Long-poll WITHOUT holding the pull lock (a sibling `cobus board` must
        # still be able to pull), then let readall's own sync fold what arrived.
        if command -v __relay_wait_for_events >/dev/null 2>&1; then
          __relay_wait_for_events "$wait_ms" || true
        fi
        ;;
      git)
        command -v __git_sync >/dev/null 2>&1 && __git_sync >/dev/null 2>&1
        ;;
    esac
    [ "$running" = 1 ] || break
    logstore_readall > "${snap}.new" 2>/dev/null && mv -f "${snap}.new" "$snap" 2>/dev/null
    __filter_since_actor_cursors "$cursors" "$wm" < "$snap" | _pr_type_filter "$inc" "$exc" | _pr_render "$json" "$color"
    cursors="$(__actor_cursors_of < "$snap")"; [ -n "$cursors" ] || cursors='{}'
    wm="$(__watermark_of < "$snap")"
    [ "$running" = 1 ] || break
    # relay mode: the long-poll is the wait; only back off when it returned fast
    # (server unreachable / no wait support) so a dead relay doesn't spin.
    sleep "$interval" & wait $! 2>/dev/null
  done
  [ "$json" = 1 ] || echo "── watch stopped ──" >&2
  return 0
}

case "${1:-}" in
  heartbeat) shift; cmd_heartbeat "$@" ;;
  peers)     shift; cmd_peers "$@" ;;
  watch)     shift; cmd_watch "$@" ;;
  ""|-h|--help|help) usage ;;
  *) echo "presence: unknown command '$1' (heartbeat|peers|watch)" >&2; usage >&2; exit 2 ;;
esac
