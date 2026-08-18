#!/usr/bin/env bash
# shellcheck shell=bash
# dispatch.sh — `cobus dispatch`: cross-machine task dispatch on top of the
# shared coordination log.
#
# From any machine, hand a ledger task to a specific other machine (or to
# "whoever is capable and idle"), with a lease so nothing is lost when a laptop
# closes, and a wake-up so the target picks it up in near-real-time (relay
# mode) or on next sync (git mode). See docs/DISPATCH.md for the model.
#
# It is a thin STATE MACHINE projected from append-only events, all written
# through the same LogStore the ledger uses (transports/lib.sh), so it works
# unchanged in local / git / relay mode:
#
#   dispatch            {id, task, title, target:{machine,actor,needs}, lease_s,
#                        priority, note, from:{machine,actor}, ts}
#   dispatch.accepted   {id, task, by:{machine,actor}, lease_until, ts}
#   dispatch.renewed    {id, by, lease_until, ts}
#   dispatch.released   {id, by, reason, ts}
#   dispatch.expired    {id, holder, lease_until, reaped_by, ts}
#   dispatch.done       {id, by, ts}
#
# Every event's `subject` is the dispatch id; the payload rides in `body`
# (compact JSON string, so it is covered by the eid) and is mirrored as a
# top-level `dispatch` object for cheap jq. Like presence heartbeats, dispatch
# events carry NO `seq`, which keeps them out of the ledger's seq-keyed
# digest/board projections; the ledger sees the task itself through the normal
# task/claim/done events dispatch.sh emits via ledger.sh.
#
# Race resolution (append-only, eventually consistent log): events of one
# dispatch are replayed in (clock.p emission-ms, create-first, eid) order and
# the FIRST `dispatch.accepted` for the current open epoch wins; every later
# accept for that epoch — and any accept tagged with a stale epoch — is
# ignored on read. Every replica computes the same answer once it has the same
# events, so a machine that briefly believed it won simply sees itself lose on
# the next projection (`accept` re-projects after writing and reports that).
#
# Presence contract (built concurrently as `cobus heartbeat/peers`,
# presence.sh): events of type `heartbeat` with top-level `machine`, `actor`,
# `caps` (object string→string|true), `task`, `ttl_s`, `ts`. dispatch.sh only
# READS them (to advise whether any live peer matches a selector); their
# absence degrades to "no peer info", never to an error.
#
# Bash 4+ / jq only.
set -uo pipefail

# shellcheck source=./common.sh
. "${COORDKIT_CORE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}/scripts/common.sh" || exit 1

DSP_CORE="$(ck_core_root)"
DSP_PLUGIN="$(ck_plugin_root)"
DSP_LEDGER="${DSP_CORE}/scripts/ledger.sh"
DSP_BUS="${DSP_CORE}/scripts/bus.sh"
DSP_RELAY_CLIENT="${DSP_CORE}/scripts/relay-client.sh"
DSP_GIT_SYNC="${DSP_PLUGIN}/bin/sync.sh"
DSP_LIB="${DSP_PLUGIN}/transports/lib.sh"

# shellcheck source=../transports/lib.sh
if ! . "$DSP_LIB" 2>/dev/null || ! command -v logstore_readall >/dev/null 2>&1; then
  echo "cobus dispatch: transports/lib.sh not found at $DSP_LIB" >&2
  exit 1
fi

DEFAULT_LEASE=1800     # 30 min — a heavy test run; renewed by `worker` while the child runs
DEFAULT_PRIORITY=5
WORKER_INTERVAL=15
US=$'\x1f'

usage() {
  cat <<'EOF'
cobus dispatch — hand a task to another machine (or to whoever is capable and idle)

Usage:
  cobus dispatch <task-id|"title"> [--to <machine|machine/actor>] [--needs k=v,k2=v2]
                 [--lease <secs>] [--priority N] [--note "..."]
                                  create the task if needed and dispatch it
  cobus dispatch accept [<dispatch-id>|--auto]
                                  (target machine) claim a dispatch; --auto picks
                                  the oldest open one that matches this
                                  machine / actor / caps
  cobus dispatch renew <id> [--lease <secs>]   extend the lease you hold
  cobus dispatch release <id> [--reason "..."] give it back (re-acceptable)
  cobus dispatch done <id>                     complete it (and the ledger task)
  cobus dispatch reap                          expire lapsed accepted dispatches
                                               so another machine can accept
  cobus dispatch ls [--mine|--open|--all] [--json]
                                  projection: id, task, target, state, holder,
                                  lease remaining  (default: everything not done)
  cobus dispatch worker [--interval <s>] [--exec <cmd>] [--once]
                                  foreground loop: sync, reap, accept --auto,
                                  run <cmd> with COORDKIT_DISPATCH_ID /
                                  COORDKIT_TASK_ID / COORDKIT_TASK_TITLE
                                  exported, renew while it runs, done on exit 0
                                  else release with the exit code as reason
  cobus dispatch peers            live presence peers (from `cobus heartbeat`)
  cobus dispatch whoami           this machine / actor / caps as seen by matching

Identity (matches `cobus heartbeat`):
  machine  COORDKIT_MACHINE > coord.toml [machine] name > hostname -s
  actor    the stable coordkit site id (ck_actor)
  caps     coord.toml [machine] caps = "k=v,k2=v2" | ["k","k2"] | [machine.caps]
           table, overridden by COORDKIT_CAPS="k=v,k2=v2"; bare key means true

States: open → accepted → done | released | expired ; released/expired are
re-acceptable. First `accept` per open epoch wins (lowest (clock.p, eid) on read).
See docs/DISPATCH.md.
EOF
}

