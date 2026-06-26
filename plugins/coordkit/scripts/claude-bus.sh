#!/usr/bin/env bash
# claude-bus.sh — a per-repo "command center" so several Claude Code instances
# running in the same project are aware of each other.
#
# AWARENESS layer (complements concurrency-guard.sh, the anti-clobber layer):
# the guard HARD-BLOCKS edits to files changed on disk; this bus RECORDS who's
# live / what they're doing / what they touch, warns SOFTLY on collisions, gives
# a live UI, a task board, and inter-instance messaging.
#
# State in <repo>/.claude-bus/:
#   agents/<sid>.json   heartbeat {sid,branch,cwd,task,files,last_seen}
#   claims/<sha>.json   soft lock {path,sid,ts}
#   inbox/<sid>/*.msg   messages waiting for that instance
#   TASKS.md            shared task board (claim/done)
#   activity.log        feed: "<iso>\t<sid8>\t<verb>\t<detail>"
#
# Wired from settings.json:
#   SessionStart            -> start    register + greet (who's live, same-branch ⚠, messages)
#   UserPromptSubmit        -> task     record current task + deliver inbox messages
#   PostToolUse Write|Edit|Read|Bash -> record  feed + heartbeat + claims
#   PreToolUse  Write|Edit   -> check   soft collision warning + desktop notify
#   Stop / SessionEnd        -> stop    drop heartbeat + release claims
#   statusLine               -> badge   "🛰️ N live" + heartbeat tick (via cship-bus.sh)
#
# By hand:
#   claude-bus.sh dashboard [repo]   one-shot snapshot (used by /bus)
#   claude-bus.sh watch [repo]       live auto-refreshing monitor (run in a pane)
#   claude-bus.sh claim "<desc>"     claim a task on the board
#   claude-bus.sh done "<text>"      mark matching task(s) done
#   claude-bus.sh tasks              print the task board
#   claude-bus.sh msg <target> <text>   message all|<sid8>|branch:<name>
#
# Defensive: on any internal trouble it exits 0 (allow) so a bug here can never
# wedge a session.
set -uo pipefail

phase="${1:-dashboard}"

STALE_SOFT=900       # 15 min -> shown as "idle"
STALE_HARD=21600     # 6 h    -> heartbeat pruned
TICK_MIN=10          # min seconds between statusline heartbeat ticks
NOTIFY_DEBOUNCE=60   # min seconds between desktop notifications per file

now()  { date +%s; }
iso()  { date '+%Y-%m-%d %H:%M:%S'; }
hhmm() { date '+%H:%M:%S'; }
mtime(){ stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

resolve_root() {
  local cwd="$1" top dir
  # explicit pin wins over everything — lets sibling non-git subdirs share one bus
  if [ -n "${CLAUDE_BUS_ROOT:-}" ]; then printf '%s' "$CLAUDE_BUS_ROOT"; return; fi
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then printf '%s' "$top"; return; fi
  dir="$cwd"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -d "$dir/.claude-bus" ] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return; fi
  printf '%s' "$cwd"
}
branch_of() { git -C "$1" branch --show-current 2>/dev/null || printf 'no-git'; }

# ── input handling ──────────────────────────────────────────────────────────
# dashboard/watch take a repo arg; everything else reads hook/statusline JSON.
case "$phase" in
  dashboard|watch|frame)
    input=""; cwd="${2:-$PWD}"; sid="cli" ;;
  claim|done|tasks|msg)
    input=""; cwd="${CLAUDE_PROJECT_DIR:-$PWD}"; sid="cli" ;;
  *)
    input="$(cat)"
    cwd="$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)"
    [ -z "$cwd" ] && cwd="$PWD"
    sid="$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)" ;;
esac

root="$(resolve_root "$cwd")"
bus="${root}/.claude-bus"
agents="${bus}/agents"; claims="${bus}/claims"; inbox="${bus}/inbox"
log="${bus}/activity.log"; tasks_md="${bus}/TASKS.md"
sid8="${sid:0:8}"
curbr="$(branch_of "$cwd")"

