#!/usr/bin/env bash
# shellcheck shell=bash
# bus.sh — a per-repo "command center" so several coordkit instances
# running in the same project are aware of each other.
#
# AWARENESS layer (complements guard.sh, the opt-in anti-clobber layer): the
# guard HARD-BLOCKS edits to files changed on disk, but only when the resolved
# enforcement mode is "guard"; this bus RECORDS who's live / what they're doing /
# what they touch, warns SOFTLY on collisions, gives a live UI, a task board, and
# inter-instance messaging. The bus never blocks a tool call, in any mode.
#
# State in <repo>/.coordkit-bus/:
#   agents/<sid>.json           heartbeat {sid,host,branch,cwd,task,files,last_seen}
#   claims/<sha>.json           soft FILE lock {path,sid,ts} — unrelated to TASK claims
#   subagents/<sid>/<tid>.json  a currently-running subagent this session launched:
#                                {sid,tool_use_id,subagent_type,description,started_at}
#                                — written at PreToolUse/Task, removed at PostToolUse/Task
#                                (or on session end / gc if the session dies mid-call)
#   inbox/<sid>/*.msg   messages waiting for that instance
#   activity.log        feed: "<iso>\t<sid8>\t<verb>\t<detail>"
#
# `claim`/`done`/`tasks` are a free-text front-end over ledger.sh's own
# task queue (task/claim/next/done) — NOT a separate board. There used to be a
# second, simpler markdown board (TASKS.md) here; it's gone. `claim "<desc>"`
# now publishes+leases in one step via the ledger, `done "<text>"` resolves a
# literal-substring match against open ledger tasks, `tasks` prints the
# ledger's own projected board. See docs/LEDGER.md.
#
# Reached from hooks through scripts/coord.sh, the single dispatcher, which
# SOURCES this file and calls bus_run:
#   SessionStart            -> start    register + inbox / file-overlap alerts
#   UserPromptSubmit        -> task     record current task + deliver inbox messages
#   PostToolUse Write|Edit|NotebookEdit|Read|Bash -> record  feed + heartbeat + claims
#   PreToolUse  Write|Edit|NotebookEdit -> check  soft collision warning + desktop notify
#   PreToolUse  Task        -> subagent-start  record a running subagent + soft same-type heads-up
#   PostToolUse Task        -> subagent-stop   drop that subagent's running record
#   SessionEnd              -> stop     drop heartbeat + release claims + subagent records
#
# SOURCING CONTRACT — the whole phase dispatch lives in bus_main(), which still
# uses `exit` freely for control flow (it predates being a library and its
# internals are deliberately untouched). Callers therefore use bus_run, which
# runs bus_main in a SUBSHELL so those exits terminate the phase, not the
# caller's session:
#   . bus.sh ; bus_run record <<<"$hook_json"
# Executing the file directly still works exactly as before.
#
# The `badge` statusline phase is NOT wired by the plugin manifest — a plugin
# manifest can't register a statusLine command, so the user must wire it in
# their settings.json by hand, e.g.:
#   "statusLine": {"type":"command","command":"bash <path>/bus.sh badge"}
# It prints "🛰️ N live" and doubles as a throttled heartbeat tick.
# See docs/STATUSLINE.md for the full rationale and the supported install path.
#
# By hand:
#   bus.sh dashboard [repo]   one-shot snapshot (used by /bus)
#   bus.sh watch [repo]       live auto-refreshing monitor (run in a pane)
#   bus.sh claim "<desc>"     publish + immediately lease a ledger task
#   bus.sh done "<text>"      mark the first matching open task done
#   bus.sh tasks              print the ledger's projected task board
#   bus.sh msg <target> <text>   message all|<sid8>|branch:<name>
#
# Defensive: on any internal trouble it exits 0 (allow) so a bug here can never
# wedge a session.
set -uo pipefail

[ -n "${_CK_BUS_SH:-}" ] && return 0 2>/dev/null
_CK_BUS_SH=1

bus_main() {

phase="${1:-dashboard}"

STALE_SOFT=900       # 15 min -> shown as "idle"
STALE_HARD=21600     # 6 h    -> heartbeat pruned
TICK_MIN=10          # min seconds between statusline heartbeat ticks; also
                     # throttles heartbeat()'s piggybacked fleet-registry write
NOTIFY_DEBOUNCE=60   # min seconds between desktop notifications per file

now()  { date +%s; }
iso()  { date '+%Y-%m-%d %H:%M:%S'; }
hhmm() { date '+%H:%M:%S'; }
mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Filesystem-safe key for a path, mirroring guard.sh's _guard_hashkey: try the
# hashers that actually exist on this box (Linux ships sha1sum/md5sum; macOS
# only shasum/md5), then fall back to the sanitized path. Hardcoding sha1sum
# would yield an EMPTY key on macOS, collapsing every file's claim onto one
# path and silently breaking collision detection.
hashkey() {
  local f="$1" k=""
  k="$(printf '%s' "$f" | sha1sum 2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | shasum  2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | md5sum  2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | md5     2>/dev/null)";                 [ -n "$k" ] && { printf '%s' "$k"; return; }
  printf '%s' "$f" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-200
}

# resolve_root() / branch_of() — canonical implementations, shared with the
# ledger, the transports and the CLI entrypoints so no two of them can ever
# resolve a different .coordkit-bus tree. The host runtime may inject
# COORDKIT_PLUGIN_ROOT; the fallback keeps a direct `bash scripts/bus.sh`
# invocation working from a repo checkout.
# A missing common.sh means a broken install; exit 0 rather than run on with an
# unresolvable root, per this script's never-wedge-a-session rule.
# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh" || exit 0

# ── input handling ──────────────────────────────────────────────────────────
# dashboard/watch take a repo arg; everything else reads hook/statusline JSON.
case "$phase" in
  dashboard|watch|frame|fleet)
    input=""; cwd="${2:-$PWD}"; sid="cli" ;;
  claim|done|tasks|heartbeat)
    # Real session id when available (falls back to "cli" for a bare shell
    # invocation) — these delegate to the ledger's task queue, whose lease/
    # work-stealing liveness check needs a sid with an actual bus heartbeat,
    # not the constant "cli" (which never has one and would look instantly
    # abandoned). msg keeps the "cli"-only behavior below; see its own note.
    input=""; cwd="$(ck_project_dir)"; sid="$(ck_session_id)" ;;
  msg)
    input=""; cwd="$(ck_project_dir)"; sid="cli" ;;
  *)
    input="$(cat)"
    cwd="$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)"
    [ -z "$cwd" ] && cwd="$PWD"
    sid="$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)" ;;