now() { date +%s; }

# ── identity ─────────────────────────────────────────────────────────────────
dsp_root() { resolve_root "$(ck_project_dir)"; }

dsp_machine() {
  local m="${COORDKIT_MACHINE:-}" toml
  if [ -z "$m" ]; then
    toml="$(ck_coord_toml "$(dsp_root)")"
    m="$(ck_toml_table_get "$toml" machine name 2>/dev/null || true)"
  fi
  [ -n "$m" ] || m="$(hostname -s 2>/dev/null || true)"
  [ -n "$m" ] || m="${HOSTNAME:-unknown}"
  printf '%s' "$m"
}

# "k=v,k2=v2,bare" -> {"k":"v","k2":"v2","bare":true}
dsp_kv_to_json() {
  [ -n "${1:-}" ] || { printf '{}'; return 0; }
  printf '%s' "$1" | jq -Rc '
    split(",") | map(gsub("^\\s+|\\s+$"; "") | select(length > 0))
    | map(if index("=") then {key: .[:index("=")], value: .[index("=")+1:]}
          else {key: ., value: true} end)
    | from_entries' 2>/dev/null || printf '{}'
}

# Merged caps object: coord.toml [machine] caps / [machine.caps] < COORDKIT_CAPS.
dsp_caps_json() {
  local toml raw base='{}' tbl='{}' env='{}'
  toml="$(ck_coord_toml "$(dsp_root)")"
  if [ -f "$toml" ]; then
    raw="$(ck_toml_table_get "$toml" machine caps 2>/dev/null || true)"
    case "$raw" in
      '['*) base="$(printf '%s' "$raw" | jq -c 'if type=="array" then map(tostring) | map({key:., value:true}) | from_entries else {} end' 2>/dev/null || printf '{}')" ;;
      ?*)   base="$(dsp_kv_to_json "$raw")" ;;
    esac
    # [machine.caps] table: every `key = value` line inside it
    tbl="$(awk '
      { t=$0; sub(/^[ \t]+/, "", t)
        if (t ~ /^\[/) { h=t; sub(/^\[[ \t]*/, "", h); sub(/[ \t]*\].*$/, "", h); intbl=(h=="machine.caps"); next }
        if (!intbl) next
        if (t ~ /^[A-Za-z0-9_.-]+[ \t]*=/) {
          k=t; sub(/[ \t]*=.*$/, "", k)
          v=t; sub(/^[^=]*=[ \t]*/, "", v)
          if (v ~ /^"/) { sub(/^"/, "", v); sub(/".*$/, "", v) }
          else if (v ~ /^\x27/) { sub(/^\x27/, "", v); sub(/\x27.*$/, "", v) }
          else { sub(/[ \t]+#.*$/, "", v); sub(/[ \t]*$/, "", v) }
          print k "=" v
        }
      }' "$toml" 2>/dev/null | paste -sd, - 2>/dev/null)"
    [ -n "$tbl" ] && tbl="$(dsp_kv_to_json "$tbl")" || tbl='{}'
  fi
  [ -n "${COORDKIT_CAPS:-}" ] && env="$(dsp_kv_to_json "$COORDKIT_CAPS")"
  jq -nc --argjson a "$base" --argjson b "$tbl" --argjson c "$env" '$a + $b + $c'
}

# ── log access ───────────────────────────────────────────────────────────────
DSP_ALL=""   # cached readall for one invocation
dsp_readall() {
  if [ -z "$DSP_ALL" ]; then
    DSP_ALL="$(mktemp "${TMPDIR:-/tmp}/coordkit-dispatch.XXXXXX")" || return 1
    trap 'rm -f "$DSP_ALL" 2>/dev/null' EXIT
    logstore_readall > "$DSP_ALL" 2>/dev/null || : > "$DSP_ALL"
  fi
  cat "$DSP_ALL"
}
dsp_reload() { [ -n "$DSP_ALL" ] && { logstore_readall > "${DSP_ALL}.tmp" 2>/dev/null && mv -f "${DSP_ALL}.tmp" "$DSP_ALL"; }; return 0; }
dsp_invalidate() { dsp_reload; }

# dsp_emit <type> <subject> <payload-json> [lease-until-epoch]
# Builds a v2 envelope (no seq — see header), eid over the identity fields,
# appends through logstore_append (local/git/relay).
dsp_emit() {
  local type="$1" subject="$2" payload="$3" until="${4:-}"
  local actor host p c id ts lease base eid hasher="sha256" hcmd="sha256sum" body machine
  command -v b3sum >/dev/null 2>&1 && { hasher="blake3"; hcmd="b3sum"; }
  ck_ensure_site
  actor="$(ck_actor)"; host="$(ck_host)"; machine="$(dsp_machine)"
  ts="$(now)"
  p="$(date +%s%3N 2>/dev/null)"; case "$p" in *[!0-9]*|'') p=$(( ts * 1000 ));; esac
  c="$(ck_clock_c)"
  id="$(printf '%x%04x' "$ts" "$(( ${RANDOM:-0} ))")"
  body="$(printf '%s' "$payload" | jq -c . 2>/dev/null)" || return 1
  if [ -n "$until" ]; then
    lease="$(jq -nc --argjson u "$until" --arg o "$actor" --arg s "${COORDKIT_SESSION_ID:-cli}" '{until:$u, owner:$o, sid8:($s|.[0:8])}')"
  else lease='null'; fi
  base="$(jq -nc --arg sv "2.0" --arg actor "$actor" --argjson p "$p" --argjson c "$c" --argjson ts "$ts" \
    --arg sid "$(ck_session_id)" --arg host "$host" --arg user "${USER:-}" --arg br "$(branch_of "$(dsp_root)")" \
    --arg machine "$machine" --arg type "$type" --arg subject "$subject" --arg body "$body" \
    --argjson lease "$lease" --arg id "$id" --argjson d "$body" \
    '{schema_version:$sv, eid:"", id:$id, actor:$actor, clock:{p:$p,c:$c}, ts:$ts, sid:$sid, sid8:($sid|.[0:8]),
      host:$host, user:$user, branch:$br, machine:$machine, type:$type, subject:$subject, body:$body,
      refs:[], tags:["dispatch"], lease:$lease, dispatch:$d, supersedes:null, sig:null}')" || return 1
  eid="${hasher}:$(printf '%s' "$base" | jq -Sc '{schema_version,actor,sid,host,branch,type,subject,body,refs,tags,lease}' \
        | "$hcmd" 2>/dev/null | cut -d' ' -f1 | cut -c1-32)"
  logstore_append "$(printf '%s' "$base" | jq -c --arg eid "$eid" '.eid=$eid')" || return 1
  dsp_invalidate
  return 0
}

# ── projection ───────────────────────────────────────────────────────────────
# One JSON object per dispatch id on stdout, sorted by (priority asc, created ts asc):
# {id, task, title, target:{machine,actor,needs}, lease_s, priority, note, from,
#  created_ts, state, holder:{machine,actor}|null, lease_until, epoch, last_ts}
dsp_project() {
  dsp_readall | jq -Rc --argjson now "$(now)" '
    def payload: (.dispatch // (try (.body|fromjson) catch null) // {});
    [inputs | (try fromjson catch null) | select(type=="object")
      | select((.type // "") | startswith("dispatch"))
      | . as $e | (payload) as $d
      | select(($d.id // $e.subject // "") != "")
      | {t: (.type), ts: (($d.ts // $e.ts // 0) | tonumber? // 0),
         p: (($e.clock.p // (($d.ts // $e.ts // 0) * 1000)) | tonumber? // 0),
         eid: (.eid // ""), d: $d, id: ($d.id // $e.subject)}]
    | group_by(.id)
    | map(
        # causal order = (emission ms clock.p, create-first, eid). See docs/DISPATCH.md "Race resolution".
        sort_by(.p, (if .t == "dispatch" then 0 else 1 end), .eid)
        | reduce .[] as $ev ({state:"missing", holder:null, lease_until:0, epoch:0, last_ts:0};
            .last_ts = $ev.ts
            | if $ev.t == "dispatch" then
                if .state == "missing" then
                  . + {state:"open", id:$ev.id, task:$ev.d.task, title:$ev.d.title, target:($ev.d.target // {}),
                       lease_s:($ev.d.lease_s // 0), priority:($ev.d.priority // 5), note:($ev.d.note // ""),
                       from:($ev.d.from // {}), created_ts:$ev.ts, epoch:1}
                else . end
              elif $ev.t == "dispatch.accepted" then
                if (.state == "open" or .state == "released" or .state == "expired")
                   and (($ev.d.epoch // .epoch) == .epoch) then
                  .state = "accepted" | .holder = $ev.d.by | .lease_until = ($ev.d.lease_until // 0)
                  | .accepted_ts = $ev.ts | .accepted_eid = $ev.eid
                else . end
              elif $ev.t == "dispatch.renewed" then
                if .state == "accepted" and (.holder == $ev.d.by) then .lease_until = ($ev.d.lease_until // .lease_until) else . end
              elif $ev.t == "dispatch.released" then
                if .state == "accepted" and (.holder == $ev.d.by) then
                  .state = "released" | .holder = null | .lease_until = 0 | .epoch += 1 | .reason = ($ev.d.reason // "")
                else . end
              elif $ev.t == "dispatch.expired" then
                if .state == "accepted" and (.holder == $ev.d.holder) and (.lease_until <= $ev.ts) then
                  .state = "expired" | .holder = null | .lease_until = 0 | .epoch += 1
                else . end
              elif $ev.t == "dispatch.done" then
                if .state != "done" and .state != "missing" then .state = "done" | .done_by = $ev.d.by | .done_ts = $ev.ts else . end
              else . end)
        | select(.state != "missing")
        | .lease_left = (if .state == "accepted" then (.lease_until - $now) else null end)
        | .lapsed = (.state == "accepted" and .lease_until < $now))
    | sort_by(.priority, .created_ts, .id)
    | .[]' 2>/dev/null
}

dsp_get() { dsp_project | jq -c --arg id "$1" 'select(.id == $id)' | head -n1; }

# ── presence peers (heartbeat contract) ──────────────────────────────────────
dsp_peers() {
  dsp_readall | jq -Rc --argjson now "$(now)" '
    [inputs | (try fromjson catch null) | select(type=="object") | select(.type == "heartbeat")
      | {machine: (.machine // .presence.machine // ""), actor: (.actor // ""), caps: (.caps // .presence.caps // {}),
         task: (.task // .presence.task // null), ttl_s: ((.ttl_s // .presence.ttl_s // 90) | tonumber? // 90),
         ts: ((.ts // 0) | tonumber? // 0)}
      | select(.machine != "")]
    | group_by(.machine + "/" + .actor) | map(max_by(.ts))
    | map(.alive = ((.ts + .ttl_s) >= $now))
    | .[]' 2>/dev/null
}

# does the {machine,actor,caps} triple satisfy target selector <json>?
dsp_match() { # <target-json> <machine> <actor> <caps-json>
  jq -ne --argjson t "$1" --arg m "$2" --arg a "$3" --argjson caps "$4" '
    (($t.machine // "") == "" or $t.machine == $m)
    and (($t.actor // "") == "" or $t.actor == $a)
    and ([($t.needs // {}) | to_entries[]
          | . as $n | ($caps[$n.key] // null) as $have
          | ($have != null and $have != false)
            and ($n.value == true or $n.value == "*" or $n.value == "" or ($have|tostring) == ($n.value|tostring))]
         | all)' >/dev/null 2>&1
}

# ── sync helpers ─────────────────────────────────────────────────────────────
dsp_sync() {
  case "$(logstore_mode)" in
    relay) [ -f "$DSP_RELAY_CLIENT" ] && bash "$DSP_RELAY_CLIENT" sync >/dev/null 2>&1 ;;
    git)   [ -f "$DSP_GIT_SYNC" ] && COORDKIT_SYNC_DEBOUNCE="${COORDKIT_SYNC_DEBOUNCE:-1}" bash "$DSP_GIT_SYNC" >/dev/null 2>&1 ;;
  esac
  dsp_reload
  return 0
}

dsp_bus_msg() { # best-effort local wake-up for sessions on THIS machine
  [ -f "$DSP_BUS" ] || return 0
  bash "$DSP_BUS" msg all "$1" >/dev/null 2>&1 || true
}

# ── task lookup ──────────────────────────────────────────────────────────────
# Prints "<subject>\t<title>" for an existing ledger task subject, or nothing.
dsp_find_task() {
  dsp_readall | jq -Rr --arg s "$1" '
    [inputs | (try fromjson catch null) | select(type=="object") | select(.type=="task" and .subject==$s)]
    | last // empty | "\(.subject)\t\(.body // "")"' 2>/dev/null
}

dsp_new_id() { printf 'd-%s%04x' "$(printf '%x' "$(now)")" "$(( ${RANDOM:-0} ))"; }

# ── verbs ────────────────────────────────────────────────────────────────────
cmd_create() {
  local spec="" to="" needs="" lease="$DEFAULT_LEASE" prio="$DEFAULT_PRIORITY" note="" quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) to="${2:-}"; shift 2 ;;
      --needs) needs="${2:-}"; shift 2 ;;
      --lease) lease="${2:-}"; shift 2 ;;
      --priority) prio="${2:-}"; shift 2 ;;
      --note) note="${2:-}"; shift 2 ;;
      --quiet|-q) quiet=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) if [ -z "$spec" ]; then spec="$1"; else spec="$spec $1"; fi; shift ;;
    esac
  done
  [ -n "$spec" ] || { usage >&2; return 2; }
  case "$lease" in ''|*[!0-9]*|0) echo "cobus dispatch: --lease must be a positive integer (seconds)" >&2; return 2 ;; esac
  case "$prio" in ''|*[!0-9]*) echo "cobus dispatch: --priority must be an integer" >&2; return 2 ;; esac

  local tmachine="" tactor=""
  if [ -n "$to" ]; then
    case "$to" in */*) tmachine="${to%%/*}"; tactor="${to#*/}" ;; *) tmachine="$to" ;; esac
  fi
  local needs_json; needs_json="$(dsp_kv_to_json "$needs")"

  # resolve / create the ledger task
  local subj title found
  subj="$(slug "$spec")"
  found="$(dsp_find_task "$subj")"
  if [ -n "$found" ]; then
    title="${found#*$'\t'}"
  else
    bash "$DSP_LEDGER" task "$spec" >/dev/null 2>&1
    dsp_invalidate; dsp_reload
    title="$spec"
    found="$(dsp_find_task "$subj")"
    [ -n "$found" ] && title="${found#*$'\t'}"
  fi
  [ -n "$title" ] || title="$spec"

  local id target payload
  id="$(dsp_new_id)"
  target="$(jq -nc --arg m "$tmachine" --arg a "$tactor" --argjson n "$needs_json" \
    '{machine:$m, actor:$a, needs:$n} | with_entries(select(.value != "" and .value != {}))')"
  payload="$(jq -nc --arg id "$id" --arg task "$subj" --arg title "$title" --argjson target "$target" \
    --argjson lease "$lease" --argjson prio "$prio" --arg note "$note" \
    --arg fm "$(dsp_machine)" --arg fa "$(ck_actor)" --argjson ts "$(now)" \
    '{id:$id, task:$task, title:$title, target:$target, lease_s:$lease, priority:$prio, note:$note,
      from:{machine:$fm, actor:$fa}, ts:$ts}')"
  dsp_emit dispatch "$id" "$payload" || { echo "cobus dispatch: could not append dispatch event" >&2; return 1; }
  dsp_sync
  dsp_bus_msg "dispatch ${id}: '${title}' → $(dsp_describe_target "$target") — \`cobus dispatch accept ${id}\` if that's you"

  if [ "$quiet" = 1 ]; then printf '%s\n' "$id"; return 0; fi
  echo "📤 dispatched ${id}: task '${subj}' → $(dsp_describe_target "$target") (lease ${lease}s, priority ${prio}, mode $(logstore_mode))"
  # advisory: is anybody live that matches?
  local n live_match=0 line pm pa pc peers
  n=0
  peers="$(dsp_peers | jq -c 'select(.alive)')"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    n=$(( n + 1 ))
    pm="$(printf '%s' "$line" | jq -r '.machine')"; pa="$(printf '%s' "$line" | jq -r '.actor')"
    pc="$(printf '%s' "$line" | jq -c '.caps')"
    dsp_match "$target" "$pm" "$pa" "$pc" && live_match=$(( live_match + 1 ))
  done <<< "$peers"
  if [ "$n" -eq 0 ]; then
    echo "   (no live presence peers seen — target will pick it up on its next \`cobus dispatch accept --auto\` / worker poll)"
  elif [ "$live_match" -eq 0 ]; then
    echo "   ⚠ ${n} live peer(s) seen, none match the selector — it will wait until one does"
  else
    echo "   ${live_match}/${n} live peer(s) match the selector"
  fi
  return 0
}

dsp_describe_target() {
  printf '%s' "$1" | jq -r '
    [ (if (.machine // "") != "" then "machine=" + .machine else empty end),
      (if (.actor // "") != "" then "actor=" + .actor else empty end),
      (if ((.needs // {}) | length) > 0 then "needs=" + ((.needs|to_entries|map(.key + "=" + (.value|tostring))) | join(",")) else empty end) ]
    | if length == 0 then "anyone" else join(" ") end'
}

# accept one dispatch row (json). Emits accepted + ledger claim. Prints the id.
dsp_accept_row() {
  local row="$1" id task lease_s until payload machine actor epoch
  id="$(printf '%s' "$row" | jq -r '.id')"; task="$(printf '%s' "$row" | jq -r '.task')"
  epoch="$(printf '%s' "$row" | jq -r '.epoch // 1')"
  lease_s="$(printf '%s' "$row" | jq -r '.lease_s // 0')"
  case "$lease_s" in ''|*[!0-9]*|0) lease_s="$DEFAULT_LEASE" ;; esac
  machine="$(dsp_machine)"; actor="$(ck_actor)"
  until=$(( $(now) + lease_s ))
  payload="$(jq -nc --arg id "$id" --arg task "$task" --arg m "$machine" --arg a "$actor" --argjson u "$until" \
    --argjson ts "$(now)" --argjson epoch "$epoch" \
    '{id:$id, task:$task, by:{machine:$m, actor:$a}, lease_until:$u, epoch:$epoch, ts:$ts}')"
  dsp_emit dispatch.accepted "$id" "$payload" "$until" || return 1
  bash "$DSP_LEDGER" claim "$task" >/dev/null 2>&1 || true
  dsp_sync
  # first-accept-wins: re-project and confirm we actually hold it
  local holder
  holder="$(dsp_get "$id" | jq -r '"\(.state)|\(.holder.machine // "")|\(.holder.actor // "")"')"
  if [ "$holder" != "accepted|${machine}|${actor}" ]; then
    echo "⚠ ${id}: accept lost the race (now: ${holder%%|*} by ${holder#*|})" >&2
    return 3
  fi
  dsp_bus_msg "dispatch ${id} accepted on ${machine} (task ${task}, lease ${lease_s}s)"
  printf '%s\n' "$id"
  return 0
}

cmd_accept() {
  local auto=0 want="" quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --auto) auto=1; shift ;;
      --quiet|-q) quiet=1; shift ;;
      -h|--help) usage; return 0 ;;
      *) want="$1"; shift ;;
    esac
  done
  [ "$auto" = 1 ] || [ -n "$want" ] || { echo "usage: cobus dispatch accept <dispatch-id>|--auto" >&2; return 2; }
  dsp_sync
  cmd_reap --quiet   # lapsed leases become re-acceptable first
  local machine actor caps row id
  machine="$(dsp_machine)"; actor="$(ck_actor)"; caps="$(dsp_caps_json)"
  if [ -n "$want" ]; then
    row="$(dsp_get "$want")"
    [ -n "$row" ] || { echo "cobus dispatch: unknown dispatch id '${want}'" >&2; return 1; }
    case "$(printf '%s' "$row" | jq -r '.state')" in
      open|released|expired) ;;
      *) echo "cobus dispatch: ${want} is $(printf '%s' "$row" | jq -r '.state') — nothing to accept" >&2; return 1 ;;
    esac
    if ! dsp_match "$(printf '%s' "$row" | jq -c '.target')" "$machine" "$actor" "$caps"; then
      echo "cobus dispatch: ${want} targets $(dsp_describe_target "$(printf '%s' "$row" | jq -c '.target')"); this is ${machine}/${actor} caps=${caps} — not accepting" >&2
      return 4
    fi
    id="$(dsp_accept_row "$row")" || return $?
    [ "$quiet" = 1 ] || echo "🤝 accepted ${id} on ${machine}/${actor} — task $(printf '%s' "$row" | jq -r '.task')"
    return 0
  fi
  # --auto: oldest matching open dispatch (projection is priority, created order)
  local rows; rows="$(dsp_project | jq -c 'select(.state == "open" or .state == "released" or .state == "expired")')"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    dsp_match "$(printf '%s' "$row" | jq -c '.target')" "$machine" "$actor" "$caps" || continue
    if id="$(dsp_accept_row "$row" 2>/dev/null)"; then
      if [ "$quiet" = 1 ]; then
        printf '%s\t%s\t%s\n' "$id" "$(printf '%s' "$row" | jq -r '.task')" "$(printf '%s' "$row" | jq -r '.title')"
      else
        echo "🤝 accepted ${id} on ${machine}/${actor} — task $(printf '%s' "$row" | jq -r '.task'): $(printf '%s' "$row" | jq -r '.title')"
      fi
      return 0
    fi
    dsp_reload   # lost a race — keep looking
  done <<< "$rows"
  [ "$quiet" = 1 ] || echo "🟢 nothing to accept for ${machine}/${actor} (caps ${caps})"
  return 1
}

# guard: caller must hold <id>; sets ROW
dsp_require_holder() {
  local id="$1" st hm ha
  ROW="$(dsp_get "$id")"
  [ -n "$ROW" ] || { echo "cobus dispatch: unknown dispatch id '${id}'" >&2; return 1; }
  st="$(printf '%s' "$ROW" | jq -r '.state')"
  [ "$st" = accepted ] || { echo "cobus dispatch: ${id} is ${st}, not accepted" >&2; return 1; }
  hm="$(printf '%s' "$ROW" | jq -r '.holder.machine // ""')"; ha="$(printf '%s' "$ROW" | jq -r '.holder.actor // ""')"
  if [ "$hm" != "$(dsp_machine)" ] || [ "$ha" != "$(ck_actor)" ]; then
    [ "${DSP_FORCE:-0}" = 1 ] || { echo "cobus dispatch: ${id} is held by ${hm}/${ha}, not by you (set DSP_FORCE=1 to override)" >&2; return 1; }
  fi
  return 0
}

cmd_renew() {
  local id="" lease="" ROW quiet=0
  while [ $# -gt 0 ]; do
    case "$1" in --lease) lease="${2:-}"; shift 2 ;; --quiet|-q) quiet=1; shift ;; *) id="$1"; shift ;; esac
  done
  [ -n "$id" ] || { echo "usage: cobus dispatch renew <id> [--lease secs]" >&2; return 2; }
  dsp_sync
  dsp_require_holder "$id" || return 1
  [ -n "$lease" ] || lease="$(printf '%s' "$ROW" | jq -r '.lease_s // 0')"
  case "$lease" in ''|*[!0-9]*|0) lease="$DEFAULT_LEASE" ;; esac
  local until payload; until=$(( $(now) + lease ))
  payload="$(jq -nc --arg id "$id" --arg m "$(dsp_machine)" --arg a "$(ck_actor)" --argjson u "$until" --argjson ts "$(now)" \
    '{id:$id, by:{machine:$m, actor:$a}, lease_until:$u, ts:$ts}')"
  dsp_emit dispatch.renewed "$id" "$payload" "$until" || return 1
  bash "$DSP_LEDGER" claim "$(printf '%s' "$ROW" | jq -r '.task')" >/dev/null 2>&1 || true
  dsp_sync
  [ "$quiet" = 1 ] || echo "🔁 renewed ${id} for ${lease}s (until $(date -d "@$until" '+%H:%M:%S' 2>/dev/null || printf '%s' "$until"))"
  return 0
}

cmd_release() {
  local id="" reason="released" ROW
  while [ $# -gt 0 ]; do
    case "$1" in --reason) reason="${2:-}"; shift 2 ;; *) id="$1"; shift ;; esac
  done
  [ -n "$id" ] || { echo "usage: cobus dispatch release <id> [--reason ...]" >&2; return 2; }
  dsp_sync
  dsp_require_holder "$id" || return 1
  local payload
  payload="$(jq -nc --arg id "$id" --arg m "$(printf '%s' "$ROW" | jq -r '.holder.machine')" \
    --arg a "$(printf '%s' "$ROW" | jq -r '.holder.actor')" --arg r "$reason" --argjson ts "$(now)" \
    '{id:$id, by:{machine:$m, actor:$a}, reason:$r, ts:$ts}')"
  dsp_emit dispatch.released "$id" "$payload" || return 1
  dsp_sync
  echo "↩ released ${id} (${reason}) — re-acceptable by any matching machine"
  return 0
}

cmd_done() {
  local id="${1:-}" ROW task
  [ -n "$id" ] || { echo "usage: cobus dispatch done <id>" >&2; return 2; }
  dsp_sync
  ROW="$(dsp_get "$id")"
  [ -n "$ROW" ] || { echo "cobus dispatch: unknown dispatch id '${id}'" >&2; return 1; }
  case "$(printf '%s' "$ROW" | jq -r '.state')" in
    done) echo "✓ ${id} already done"; return 0 ;;
  esac
  task="$(printf '%s' "$ROW" | jq -r '.task')"
  local payload
  payload="$(jq -nc --arg id "$id" --arg m "$(dsp_machine)" --arg a "$(ck_actor)" --argjson ts "$(now)" \
    '{id:$id, by:{machine:$m, actor:$a}, ts:$ts}')"
  dsp_emit dispatch.done "$id" "$payload" || return 1
  bash "$DSP_LEDGER" "done" "$task" >/dev/null 2>&1 || true
  dsp_sync
  echo "✅ ${id} done — task '${task}' marked done in the ledger"
  return 0
}

cmd_reap() {
  local quiet=0 n=0 row id hm ha until payload rows
  case "${1:-}" in --quiet|-q) quiet=1 ;; esac
  rows="$(dsp_project | jq -c 'select(.lapsed == true)')"
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    id="$(printf '%s' "$row" | jq -r '.id')"
    hm="$(printf '%s' "$row" | jq -r '.holder.machine // ""')"; ha="$(printf '%s' "$row" | jq -r '.holder.actor // ""')"
    until="$(printf '%s' "$row" | jq -r '.lease_until // 0')"
    payload="$(jq -nc --arg id "$id" --arg hm "$hm" --arg ha "$ha" --argjson u "$until" \
      --arg rm "$(dsp_machine)" --arg ra "$(ck_actor)" --argjson ts "$(now)" \
      '{id:$id, holder:{machine:$hm, actor:$ha}, lease_until:$u, reaped_by:{machine:$rm, actor:$ra}, ts:$ts}')"
    dsp_emit dispatch.expired "$id" "$payload" && n=$(( n + 1 ))
    [ "$quiet" = 1 ] || echo "⏰ ${id}: lease held by ${hm}/${ha} lapsed at ${until} — back to open"
  done <<< "$rows"
  [ "$n" -gt 0 ] && dsp_sync
  [ "$quiet" = 1 ] || echo "reaped ${n} lapsed dispatch(es)"
  return 0
}

cmd_ls() {
  local filter="active" json=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --mine) filter=mine ;; --open) filter=open ;; --all) filter=all ;; --json) json=1 ;;
      -h|--help) usage; return 0 ;;
    esac; shift
  done
  local machine actor
  machine="$(dsp_machine)"; actor="$(ck_actor)"
  local rows
  rows="$(dsp_project | jq -c --arg f "$filter" --arg m "$machine" --arg a "$actor" '
    select(
      if $f == "all" then true
      elif $f == "open" then (.state == "open" or .state == "released" or .state == "expired")
      elif $f == "mine" then ((.holder.machine == $m and .holder.actor == $a) or (.from.machine == $m and .from.actor == $a))
      else .state != "done" end)')"
  if [ "$json" = 1 ]; then printf '%s\n' "$rows" | jq -s '.' ; return 0; fi
  if [ -z "$rows" ]; then echo "📭 no dispatches ($filter) — this is ${machine}/${actor}"; return 0; fi
  echo "📬 dispatches ($filter) — this is ${machine}/${actor}, mode $(logstore_mode)"
  printf '%-16s %-30s %-28s %-9s %-24s %s\n' ID TASK TARGET STATE HOLDER LEASE
  printf '%s\n' "$rows" | jq -r '
    def tgt: [ (if (.target.machine // "") != "" then .target.machine + (if (.target.actor // "") != "" then "/" + .target.actor else "" end) else empty end),
               (if ((.target.needs // {}) | length) > 0 then ((.target.needs|to_entries|map(.key + "=" + (.value|tostring))) | join(",")) else empty end) ]
             | if length == 0 then "anyone" else join(" ") end;
    def lease: if .state == "accepted" then (if .lease_left < 0 then "LAPSED " + ((-.lease_left)|tostring) + "s" else (.lease_left|tostring) + "s" end) else "-" end;
    def holder: if .holder then (.holder.machine + "/" + .holder.actor) else "-" end;
    [ .id, (.task|.[0:30]), (tgt|.[0:28]), .state, (holder|.[0:24]), lease ] | @tsv' \
    | while IFS=$'\t' read -r a b c d e f; do printf '%-16s %-30s %-28s %-9s %-24s %s\n' "$a" "$b" "$c" "$d" "$e" "$f"; done
  return 0
}

cmd_peers() {
  local rows; rows="$(dsp_peers)"
  [ -n "$rows" ] || { echo "no presence heartbeats in the log yet (see \`cobus heartbeat\`)"; return 0; }
  printf '%s\n' "$rows" | jq -r '"\(if .alive then "●" else "○" end) \(.machine)/\(.actor)  caps=\(.caps|tojson)  task=\(.task // "-")  age=\(now - .ts | floor)s ttl=\(.ttl_s)s"'
}

cmd_whoami() {
  printf 'machine: %s\nactor:   %s\ncaps:    %s\nmode:    %s\n' "$(dsp_machine)" "$(ck_actor)" "$(dsp_caps_json)" "$(logstore_mode)"
}

# ── worker loop ──────────────────────────────────────────────────────────────
cmd_worker() {
  local interval="$WORKER_INTERVAL" exec_cmd="" once=0 max_idle=0 idle=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval) interval="${2:-}"; shift 2 ;;
      --exec) exec_cmd="${2:-}"; shift 2 ;;
      --once) once=1; shift ;;
      --max-idle) max_idle="${2:-0}"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) echo "cobus dispatch worker: unknown arg $1" >&2; return 2 ;;
    esac
  done
  case "$interval" in ''|*[!0-9]*|0) interval="$WORKER_INTERVAL" ;; esac
  case "$max_idle" in ''|*[!0-9]*) max_idle=0 ;; esac

  local machine actor stopping=0 child="" renew_pid="" cur_id=""
  machine="$(dsp_machine)"; actor="$(ck_actor)"
  export COORDKIT_SESSION_ID="${COORDKIT_SESSION_ID:-dispatch-worker-$$}"
  [ -f "$DSP_BUS" ] && bash "$DSP_BUS" heartbeat >/dev/null 2>&1   # ledger claim liveness on this machine

  on_signal() {
    [ "$stopping" = 1 ] && return
    stopping=1
    echo
    echo "cobus dispatch worker: caught signal — stopping"
    [ -n "$renew_pid" ] && kill "$renew_pid" 2>/dev/null
    if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
      kill -TERM "$child" 2>/dev/null
      wait "$child" 2>/dev/null
      [ -n "$cur_id" ] && DSP_FORCE=1 cmd_release "$cur_id" --reason "worker interrupted (signal)" >/dev/null 2>&1
    elif [ -n "$cur_id" ]; then
      DSP_FORCE=1 cmd_release "$cur_id" --reason "worker interrupted (signal)" >/dev/null 2>&1
    fi
  }
  trap on_signal INT TERM

  echo "cobus dispatch worker: ${machine}/${actor} caps=$(dsp_caps_json) mode=$(logstore_mode) interval=${interval}s${exec_cmd:+ exec='$exec_cmd'}"
  while [ "$stopping" = 0 ]; do
    dsp_sync
    local line id task title rc
    if line="$(cmd_accept --auto --quiet 2>/dev/null)"; then
      idle=0
      id="${line%%$'\t'*}"; line="${line#*$'\t'}"; task="${line%%$'\t'*}"; title="${line#*$'\t'}"
      cur_id="$id"
      echo "[worker] accepted ${id} — task ${task}: ${title}"
      if [ -z "$exec_cmd" ]; then
        echo "[worker]   no --exec configured: leaving ${id} accepted for a human/agent on this machine (renew/done it by hand)"
        cur_id=""
      else
        local lease_s renew_every
        lease_s="$(dsp_get "$id" | jq -r '.lease_s // 0')"
        case "$lease_s" in ''|*[!0-9]*|0) lease_s="$DEFAULT_LEASE" ;; esac
        renew_every=$(( lease_s / 3 )); [ "$renew_every" -lt 5 ] && renew_every=5
        COORDKIT_DISPATCH_ID="$id" COORDKIT_TASK_ID="$task" COORDKIT_TASK_TITLE="$title" \
          bash -c "$exec_cmd" &
        child=$!
        ( while kill -0 "$child" 2>/dev/null; do
            sleep "$renew_every"
            kill -0 "$child" 2>/dev/null && bash "${BASH_SOURCE[0]}" renew "$id" --quiet >/dev/null 2>&1
          done ) &
        renew_pid=$!
        wait "$child" 2>/dev/null; rc=$?
        child=""
        kill "$renew_pid" 2>/dev/null; wait "$renew_pid" 2>/dev/null; renew_pid=""
        [ "$stopping" = 1 ] && break
        if [ "$rc" -eq 0 ]; then
          cmd_done "$id" >/dev/null 2>&1 && echo "[worker] done ${id} (exit 0)"
        else
          cmd_release "$id" --reason "worker command exited ${rc}" >/dev/null 2>&1
          echo "[worker] released ${id} (command exited ${rc})"
        fi
        cur_id=""
      fi
      [ "$once" = 1 ] && break
      continue
    fi
    idle=$(( idle + 1 ))
    [ "$once" = 1 ] && { echo "[worker] nothing to accept"; break; }
    if [ "$max_idle" -gt 0 ] && [ "$idle" -ge "$max_idle" ]; then echo "[worker] idle ${idle} polls — exiting"; break; fi
    sleep "$interval" &
    wait $! 2>/dev/null
  done
  trap - INT TERM
  return 0
}

# ── dispatch ─────────────────────────────────────────────────────────────────
verb="${1:-}"
case "$verb" in
  ""|-h|--help|help) usage; exit 0 ;;
  accept)  shift; cmd_accept "$@" ;;
  renew)   shift; cmd_renew "$@" ;;
  release) shift; cmd_release "$@" ;;
  done)    shift; cmd_done "$@" ;;
  reap)    shift; cmd_reap "$@" ;;
  ls|list) shift; cmd_ls "$@" ;;
  worker)  shift; cmd_worker "$@" ;;
  peers)   shift; cmd_peers "$@" ;;
  whoami)  shift; cmd_whoami "$@" ;;
  create|new) shift; cmd_create "$@" ;;
  *)       cmd_create "$@" ;;
esac