ensure_dirs() {
  mkdir -p "$agents" "$claims" "$inbox" 2>/dev/null || return 1
  [ -f "${bus}/.gitignore" ] || printf '*\n' > "${bus}/.gitignore" 2>/dev/null
  return 0
}

prune_dead() {
  local t f last; t="$(now)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$last" ] && last=0
    [ $(( t - last )) -gt "$STALE_HARD" ] && rm -f "$f" 2>/dev/null
  done
}

heartbeat() {  # $1=task (or "") $2=file-to-append (or "")
  ensure_dirs || return 0
  local rec="${agents}/${sid}.json" task_set="${1:-}" file_add="${2:-}"
  local t br prev='{}'; t="$(now)"; br="$curbr"
  [ -f "$rec" ] && prev="$(cat "$rec" 2>/dev/null || printf '{}')"
  printf '%s' "$prev" | jq \
    --arg sid "$sid" --arg br "$br" --arg cwd "$cwd" \
    --argjson t "$t" --arg task "$task_set" --arg file "$file_add" '
      . as $p
      | {sid:$sid, branch:$br, cwd:$cwd, last_seen:$t}
      + {task:  ( if $task != "" then $task else ($p.task // "") end )}
      + {files: ( ($p.files // [])
                  | if $file != "" then (. + [$file]) else . end
                  | reverse | unique | .[0:8] )}
    ' > "${rec}.tmp" 2>/dev/null && mv "${rec}.tmp" "$rec" 2>/dev/null
}

agent_age()    { local f="${agents}/$1.json" l; l="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$l" ] && l=0; echo $(( $(now) - l )); }
agent_live()   { [ -f "${agents}/$1.json" ] && [ "$(agent_age "$1")" -le "$STALE_HARD" ]; }

# tab-rows of OTHER live agents: sid8 \t state \t age \t branch \t task \t files
others_live() {
  local t f s last age br task files state; t="$(now)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"; [ "$s" = "$sid" ] && continue
    last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$last" ] && last=0
    age=$(( t - last )); [ "$age" -gt "$STALE_HARD" ] && continue
    br="$(jq -r '.branch // "?"' "$f" 2>/dev/null)"
    task="$(jq -r '.task // ""' "$f" 2>/dev/null)"
    files="$(jq -r '(.files // []) | join(", ")' "$f" 2>/dev/null)"
    state="live"; [ "$age" -gt "$STALE_SOFT" ] && state="idle"
    printf '%s\t%s\t%ss\t%s\t%s\t%s\n' "${s:0:8}" "$state" "$age" "$br" "$task" "$files"
  done
}

# files touched by >=2 distinct live agents -> "path \t who"
collisions() {
  local t f s last age fl; t="$(now)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"
    last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$last" ] && last=0
    age=$(( t - last )); [ "$age" -gt "$STALE_HARD" ] && continue
    jq -r '(.files // [])[]' "$f" 2>/dev/null | while IFS= read -r fl; do
      [ -n "$fl" ] && printf '%s\t%s\n' "${s:0:8}" "$fl"
    done
  done | sort -u | awk -F'\t' '{c[$2]++; who[$2]=who[$2] (who[$2]==""?"":", ") $1}
                                END{for(p in c) if(c[p]>1) printf "%s\t%s\n",p,who[p]}'
}

drain_inbox() {  # prints message lines for $sid and deletes them; returns 0 if any
  local box="${inbox}/${sid}" f got=1 out=""
  [ -d "$box" ] || { printf ''; return 1; }
  for f in "$box"/*.msg; do
    [ -e "$f" ] || continue
    out+="  📨 $(cat "$f" 2>/dev/null)"$'\n'; rm -f "$f" 2>/dev/null; got=0
  done
  printf '%s' "$out"; return $got
}

notify() {  # best-effort desktop notification; never fails
  local title="$1" body="$2"
  command -v notify-send >/dev/null 2>&1 && { notify-send -u normal "$title" "$body" >/dev/null 2>&1 & disown 2>/dev/null; return; }
  command -v powershell.exe >/dev/null 2>&1 && { powershell.exe -NoProfile -Command "[void][System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms'); [System.Windows.Forms.MessageBox]::Show('$body','$title')" >/dev/null 2>&1 & disown 2>/dev/null; }
}

case "$phase" in
  # ── SessionStart ──────────────────────────────────────────────────────────
  start)
    ensure_dirs && prune_dead && heartbeat "" ""
    msgs="$(drain_inbox)"; have_msgs=$?
    rows="$(others_live)"
    samebr=""
    if [ -n "$rows" ]; then
      while IFS=$'\t' read -r id st age br task files; do
        [ "$br" = "$curbr" ] && [ "$br" != "no-git" ] && samebr+="${id} "
      done <<< "$rows"
    fi
    ctx=""
    [ "$have_msgs" -eq 0 ] && [ -n "$msgs" ] && ctx+="📨 Messages waiting for you:"$'\n'"${msgs}"
    if [ -n "$samebr" ]; then
      ctx+="⚠️  COLLISION RISK: instance(s) ${samebr}are live on your SAME branch (${curbr}). Coordinate or use a separate branch before committing."$'\n'
    fi
    if [ -n "$rows" ]; then
      ctx+="🛰️  Other Claude instances live in this repo (.claude-bus):"$'\n'
      while IFS=$'\t' read -r id st age br task files; do
        ctx+="  • ${id} [${st}, ${age} ago] branch:${br}"
        [ -n "$task" ]  && ctx+=" — task: ${task}"
        [ -n "$files" ] && ctx+=" — touching: ${files}"
        ctx+=$'\n'
      done <<< "$rows"
      ctx+="Run /bus for the dashboard, /claim to take a task, /msg to ping another instance."
    fi
    [ -n "$ctx" ] && printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' \
      "$(printf '%s' "$ctx" | jq -Rs .)"
    exit 0
    ;;

  # ── UserPromptSubmit ──────────────────────────────────────────────────────
  task)
    prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null)"
    prompt="$(printf '%s' "$prompt" | tr '\n' ' ' | cut -c1-120)"
    [ -n "$prompt" ] && heartbeat "$prompt" ""
    msgs="$(drain_inbox)"; have_msgs=$?
    if [ "$have_msgs" -eq 0 ] && [ -n "$msgs" ]; then
      ctx="📨 Message(s) from another Claude instance in this repo:"$'\n'"${msgs}"
      printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' \
        "$(printf '%s' "$ctx" | jq -Rs .)"
    fi
    exit 0
    ;;

  # ── PostToolUse feed ──────────────────────────────────────────────────────
  record)
    tn="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)"
    file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    cmd="$(printf '%s' "$input"  | jq -r '.tool_input.command // empty' 2>/dev/null)"
    ensure_dirs || exit 0
    case "$tn" in
      Write|Edit)
        [ -z "$file" ] && exit 0
        rel="${file#$root/}"; heartbeat "" "$rel"
        printf '%s\t%s\tedit\t%s\n' "$(iso)" "$sid8" "$rel" >> "$log" 2>/dev/null
        key="$(printf '%s' "$file" | sha1sum | cut -d' ' -f1)"
        jq -n --arg p "$rel" --arg sid "$sid" --argjson ts "$(now)" \
          '{path:$p, sid:$sid, ts:$ts}' > "${claims}/${key}.json" 2>/dev/null ;;
      Read)
        [ -z "$file" ] && exit 0
        rel="${file#$root/}"; heartbeat "" ""
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
    file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
    [ -z "$file" ] && exit 0
    key="$(printf '%s' "$file" | sha1sum | cut -d' ' -f1)"
    cf="${claims}/${key}.json"; [ -f "$cf" ] || exit 0
    owner="$(jq -r '.sid // ""' "$cf" 2>/dev/null)"
    { [ -z "$owner" ] || [ "$owner" = "$sid" ]; } && exit 0
    agent_live "$owner" || exit 0
    obr="$(jq -r '.branch // "?"' "${agents}/${owner}.json" 2>/dev/null)"
    age="$(agent_age "$owner")"; rel="${file#$root/}"
    # debounced desktop notification
    mk="${bus}/.notify-${key}"
    do_notify=1
    if [ -f "$mk" ]; then [ $(( $(now) - $(mtime "$mk") )) -lt "$NOTIFY_DEBOUNCE" ] && do_notify=0; fi
    if [ "$do_notify" -eq 1 ]; then : > "$mk" 2>/dev/null; notify "Claude collision" "${owner:0:8} (branch:${obr}) is also editing ${rel##*/}"; fi
    msg="🔔 Another live Claude instance (${owner:0:8}, branch:${obr}, active ${age}s ago) recently edited \"${rel}\". Soft lock: not blocking — reconcile, don't clobber. Run /bus or /msg ${owner:0:8} to coordinate."
    printf '{"systemMessage":%s,"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":%s}}\n' \
      "$(printf '%s' "$msg" | jq -Rs .)" "$(printf '%s' "$msg" | jq -Rs .)"
    exit 0
    ;;

  # ── Stop / SessionEnd ─────────────────────────────────────────────────────
  stop)
    rm -f "${agents}/${sid}.json" 2>/dev/null
    for cf in "$claims"/*.json; do
      [ -e "$cf" ] || continue
      [ "$(jq -r '.sid // ""' "$cf" 2>/dev/null)" = "$sid" ] && rm -f "$cf" 2>/dev/null
    done
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
    t="$(now)"; live=0; samebr=0
    for f in "$agents"/*.json; do
      [ -e "$f" ] || continue
      l="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$l" ] && l=0
      [ $(( t - l )) -gt "$STALE_HARD" ] && continue
      live=$(( live + 1 ))
      s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"
      br="$(jq -r '.branch // ""' "$f" 2>/dev/null)"
      [ "$s" != "$sid" ] && [ "$br" = "$curbr" ] && [ "$br" != "no-git" ] && samebr=$(( samebr + 1 ))
    done
    [ "$live" -le 1 ] && exit 0   # alone: keep the statusline clean
    out="🛰️ ${live} live"
    if [ "$samebr" -gt 0 ]; then out="${out} \033[31m· ⚠ ${samebr} on this branch\033[0m"; fi
    printf '%b' "$out"
    exit 0
    ;;

  # ── task board ────────────────────────────────────────────────────────────
  claim)
    shift; desc="$*"; [ -z "$desc" ] && { echo "usage: claude-bus.sh claim \"<description>\""; exit 0; }
    ensure_dirs || exit 0
    ( flock 9; printf -- '- [ ] (%s) %s  @%s\n' "$curbr" "$desc" "$(iso)" >> "$tasks_md" ) 9>"${bus}/.tasks.lock" 2>/dev/null
    echo "✅ claimed on board (${tasks_md}): $desc  [as branch:${curbr}]"
    exit 0
    ;;
  done)
    shift; pat="$*"; [ -z "$pat" ] && { echo "usage: claude-bus.sh done \"<text to match>\""; exit 0; }
    [ -f "$tasks_md" ] || { echo "no task board yet"; exit 0; }
    esc="$(printf '%s' "$pat" | sed 's/[&/\]/\\&/g')"
    ( flock 9; sed -i "/$esc/s/^- \[ \]/- [x]/" "$tasks_md" ) 9>"${bus}/.tasks.lock" 2>/dev/null
    echo "✅ marked done (matching: $pat)"
    exit 0
    ;;
  tasks)
    if [ -f "$tasks_md" ]; then echo "📋 Task board — ${tasks_md}"; echo; cat "$tasks_md"; else echo "No task board yet. Use: claude-bus.sh claim \"...\""; fi
    exit 0
    ;;

  # ── messaging ─────────────────────────────────────────────────────────────
  msg)
    shift; target="${1:-}"; shift || true; text="$*"
    { [ -z "$target" ] || [ -z "$text" ]; } && { echo "usage: claude-bus.sh msg <all|sid8|branch:name> <text>"; exit 0; }
    ensure_dirs || exit 0
    [ -d "$agents" ] || { echo "no live agents"; exit 0; }
    sender="branch:${curbr} ($(basename "$root"))"
    stamp="$(printf 'from %s @%s: %s' "$sender" "$(hhmm)" "$text")"
    delivered=0
    for f in "$agents"/*.json; do
      [ -e "$f" ] || continue
      s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"; [ -z "$s" ] && continue
      l="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$l" ] && l=0
      [ $(( $(now) - l )) -gt "$STALE_HARD" ] && continue
      br="$(jq -r '.branch // ""' "$f" 2>/dev/null)"
      hit=0
      case "$target" in
        all) hit=1 ;;
        branch:*) [ "$br" = "${target#branch:}" ] && hit=1 ;;
        *) case "$s" in "$target"*) hit=1 ;; esac ;;
      esac
      if [ "$hit" -eq 1 ]; then
        mkdir -p "${inbox}/${s}" 2>/dev/null
        printf '%s\n' "$stamp" > "${inbox}/${s}/$(now)-$$.msg" 2>/dev/null
        delivered=$(( delivered + 1 ))
      fi
    done
    echo "📨 delivered to ${delivered} instance(s): $text"
    exit 0
    ;;

  # ── one-shot snapshot (/bus) and live monitor (watch) ─────────────────────
  dashboard|frame|watch)
    C=0; [ "$phase" = "frame" ] || [ "$phase" = "watch" ] && C=1
    if [ "$C" = 1 ]; then BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
    else BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""; fi

    render() {
      if [ ! -d "$bus" ]; then echo "No .claude-bus/ in ${root} — no instances have registered here yet."; return; fi
      local t rows col cany tany; t="$(now)"
      printf '%b🛰️  Claude command center%b  %s  %b%s%b\n' "$BOLD" "$RST" "${root}" "$DIM" "$(iso)" "$RST"
      printf '%bLIVE AGENTS%b\n' "$CYN" "$RST"
      local any=0 s last age br task files state
      for f in "$agents"/*.json; do
        [ -e "$f" ] || continue
        last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$last" ] && last=0
        age=$(( t - last )); [ "$age" -gt "$STALE_HARD" ] && continue
        any=1
        s="$(jq -r '.sid // ""' "$f" 2>/dev/null)"
        br="$(jq -r '.branch // "?"' "$f" 2>/dev/null)"
        task="$(jq -r '.task // "(no task yet)"' "$f" 2>/dev/null)"
        files="$(jq -r '(.files // []) | join(", ")' "$f" 2>/dev/null)"
        state="${GRN}live${RST}"; [ "$age" -gt "$STALE_SOFT" ] && state="${YEL}idle${RST}"
        printf '  %b%s%b [%b, %ds]  branch:%b%s%b\n' "$BOLD" "${s:0:8}" "$RST" "$state" "$age" "$YEL" "$br" "$RST"
        printf '      task:    %s\n' "$task"
        [ -n "$files" ] && printf '      %btouched:%b %s\n' "$DIM" "$RST" "$files"
      done
      [ "$any" = 0 ] && echo "  (none)"
      printf '%bCOLLISIONS%b\n' "$RED" "$RST"
      col="$(collisions)"; cany=0
      if [ -n "$col" ]; then while IFS=$'\t' read -r p who; do printf '  %b⚠ %s%b  ← %s\n' "$RED" "$p" "$RST" "$who"; cany=1; done <<< "$col"; fi
      [ "$cany" = 0 ] && echo "  (none)"
      printf '%bTASK BOARD%b (open)\n' "$CYN" "$RST"
      tany=0
      if [ -f "$tasks_md" ]; then grep -n '^- \[ \]' "$tasks_md" 2>/dev/null | sed 's/^[0-9]*://; s/^/  /' && tany=1; fi
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