esac

# Session and tool-use ids become path components below. Native hosts provide
# UUID-like values, but direct hook invocation is still untrusted input; fold
# anything path-shaped to a stable key before touching the filesystem.
case "$sid" in
  ""|.|..|*/*|*\\*) sid="session-$(hashkey "$sid")" ;;
esac

root="$(resolve_root "$cwd")"
bus="${root}/.coordkit-bus"
agents="${bus}/agents"; claims="${bus}/claims"; inbox="${bus}/inbox"
subagents="${bus}/subagents"
log="${bus}/activity.log"
sid8="${sid:0:8}"
curbr="$(branch_of "$cwd")"
host="$(ck_host)"

# Compact hook-context controls. Environment variables take precedence over
# the repo's optional [context] table; defaults keep hook payloads small even
# when no config has been initialized yet. The dashboard remains the full,
# on-demand view.
context_cfg_value() { # <key>
  local key="$1" cfg
  cfg="$(ck_coord_toml "$root")"
  [ -f "$cfg" ] || return 1
  awk -v want="$key" '
    /^[[:space:]]*\[/ {
      section=$0; sub(/^[[:space:]]*\[/,"",section); sub(/\].*$/,"",section)
      gsub(/[[:space:]]/,"",section); next
    }
    section == "context" {
      line=$0; sub(/[[:space:]]*#.*/,"",line)
      split(line,p,"="); k=p[1]; gsub(/[[:space:]]/,"",k)
      if (k == want) {
        sub(/^[^=]*=[[:space:]]*/,"",line); gsub(/^[[:space:]\"]+|[[:space:]\"]+$/,"",line)
        print line; exit
      }
    }
  ' "$cfg" 2>/dev/null
}

context_int_setting() { # <env-name> <toml-key> <default> <minimum> [legacy-env]
  local env_name="$1" key="$2" fallback="$3" minimum="$4" legacy="${5:-}" value
  value="${!env_name:-}"
  case "$value" in ''|*[!0-9]*) ;; *) [ "$value" -ge "$minimum" ] && { printf '%s' "$value"; return; } ;; esac
  if [ -n "$legacy" ]; then
    value="${!legacy:-}"
    case "$value" in ''|*[!0-9]*) ;; *) [ "$value" -ge "$minimum" ] && { printf '%s' "$value"; return; } ;; esac
  fi
  value="$(context_cfg_value "$key" 2>/dev/null || true)"
  case "$value" in ''|*[!0-9]*) ;; *) [ "$value" -ge "$minimum" ] && { printf '%s' "$value"; return; } ;; esac
  printf '%s' "$fallback"
}

CONTEXT_MAX_PEERS="$(context_int_setting COORDKIT_CONTEXT_MAX_PEERS max_peers 1 1)"
CONTEXT_MAX_MESSAGES="$(context_int_setting COORDKIT_CONTEXT_MAX_MESSAGES max_messages 2 1)"
CONTEXT_BODY_CHARS="$(context_int_setting COORDKIT_CONTEXT_EVENT_BODY_CHARS event_body_chars 80 24 COORDKIT_CONTEXT_BODY_CHARS)"
CONTEXT_COLLISION_TOKENS="$(context_int_setting COORDKIT_CONTEXT_COLLISION_TOKENS collision_tokens 64 32)"
CONTEXT_BYTES_PER_TOKEN="$(context_int_setting COORDKIT_CONTEXT_BYTES_PER_TOKEN bytes_per_token 4 1)"

compact_field() { # <untrusted display text>
  printf '%s' "$1" | tr '\000-\037' ' ' | cut -c1-"$CONTEXT_BODY_CHARS"
}

# Path to the ledger, whose task queue backs claim/done/tasks below.
LEDGER_SH="$(ck_plugin_root)/scripts/ledger.sh"

ensure_dirs() {
  mkdir -p "$agents" "$claims" "$inbox" "$subagents" 2>/dev/null || return 1
  [ -f "${bus}/.gitignore" ] || printf '*\n' > "${bus}/.gitignore" 2>/dev/null
  ck_git_info_exclude_add "$root" '/.coordkit-bus/'
  return 0
}

prune_dead() {
  local t f last cf owner sd; t="$(now)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$last" ] && last=0
    [ $(( t - last )) -gt "$STALE_HARD" ] && rm -f "$f" "${f}.lock" 2>/dev/null
  done
  # Also drop claims whose owning session has no live agent record. `stop`
  # releases a session's claims, but a crashed/killed session never runs it,
  # so its soft locks would otherwise linger forever. Runs AFTER the agents
  # loop above so agent_live sees hard-stale records already pruned.
  for cf in "$claims"/*.json; do
    [ -e "$cf" ] || continue
    owner="$(jq -r '.sid // ""' "$cf" 2>/dev/null)"
    { [ -z "$owner" ] || ! agent_live "$owner"; } && rm -f "$cf" 2>/dev/null
  done
  # And subagent dirs for sessions that crashed mid-call (a live session
  # cleans up its own via subagent-stop / stop; a dead one never gets to).
  for sd in "$subagents"/*/; do
    [ -d "$sd" ] || continue
    owner="$(basename "$sd")"
    agent_live "$owner" || rm -rf "$sd" 2>/dev/null
  done
  return 0   # never let the loop's last test short-circuit `... && heartbeat`
}

heartbeat() {  # $1=task (or "") $2=file-to-append (or "")
  ensure_dirs || return 0
  local rec="${agents}/${sid}.json" task_set="${1:-}" file_add="${2:-}"
  local t br prev='{}'; t="$(now)"; br="$curbr"
  # tmp+mv makes each WRITE atomic, but read-then-write isn't: two callers for
  # the same sid (e.g. the statusline badge tick racing a hook heartbeat) can
  # both read the old record and the loser's field update is lost. Serialize the
  # whole read-modify-write under a per-sid lock (same flock idiom as common.sh's
  # ck_clock_c) so unrelated sessions' heartbeats stay independent.
  ( flock 9
    [ -f "$rec" ] && prev="$(cat "$rec" 2>/dev/null || printf '{}')"
    printf '%s' "$prev" | jq \
      --arg sid "$sid" --arg host "$host" --arg br "$br" --arg cwd "$cwd" \
      --argjson t "$t" --arg task "$task_set" --arg file "$file_add" '
        . as $p
        | {sid:$sid, host:$host, branch:$br, cwd:$cwd, last_seen:$t}
        + {task:  ( if $task != "" then $task else ($p.task // "") end )}
        + {files: ( ($p.files // [])
                    | if $file != "" then (. + [$file]) else . end
                    | reverse | unique | .[0:8] )}
      ' > "${rec}.tmp" 2>/dev/null && mv "${rec}.tmp" "$rec" 2>/dev/null
  ) 9>"${rec}.lock" 2>/dev/null
  fleet_register
  return 0
}

# Piggybacks on heartbeat()'s own call frequency — no separate/unthrottled
# write path. heartbeat() itself fires on every SessionStart/UserPromptSubmit/
# tool-use, which is too hot a cadence for a file shared across every repo on
# the machine, so this is throttled independently via a per-repo marker file
# (same debounce idiom as the desktop-notify NOTIFY_DEBOUNCE marker below),
# reusing TICK_MIN as the interval. Registers ONLY this repo's own root ->
# {last_seen} in $(ck_data_dir)/fleet.json — see the `fleet` phase for the
# cross-repo read side, which re-derives liveness from each registered repo's
# OWN .coordkit-bus/agents/*.json rather than trusting a cached count here.
fleet_register() {
  local mk="${bus}/.fleet-tick" d f
  if [ -f "$mk" ]; then
    [ $(( $(now) - $(mtime "$mk") )) -lt "$TICK_MIN" ] && return 0
  fi
  d="$(ck_data_dir)"; f="${d}/fleet.json"
  mkdir -p "$d" 2>/dev/null || return 0
  : > "$mk" 2>/dev/null
  ( flock 9
    local prev='{}'
    [ -f "$f" ] && prev="$(cat "$f" 2>/dev/null || printf '{}')"
    printf '%s' "$prev" | jq --arg p "$root" --argjson t "$(now)" \
      '(. // {}) | .repos[$p] = {last_seen: $t}' \
      > "${f}.tmp" 2>/dev/null && mv "${f}.tmp" "$f" 2>/dev/null
  ) 9>"${f}.lock" 2>/dev/null
  return 0
}

agent_age()    { local f="${agents}/$1.json" l; l="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$l" ] && l=0; echo $(( $(now) - l )); }
agent_live()   { [ -f "${agents}/$1.json" ] && [ "$(agent_age "$1")" -le "$STALE_HARD" ]; }

# tab-rows: sid8 \t host \t state \t age \t branch \t cwd \t task \t files
others_live() {
  # One jq per agent file (not one per field): @tsv also escapes any literal
  # tab inside task/branch, so the tab-separated contract stays intact.
  local t f s oh last age br cwd task files state; t="$(now)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r s oh last br cwd task files <<< "$(jq -r \
      '[.sid // "", .host // "unknown", .last_seen // 0, .branch // "?", .cwd // "", .task // "", ((.files // [])|join(", "))] | @tsv' \
      "$f" 2>/dev/null)"
    [ "$s" = "$sid" ] && continue
    case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
    age=$(( t - last )); [ "$age" -gt "$STALE_HARD" ] && continue
    state="live"; [ "$age" -gt "$STALE_SOFT" ] && state="idle"
    printf '%s\t%s\t%s\t%ss\t%s\t%s\t%s\t%s\n' "${s:0:8}" "$oh" "$state" "$age" "$br" "$cwd" "$task" "$files"
  done
}

# files touched by >=2 distinct live agents -> "path \t who"
collisions() {
  # One jq per agent file: sid + last_seen + the file list joined on US (\037),
  # which can't occur in a path, then split in-shell.
  local t f s last age fl rest; t="$(now)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    IFS=$'\t' read -r s last rest <<< "$(jq -r \
      '[.sid // "", .last_seen // 0, ((.files // [])|join("\u001f"))] | @tsv' \
      "$f" 2>/dev/null)"
    case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
    age=$(( t - last )); [ "$age" -gt "$STALE_HARD" ] && continue
    while IFS= read -r fl; do
      [ -n "$fl" ] && printf '%s\t%s\n' "${s:0:8}" "$fl"
    done <<< "$(printf '%s' "${rest:-}" | tr '\037' '\n')"
  done | sort -u | awk -F'\t' '{c[$2]++; who[$2]=who[$2] (who[$2]==""?"":", ") $1}
                                END{for(p in c) if(c[p]>1) printf "%s\t%s\n",p,who[p]}'
}

# Cross-repo counterpart of others_live(): given ANOTHER repo's root (not
# $root/$agents — those are always THIS repo), re-derive live/idle session
# counts and the distinct branches in use by reading straight from that
# repo's OWN .coordkit-bus/agents/*.json. Used only by the `fleet` phase.
#
# Deliberately a separate small pass rather than a generalized others_live()
# (parameterized bus dir + optional self-exclusion): others_live() is on the
# SessionStart hot path and reused by badge's classifier too, so reshaping its
# signature for a view-only cross-repo case risked more than this task
# warrants. It intentionally mirrors the SAME age/state formula (STALE_SOFT/
# STALE_HARD against last_seen) so liveness isn't redefined a second time,
# just re-applied to a different agents/ directory.
# Prints "<live>\t<idle>\t<branch1,branch2,...>".
fleet_repo_stats() {
  local repo_root="$1" af al abr aage live=0 idle=0 branches="" t; t="$(now)"
  for af in "${repo_root}/.coordkit-bus/agents"/*.json; do
    [ -e "$af" ] || continue
    IFS=$'\t' read -r al abr <<< "$(jq -r '[.last_seen // 0, .branch // "?"] | @tsv' "$af" 2>/dev/null)"
    case "${al:-}" in ''|*[!0-9]*) al=0 ;; esac
    aage=$(( t - al )); [ "$aage" -gt "$STALE_HARD" ] && continue
    if [ "$aage" -gt "$STALE_SOFT" ]; then idle=$(( idle + 1 )); else live=$(( live + 1 )); fi
    case ",${branches}," in *",${abr},"*) ;; *) branches="${branches:+${branches},}${abr}" ;; esac
  done
  printf '%s\t%s\t%s\n' "$live" "$idle" "$branches"
}

inbox_count() {
  local box="${inbox}/${sid}" f n=0
  [ -d "$box" ] || { printf '0'; return; }
  for f in "$box"/*.msg; do [ -e "$f" ] && n=$(( n + 1 )); done
  printf '%s' "$n"
}

drain_inbox() {  # delivers at most CONTEXT_MAX_MESSAGES; excess stays queued
  local box="${inbox}/${sid}" f got=1 out="" shown=0 text
  [ -d "$box" ] || { printf ''; return 1; }
  for f in "$box"/*.msg; do
    [ -e "$f" ] || continue
    [ "$shown" -ge "$CONTEXT_MAX_MESSAGES" ] && continue
    text="$(cat "$f" 2>/dev/null)"
    out+="- $(compact_field "$text")"$'\n'
    rm -f "$f" 2>/dev/null
    shown=$(( shown + 1 )); got=0
  done
  # drop the now-empty per-sid dir so long-lived buses don't accumulate one
  # stub directory per session forever; rmdir no-ops if non-empty or gone.
  rmdir "$box" 2>/dev/null
  printf '%s' "$out"; return $got
}

notify() {  # best-effort desktop notification; never fails
  local title="$1" body="$2"
  # notify-send takes title/body as separate argv, so it needs no escaping.
  command -v notify-send >/dev/null 2>&1 && { notify-send -u normal "$title" "$body" >/dev/null 2>&1 & disown 2>/dev/null; return; }
  if command -v powershell.exe >/dev/null 2>&1; then
    # title/body are attacker-influenced (filenames, another session's branch
    # field) and get inlined into PowerShell single-quoted string literals, so
    # sanitize for THAT context: strip control chars/newlines (which would break
    # out of the -Command string) and double embedded single quotes ('->'')
    # which is the only metacharacter inside a PS single-quoted literal. An env
    # var can't carry these safely — WSL vars don't reach powershell.exe without
    # WSLENV — so inline escaping is the reliable path.
    local pt pb
    pt="$(printf '%s' "$title" | tr -d '\000-\037' | sed "s/'/''/g")"
    pb="$(printf '%s' "$body"  | tr -d '\000-\037' | sed "s/'/''/g")"
    powershell.exe -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('$pb','$pt')" >/dev/null 2>&1 & disown 2>/dev/null
  fi
}

case "$phase" in
  # ── SessionStart ──────────────────────────────────────────────────────────
  start)
    ensure_dirs && prune_dead && heartbeat "" ""
    msg_total="$(inbox_count)"
    msgs="$(drain_inbox)"; have_msgs=$?
    msg_shown="$msg_total"; [ "$msg_shown" -gt "$CONTEXT_MAX_MESSAGES" ] && msg_shown="$CONTEXT_MAX_MESSAGES"
    msg_hidden=$(( msg_total - msg_shown ))
    ctx=""; suppressed=0
    if [ "$have_msgs" -eq 0 ] && [ -n "$msgs" ]; then
      ctx+="CK inbox (${msg_shown}/${msg_total}):"$'\n'"${msgs}"
      if [ "$msg_hidden" -gt 0 ]; then ctx+="… +${msg_hidden} queued for next prompt"$'\n'; suppressed=$(( suppressed + msg_hidden )); fi
    fi
    collision_rows="$(collisions)"
    if [ -n "$collision_rows" ]; then
      collision_total="$(printf '%s\n' "$collision_rows" | awk 'NF{n++} END{print n+0}')"
      collision_shown=0
      ctx+="CK COLLISION: ${collision_total} overlapping file(s) with live peer(s):"$'\n'
      while IFS=$'\t' read -r path who; do
        [ -n "$path" ] || continue
        [ "$collision_shown" -ge "$CONTEXT_MAX_PEERS" ] && continue
        ctx+="- $(compact_field "$path") <- $(compact_field "$who")"$'\n'
        collision_shown=$(( collision_shown + 1 ))
      done <<< "$collision_rows"
      if [ "$collision_total" -gt "$collision_shown" ]; then
        ctx+="… +$(( collision_total - collision_shown )) more overlapping file(s)"$'\n'
        suppressed=$(( suppressed + collision_total - collision_shown ))
      fi
      ctx+="Reconcile before editing or committing."$'\n'
    fi
    [ -n "$ctx" ] && printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s},"coordkitMetrics":{"suppressed":%s}}\n' \
      "$(printf '%s' "$ctx" | jq -Rs .)" "$suppressed"
    exit 0
    ;;

  # ── UserPromptSubmit ──────────────────────────────────────────────────────
  task)
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
    prompt="$(printf '%s' "$prompt" | tr '\n' ' ' | cut -c1-120)"
    [ -n "$prompt" ] && heartbeat "$prompt" ""
    msg_total="$(inbox_count)"
    msgs="$(drain_inbox)"; have_msgs=$?
    if [ "$have_msgs" -eq 0 ] && [ -n "$msgs" ]; then
      msg_shown="$msg_total"; [ "$msg_shown" -gt "$CONTEXT_MAX_MESSAGES" ] && msg_shown="$CONTEXT_MAX_MESSAGES"
      msg_hidden=$(( msg_total - msg_shown ))
      ctx="CK inbox (${msg_shown}/${msg_total}):"$'\n'"${msgs}"
      [ "$msg_hidden" -gt 0 ] && ctx+="… +${msg_hidden} queued for next prompt"$'\n'
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s},"coordkitMetrics":{"suppressed":%s}}\n' \
        "$(printf '%s' "$ctx" | jq -Rs .)" "$msg_hidden"
    fi
    exit 0
    ;;

  # ── PostToolUse feed ──────────────────────────────────────────────────────
  record)
    tn="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
    # NotebookEdit names its target `notebook_path`, not `file_path` (same as guard.sh).
    file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
    cmd="$(printf '%s' "$input"  | jq -r '.tool_input.command // empty' 2>/dev/null)"
    ensure_dirs || exit 0
    case "$tn" in
      Write|Edit|NotebookEdit)
        [ -z "$file" ] && exit 0
        rel="${file#"$root"/}"; heartbeat "" "$rel"
        printf '%s\t%s\tedit\t%s\n' "$(iso)" "$sid8" "$rel" >> "$log" 2>/dev/null
        key="$(hashkey "$file")"
        jq -n --arg p "$rel" --arg sid "$sid" --argjson ts "$(now)" \
          '{path:$p, sid:$sid, ts:$ts}' > "${claims}/${key}.json" 2>/dev/null ;;
      Read)
        [ -z "$file" ] && exit 0
        rel="${file#"$root"/}"; heartbeat "" ""
        printf '%s\t%s\tread\t%s\n' "$(iso)" "$sid8" "$rel" >> "$log" 2>/dev/null ;;
      Bash)
        [ -z "$cmd" ] && exit 0
        cmd="$(printf '%s' "$cmd" | tr '\n' ' ' | cut -c1-70)"; heartbeat "" ""
        printf '%s\t%s\tbash\t%s\n' "$(iso)" "$sid8" "$cmd" >> "$log" 2>/dev/null ;;
      *) exit 0 ;;
    esac
    # cap the log
    if [ -f "$log" ] && [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 600 ]; then
      tail -n 350 "$log" > "${log}.tmp" 2>/dev/null && mv "${log}.tmp" "$log" 2>/dev/null
    fi
    exit 0
    ;;

  # ── PreToolUse soft collision warning (+ desktop notify, debounced) ───────
  check)
    file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
    [ -z "$file" ] && exit 0
    key="$(hashkey "$file")"
    cf="${claims}/${key}.json"; [ -f "$cf" ] || exit 0
    IFS=$'\t' read -r owner cts <<< "$(jq -r '[.sid // "", .ts // 0] | @tsv' "$cf" 2>/dev/null)"
    { [ -z "$owner" ] || [ "$owner" = "$sid" ]; } && exit 0
    agent_live "$owner" || exit 0
    # Warn only about a RECENT touch. The claim survives (the dashboard still
    # reports it as history), but a sibling that touched this file once an hour
    # ago and moved on shouldn't warn every edit for the rest of its session.
    case "${cts:-}" in ''|*[!0-9]*) cts=0 ;; esac
    [ $(( $(now) - cts )) -gt "$STALE_SOFT" ] && exit 0
    obr="$(jq -r '.branch // "?"' "${agents}/${owner}.json" 2>/dev/null)"
    ohost="$(jq -r '.host // "unknown"' "${agents}/${owner}.json" 2>/dev/null)"
    age="$(agent_age "$owner")"; rel="${file#"$root"/}"
    # debounced desktop notification
    mk="${bus}/.notify-${key}"
    do_notify=1
    if [ -f "$mk" ]; then [ $(( $(now) - $(mtime "$mk") )) -lt "$NOTIFY_DEBOUNCE" ] && do_notify=0; fi
    if [ "$do_notify" -eq 1 ]; then : > "$mk" 2>/dev/null; notify "coordkit collision" "${owner:0:8} (${ohost}, branch:${obr}) is also editing ${rel##*/}"; fi
    rel="$(compact_field "$rel")"
    msg="CK COLLISION: ${owner:0:8} host=${ohost} br=${obr} edited ${rel} ${age}s ago. Soft warning; reconcile. $(ck_coordination_hint "${owner:0:8}")"
    collision_bytes=$(( CONTEXT_COLLISION_TOKENS * CONTEXT_BYTES_PER_TOKEN ))
    msg="$(ck_utf8_prefix_bytes "$msg" "$collision_bytes")"
    printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' \
      "$(printf '%s' "$msg" | jq -Rs .)" "$(printf '%s' "$msg" | jq -Rs .)"
    exit 0
    ;;

  # ── PreToolUse Task: record a running subagent + soft same-type heads-up ──
  # Never denies — subagent launches are never blocked, same as everything
  # else on this bus. Single-writer file (only this sid ever writes its own
  # subagents/<sid>/ dir), so tmp+mv is enough — no lock needed, same as
  # heartbeat().
  subagent-start)
    ensure_dirs || exit 0
    tid="$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null)"
    # Subagent records are keyed on tool_use_id — a host that doesn't provide it
    # can't have its subagents paired start->stop, so tracking degrades to off
    # for this call. Leave a breadcrumb in the feed so it isn't a silent no-op
    # (guard.sh instead falls back to a single shared slot; that works there
    # because it only needs ONE snapshot, not one record per concurrent call).
    if [ -z "$tid" ]; then
      # once per session: this phase doesn't cap the log, so don't append per call
      if [ ! -e "${bus}/.no-tid-${sid}" ]; then
        : > "${bus}/.no-tid-${sid}" 2>/dev/null
        printf '%s\t%s\tsubagent\t(tracking off: host provided no tool_use_id)\n' "$(iso)" "$sid8" >> "$log" 2>/dev/null
      fi
      exit 0
    fi
    case "$tid" in *[!A-Za-z0-9._:-]*) tid="$(hashkey "$tid")" ;; esac
    stype="$(printf '%s' "$input" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
    sdesc="$(printf '%s' "$input" | jq -r '.tool_input.description // empty' 2>/dev/null)"
    heartbeat "" ""
    mkdir -p "${subagents}/${sid}" 2>/dev/null
    rec="${subagents}/${sid}/${tid}.json"
    jq -n --arg sid "$sid" --arg tid "$tid" --arg t "$stype" --arg d "$sdesc" --argjson ts "$(now)" \
      '{sid:$sid, tool_use_id:$tid, subagent_type:$t, description:$d, started_at:$ts}' \
      > "${rec}.tmp" 2>/dev/null && mv "${rec}.tmp" "$rec" 2>/dev/null
    [ -n "$stype" ] || exit 0
    # soft heads-up: is any OTHER live sibling already running this same subagent_type?
    hit="" hithost="unknown" hitdesc=""
    for f in "$subagents"/*/*.json; do
      [ -e "$f" ] || continue
      IFS=$'\t' read -r osid ot od <<< "$(jq -r \
        '[.sid // "", .subagent_type // "", .description // ""] | @tsv' "$f" 2>/dev/null)"
      [ "$osid" = "$sid" ] && continue
      [ "$ot" = "$stype" ] || continue
      agent_live "$osid" || continue
      hit="${osid:0:8}"
      hithost="$(jq -r '.host // "unknown"' "${agents}/${osid}.json" 2>/dev/null)"
      hitdesc="$od"; break
    done
    [ -n "$hit" ] || exit 0
    msg="CK subagent overlap: ${hit} host=${hithost} type=$(compact_field "$stype")"
    [ -n "$hitdesc" ] && msg+=" desc=$(compact_field "$hitdesc")"
    msg+=". Allowed; $(ck_coordination_hint "$hit")"
    msg="$(ck_utf8_prefix_bytes "$msg" "$(( CONTEXT_COLLISION_TOKENS * CONTEXT_BYTES_PER_TOKEN ))")"
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":%s,"additionalContext":%s}}\n' \
      "$(printf '%s' "$msg" | jq -Rs .)" "$(printf '%s' "$msg" | jq -Rs .)"
    exit 0
    ;;

  # ── PostToolUse Task: the subagent finished — drop its running record ─────
  subagent-stop)
    tid="$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null)"
    case "$tid" in *[!A-Za-z0-9._:-]*) tid="$(hashkey "$tid")" ;; esac
    [ -n "$tid" ] && rm -f -- "${subagents}/${sid}/${tid}.json" 2>/dev/null
    rmdir "${subagents}/${sid}" 2>/dev/null
    exit 0
    ;;

  # ── SessionEnd ────────────────────────────────────────────────────────────
  # Wired to SessionEnd only (NOT Stop): Stop fires at the end of every
  # assistant turn, which would drop the heartbeat + release claims mid-session
  # and make the instance invisible to /bus for most of its life.
  stop)
    rm -f "${agents}/${sid}.json" "${agents}/${sid}.json.lock" "${bus}/.no-tid-${sid}" 2>/dev/null
    for cf in "$claims"/*.json; do
      [ -e "$cf" ] || continue
      [ "$(jq -r '.sid // ""' "$cf" 2>/dev/null)" = "$sid" ] && rm -f "$cf" 2>/dev/null
    done
    # covers any subagent that was still running when the session ended
    # (crashed/interrupted before its own PostToolUse/Task could fire)
    rm -rf -- "${subagents:?}/${sid}" 2>/dev/null
    # drop our own inbox dir if drained; rmdir no-ops if it still holds
    # undelivered messages (leaving them for a possible late reader).
    rmdir "${inbox}/${sid}" 2>/dev/null
    exit 0
    ;;

  # ── statusline badge (+ throttled heartbeat tick) ─────────────────────────
  badge)
    [ -d "$agents" ] || exit 0
    rec="${agents}/${sid}.json"
    do_tick=1
    if [ -f "$rec" ]; then
      l="$(jq -r '.last_seen // 0' "$rec" 2>/dev/null)"; [ -z "$l" ] && l=0
      [ $(( $(now) - l )) -lt "$TICK_MIN" ] && do_tick=0
    fi
    [ "$do_tick" -eq 1 ] && heartbeat "" ""
    # Count DISTINCT sessions (by 8-char sid — the identity the rest of the bus
    # displays) so duplicate or stub registrations for one session can't inflate
    # the badge. Each session is classified by its FRESHEST heartbeat.
    t="$(now)"
    counts="$(
      # The statusline re-runs this on every refresh tick, so keep it to ONE jq
      # per agent file: jq emits the awk contract (sid8 \t age \t branch)
      # directly. Still per-file rather than one pass over the glob so a single
      # corrupt heartbeat can't blank the whole badge.
      for f in "$agents"/*.json; do
        [ -e "$f" ] || continue
        jq -r --argjson t "$t" \
          'select((.sid // "") != "")
           | [(.sid)[0:8], ($t - (.last_seen // 0)), (.branch // "")] | @tsv' \
          "$f" 2>/dev/null
      done | awk -F'\t' -v me="${sid:0:8}" -v soft="$STALE_SOFT" -v hard="$STALE_HARD" -v cur="$curbr" '
        { id=$1; age=$2+0; br=$3
          if (age>hard) next
          if (!(id in a) || age<a[id]) { a[id]=age; bof[id]=br } }   # freshest heartbeat per session
        END {
          live=0; idle=0; samebr=0
          for (id in a) {
            if (a[id]<=soft) { live++; if (id!=me && bof[id]==cur && cur!="no-git" && cur!="detached" && cur!="") samebr++ }
            else idle++
          }
          printf "%d %d %d", live, idle, samebr
        }'
    )"
    live="${counts%% *}"; rest="${counts#* }"; idle="${rest%% *}"; samebr="${rest##* }"
    : "${live:=0}" "${idle:=0}" "${samebr:=0}"
    # alone: only me live and nobody idling -> keep the statusline clean
    [ "$live" -le 1 ] && [ "$idle" -eq 0 ] && exit 0
    if [ "$live" -ge 2 ]; then out="🛰️ ${live} live"; else out="🛰️"; fi
    if [ "$idle" -gt 0 ]; then out="${out} · ${idle} idle"; fi
    if [ "$samebr" -gt 0 ]; then out="${out} \033[31m· ⚠ ${samebr} on this branch\033[0m"; fi
    printf '%b' "$out"
    exit 0
    ;;

  # ── heartbeat: bare-CLI liveness registration (no hook JSON available) ────
  # ledger.sh's owner_live() only treats a claim as "in-progress" (not
  # immediately reclaimable) when the claiming sid has a live bus heartbeat —
  # normally established for free by the SessionStart/UserPromptSubmit hooks.
  # A bare-shell actor with no hook driving it (e.g. `cobus swarm`'s worker
  # loops) never gets one, so without this its very first claim would look
  # instantly abandoned to every other reader and be re-claimed out from under
  # it on the next `next`/`board`. Reuses the same heartbeat() a hooked session
  # writes — no new state shape, no separate liveness path to keep in sync.
  heartbeat)
    ensure_dirs && heartbeat "" ""
    echo "💓 heartbeat registered for ${sid8} (branch:${curbr})"
    exit 0
    ;;

  # ── task board — a free-text front-end over the ledger's own task queue ────
  # (no separate storage here anymore; see the header note and docs/LEDGER.md)
  claim)
    shift; desc="$*"; [ -z "$desc" ] && { echo "usage: bus.sh claim \"<description>\""; exit 0; }
    [ -f "$LEDGER_SH" ] || { echo "bus.sh: ledger script not found at $LEDGER_SH"; exit 0; }
    subj="$(slug "$desc")"
    bash "$LEDGER_SH" task "$desc" >/dev/null 2>&1
    out="$(bash "$LEDGER_SH" claim "$subj" 2>&1)"
    case "$out" in
      🔒*) echo "✅ claimed (${subj}): $desc  [as branch:${curbr}]" ;;
      *)   echo "$out" ;;   # already in-progress / already done — surface the ledger's own message
    esac
    exit 0
    ;;
  done)
    shift; pat="$*"; [ -z "$pat" ] && { echo "usage: bus.sh done \"<text to match>\""; exit 0; }
    [ -f "$LEDGER_SH" ] || { echo "bus.sh: ledger script not found at $LEDGER_SH"; exit 0; }
    bash "$LEDGER_SH" done-text "$pat"
    exit 0
    ;;
  tasks)
    [ -f "$LEDGER_SH" ] || { echo "bus.sh: ledger script not found at $LEDGER_SH"; exit 0; }
    bash "$LEDGER_SH" board
    exit 0
    ;;

  # ── messaging ─────────────────────────────────────────────────────────────
  # Limitation: messages sent from the CLI run under sid "cli" (see input
  # handling above), not a real session id. A `msg all` therefore also drops a
  # copy into any live session — including, if the sender happens to be a live
  # session too, potentially its own inbox. Target a specific sid8 or branch to
  # avoid echoing back to yourself.
  msg)
    shift; target="${1:-}"; shift || true; text="$*"
    { [ -z "$target" ] || [ -z "$text" ]; } && { echo "usage: bus.sh msg <all|sid8|branch:name> <text>"; exit 0; }
    # ensure_dirs stays: it's cheap, idempotent, and the delivery path below
    # needs inbox/ to exist. It can only create a phantom tree at a root that
    # has no bus yet — which is exactly the case the 0-delivered diagnostic
    # below now names explicitly.
    ensure_dirs || exit 0
    [ -d "$agents" ] || { echo "📭 no agent records at this bus root (${root})."; exit 1; }
    sender="branch:${curbr} ($(basename "$root"))"
    stamp="$(printf 'from %s @%s: %s' "$sender" "$(hhmm)" "$text")"
    delivered=0 seen=0 stale=0 live_desc=""
    for f in "$agents"/*.json; do
      [ -e "$f" ] || continue
      s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"; [ -z "$s" ] && continue
      seen=$(( seen + 1 ))
      l="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$l" ] && l=0
      [ $(( $(now) - l )) -gt "$STALE_HARD" ] && { stale=$(( stale + 1 )); continue; }
      br="$(jq -r '.branch // ""' "$f" 2>/dev/null)"
      live_desc+="${live_desc:+, }${s:0:8}(branch:${br:-?})"
      hit=0
      case "$target" in
        all) hit=1 ;;
        branch:*) [ "$br" = "${target#branch:}" ] && hit=1 ;;
        *) case "$s" in "$target"*) hit=1 ;; esac ;;
      esac
      if [ "$hit" -eq 1 ]; then
        mkdir -p "${inbox}/${s}" 2>/dev/null
        # Uniquify: ts-pid alone can collide within the same second/PID and
        # silently overwrite an undelivered message. Add a random suffix and
        # loop past any name that somehow already exists.
        mf="${inbox}/${s}/$(now)-$$-${RANDOM}.msg"
        while [ -e "$mf" ]; do mf="${inbox}/${s}/$(now)-$$-${RANDOM}${RANDOM}.msg"; done
        printf '%s\n' "$stamp" > "$mf" 2>/dev/null
        delivered=$(( delivered + 1 ))
      fi
    done
    if [ "$delivered" -gt 0 ]; then
      echo "📨 delivered to ${delivered} instance(s): $text"
      exit 0
    fi
    # 0 delivered is a failure, and the reason matters: an empty bus root, a bus
    # full of dead sessions, and a live bus where nothing matched the target are
    # three different problems with three different fixes.
    if [ "$seen" -eq 0 ]; then
      echo "📭 no agent records at this bus root (${root}). If you're in a git worktree, live sessions may be registered under the main checkout's bus instead — flag it if you see this."
    elif [ "$stale" -eq "$seen" ]; then
      echo "📭 found ${seen} agent record(s), all stale (>${STALE_HARD}s since last heartbeat) — nobody is currently live."
    else
      echo "📭 $(( seen - stale )) live instance(s) found, none matched \"${target}\" — live targets: ${live_desc}"
    fi
    exit 1
    ;;

  # ── cross-repo fleet view — READ-ONLY discovery, not task dispatch ────────
  # Reads the local, per-machine registry heartbeat()/fleet_register() writes
  # to $(ck_data_dir)/fleet.json (repo root -> {last_seen}) and, for each
  # entry, re-derives live/idle counts + branches at VIEW TIME by reading
  # THAT repo's own .coordkit-bus/agents/*.json directly — the registry only
  # remembers WHERE repos are; liveness is cheap to recompute and a cached
  # copy would go stale between heartbeats. Entries whose path no longer
  # exists on disk (moved/deleted repo) are skipped from the listing and
  # pruned from the registry, under the same lock fleet_register() uses.
  fleet)
    fd="$(ck_data_dir)/fleet.json"
    if [ ! -s "$fd" ]; then
      echo "🛰️  coordkit fleet — no repos registered yet (a repo registers itself on its next coordkit heartbeat)."
      exit 0
    fi
    paths="$(jq -r '.repos // {} | keys[]' "$fd" 2>/dev/null | sort)"
    if [ -z "$paths" ]; then
      echo "🛰️  coordkit fleet — no repos registered yet."
      exit 0
    fi
    printf '🛰️  coordkit fleet  %s\n' "$(iso)"
    any=0 stale_paths=""
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      if [ ! -d "$p" ]; then stale_paths+="${p}"$'\n'; continue; fi
      any=1
      here=""; [ "$p" = "$root" ] && here="  (this repo)"
      IFS=$'\t' read -r flive fidle fbr <<< "$(fleet_repo_stats "$p")"
      printf '  %s%s\n' "$p" "$here"
      printf '      %s live · %s idle' "${flive:-0}" "${fidle:-0}"
      [ -n "${fbr:-}" ] && printf '   branch: %s' "$fbr"
      printf '\n'
    done <<< "$paths"
    [ "$any" = 0 ] && echo "  (no registered repos still exist on disk)"
    if [ -n "$stale_paths" ]; then
      ( flock 9
        cur="$(cat "$fd" 2>/dev/null || printf '{}')"
        while IFS= read -r sp; do
          [ -n "$sp" ] || continue
          cur="$(printf '%s' "$cur" | jq --arg p "$sp" 'del(.repos[$p])' 2>/dev/null)"
        done <<< "$stale_paths"
        printf '%s' "$cur" > "${fd}.tmp" 2>/dev/null && mv "${fd}.tmp" "$fd" 2>/dev/null
      ) 9>"${fd}.lock" 2>/dev/null
    fi
    exit 0
    ;;

  # ── one-shot snapshot (/bus) and live monitor (watch) ─────────────────────
  dashboard|frame|watch)
    C=0; [ "$phase" = "frame" ] || [ "$phase" = "watch" ] && C=1
    if [ "$C" = 1 ]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
    else BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""; fi

    render() {
      if [ ! -d "$bus" ]; then echo "No .coordkit-bus/ in ${root} — no instances have registered here yet."; return; fi
      local t rows col cany tany; t="$(now)"
      printf '%b🛰️  coordkit command center%b  %s  %b%s%b\n' "$BOLD" "$RST" "${root}" "$DIM" "$(iso)" "$RST"
      printf '%bLIVE AGENTS%b\n' "$CYN" "$RST"
      local any=0 s ah last age br cwd task files state
      for f in "$agents"/*.json; do
        [ -e "$f" ] || continue
        last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$last" ] && last=0
        age=$(( t - last )); [ "$age" -gt "$STALE_HARD" ] && continue
        any=1
        s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"
        ah="$(jq -r '.host // "unknown"' "$f" 2>/dev/null)"
        br="$(jq -r '.branch // "?"' "$f" 2>/dev/null)"
        cwd="$(jq -r '.cwd // ""' "$f" 2>/dev/null)"
        task="$(jq -r '.task // "(no task yet)"' "$f" 2>/dev/null)"
        files="$(jq -r '(.files // []) | join(", ")' "$f" 2>/dev/null)"
        state="${GRN}live${RST}"; [ "$age" -gt "$STALE_SOFT" ] && state="${YEL}idle${RST}"
        printf '  %b%s%b [host:%s, %b, %ds]  branch:%b%s%b\n' "$BOLD" "${s:0:8}" "$RST" "$ah" "$state" "$age" "$YEL" "$br" "$RST"
        [ -n "$cwd" ] && printf '      path:    %s\n' "$cwd"
        printf '      task:    %s\n' "$task"
        [ -n "$files" ] && printf '      %btouched:%b %s\n' "$DIM" "$RST" "$files"
        if [ -d "${subagents}/${s}" ]; then
          for sf in "${subagents}/${s}"/*.json; do
            [ -e "$sf" ] || continue
            IFS=$'\t' read -r sat sad <<< "$(jq -r \
              '[.subagent_type // "?", .description // ""] | @tsv' "$sf" 2>/dev/null)"
            printf '      %bsubagent:%b %s' "$DIM" "$RST" "$sat"
            [ -n "$sad" ] && printf ' — %s' "$sad"
            printf '\n'
          done
        fi
      done
      [ "$any" = 0 ] && echo "  (none)"
      printf '%bCOLLISIONS%b\n' "$RED" "$RST"
      col="$(collisions)"; cany=0
      if [ -n "$col" ]; then while IFS=$'\t' read -r p who; do printf '  %b⚠ %s%b  ← %s\n' "$RED" "$p" "$RST" "$who"; cany=1; done <<< "$col"; fi
      [ "$cany" = 0 ] && echo "  (none)"
      printf '%bTASK BOARD%b (open — from the ledger)\n' "$CYN" "$RST"
      tany=0
      tb="$([ -f "$LEDGER_SH" ] && bash "$LEDGER_SH" board 2>/dev/null | grep -E '^\s*\[ \]')"
      if [ -n "$tb" ]; then printf '%s\n' "$tb" | sed 's/^/  /' && tany=1; fi
      [ "$tany" = 0 ] && echo "  (none)"
      printf '%bRECENT ACTIVITY%b (last 12)\n' "$CYN" "$RST"
      if [ -f "$log" ]; then tail -n 12 "$log" 2>/dev/null | sed 's/^/  /'; else echo "  (none)"; fi
    }

    if [ "$phase" = "watch" ]; then
      trap 'tput cnorm 2>/dev/null; printf "\n"; exit 0' INT TERM
      tput civis 2>/dev/null
      while true; do
        clear 2>/dev/null
        render
        printf '\n%brefresh 2s · ctrl-c to quit%b\n' "$DIM" "$RST"
        sleep 2
      done
    else
      render
    fi
    exit 0
    ;;

  *) exit 0 ;;
esac

}   # ── end bus_main ────────────────────────────────────────────────────────

# Public entrypoint for sourced callers (scripts/coord.sh). The subshell is what
# makes bus_main's ~40 `exit 0` statements safe to call in-process: they end the
# phase, not the dispatcher. Hook JSON is fed on stdin exactly as before.
bus_run() { ( bus_main "$@" ); }

# Executed directly (bash bus.sh <phase>) rather than sourced: dispatch. No
# subshell here — the script IS the process, so `exit` means what it always did.
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  bus_main "$@"
fi
