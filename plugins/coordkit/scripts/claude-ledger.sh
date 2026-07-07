#!/usr/bin/env bash
# claude-ledger.sh — v2 SHARED CONTEXT layer for multi-instance Claude Code.
#
# Sits ON TOP of claude-bus.sh (the awareness layer) and reuses its per-repo
# heartbeats (<repo>/.claude-bus/agents/<sid>.json) for liveness. Where the bus
# RECORDS who's live and WARNS on collisions, the ledger gives the instances a
# single append-only source of truth they all read paginated slices out of, plus
# a self-orchestrating task queue with leases.
#
# Event sourcing:
#   ledger.jsonl   append-only truth. one JSON event per line, never edited.
#       {seq,ts,sid,sid8,branch,type,subject,body,refs[],tags[],lease}
#       type ∈ note|decision|question|answer|task|claim|done|block
#   cursors/<sid>.json   {seq:N} — how far THIS instance has consumed.
#   Projections (open tasks, claims, decisions) are RECOMPUTED from the log on
#   demand — deterministic, so every instance converges to the same state.
#
# Self-orchestration:
#   task "<desc>"     publish work to the shared queue (subject = slug)
#   next              auto-claim the first open task whose deps are satisfied
#   claim <subject>   lease a task (TTL tied to bus heartbeat liveness)
#   done <subject>    mark complete   |   block <subject> "<why>"
#   A claim whose lease expired OR whose owner's heartbeat is dead reverts the
#   task to OPEN automatically → work-stealing, no leader needed.
#
# Pagination / "raising the context layer":
#   On SessionStart/UserPromptSubmit a TOKEN-BUDGETED digest is injected:
#   materialized state (open/claimed tasks, recent decisions, open questions)
#   + only the events newer than this instance's cursor, capped to a page.
#   Cursor then advances so the next turn shows only what's new.
#
# Wired from settings.json (ADDITIVE — alongside claude-bus.sh):
#   SessionStart      -> start    register cursor + inject digest
#   UserPromptSubmit  -> prompt   inject delta since cursor + advance
# By hand / slash commands (/led, /ctx):
#   digest|catchup    full paginated digest      board   task board
#   note|decide|ask|answer|task|claim|next|done|block   write events
#
# Defensive: any internal trouble -> exit 0 so it can never wedge a session.
set -uo pipefail

phase="${1:-digest}"

LEASE_TTL=900        # 15 min task lease (matches bus STALE_SOFT)
LIVE_TTL=21600       # 6 h  -> owner considered dead (matches bus STALE_HARD)
PAGE=20              # max events injected per turn
BODYCAP=240          # max chars of an event body in the digest

now()  { date +%s; }
iso()  { date '+%Y-%m-%d %H:%M:%S'; }

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
slug() { printf '%s' "$1" | tr '[:upper:] ' '[:lower:]-' | tr -cd 'a-z0-9._-' | cut -c1-48; }

# ── input handling: hook phases read JSON on stdin; CLI phases take args ──────
case "$phase" in
  start|prompt)
    input="$(cat)"
    cwd="$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)"
    [ -z "$cwd" ] && cwd="$PWD"
    sid="$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)" ;;
  *)
    input=""; cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
    sid="${CLAUDE_SESSION_ID:-cli}" ;;
esac

root="$(resolve_root "$cwd")"
bus="${root}/.claude-bus"
agents="${bus}/agents"
ledger="${bus}/ledger.jsonl"   # READ source (repointed to a logstore view when sharing is on)
LWRITE="${bus}/ledger.jsonl"   # physical append target in direct (default) mode
cursors="${bus}/cursors"
lock="${bus}/.ledger.lock"
sid8="${sid:0:8}"
curbr="$(branch_of "$cwd")"

# ── coordkit transports/versioning shim (default OFF → byte-identical to v1) ──
# When COORDKIT_USE_LOGSTORE=1 and the transports lib is present, reads are
# served from the deduped+ordered union (logstore_readall) and writes go
# through logstore_append (Phase 4 sharing). When COORDKIT_EMIT_V2=1, new
# events use the versioned v2 envelope (Phase 3). Both default off so a plugin
# instance and a live global-hooks instance still converge on one ledger.jsonl.
CK_LOGSTORE=0
CK_DATA="${COORDKIT_DATA:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/coordkit-data}}"
_ck_lib="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}/transports/lib.sh"
# Activate the logstore when (a) explicitly requested, (b) COORDKIT_MODE forces a
# non-local mode, or (c) a committed coord.toml selects git/relay — so a fresh
# clone auto-joins sharing with NO env var. With no toml + no env → stays direct
# (byte-identical to today).
_ck_want=0
[ "${COORDKIT_USE_LOGSTORE:-0}" = 1 ] && _ck_want=1
if [ "$_ck_want" = 0 ]; then
  _ck_m="${COORDKIT_MODE:-}"
  if [ -z "$_ck_m" ]; then
    _ck_toml="${COORDKIT_COORD_TOML:-${root}/.claude/coord/coord.toml}"
    [ -f "$_ck_toml" ] && _ck_m="$(sed -n '/^[[:space:]]*\[/q;p' "$_ck_toml" 2>/dev/null \
      | grep -E '^[[:space:]]*mode[[:space:]]*=' | head -n1 \
      | sed -E 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"[[:space:]]*$//')"
  fi
  case "$_ck_m" in git|relay) _ck_want=1 ;; esac
fi
if [ "$_ck_want" = 1 ] && [ -f "$_ck_lib" ]; then
  . "$_ck_lib" 2>/dev/null && command -v logstore_readall >/dev/null 2>&1 && CK_LOGSTORE=1
fi
# v2 envelope is the shipped DEFAULT (carries seq + eid-dedup + clock order, and
# is schema-valid — see schema/event.schema.json). Every read path in this file
# (digest, board, task_status, delta injection, prompt) keys off fields that v2
# and v1 both expose (seq/type/subject/body/branch/sid/sid8), and task_status
# already handles lease as object-or-scalar — so v2 is read-compatible with mixed
# and legacy ledgers. Pin COORDKIT_EMIT_V2=0 to force the flat v1 line.
: "${COORDKIT_EMIT_V2:=1}"
[ "$CK_LOGSTORE" = 1 ] && trap 'rm -f "${bus}/.lview.$$" 2>/dev/null' EXIT

refresh_view() {  # logstore mode: materialize the ordered union into the READ source
  [ "$CK_LOGSTORE" = 1 ] || return 0
  mkdir -p "$bus" 2>/dev/null
  ledger="${bus}/.lview.$$"
  logstore_readall > "$ledger" 2>/dev/null || : > "$ledger"
}
ledger_emit() {  # append one prebuilt JSON line (logstore-aware)
  if [ "$CK_LOGSTORE" = 1 ]; then logstore_append "$1" 2>/dev/null
  else printf '%s\n' "$1" >> "$LWRITE" 2>/dev/null; fi
}

_ck_actor() {
  local f="${CK_DATA}/site.json" a
  a="$(jq -r '.actor // empty' "$f" 2>/dev/null)"
  [ -n "$a" ] && { printf '%s' "$a"; return; }
  local seed="${HOSTNAME:-host}-${USER:-user}-${HOME:-/}" h
  if command -v b3sum >/dev/null 2>&1; then h="$(printf '%s' "$seed" | b3sum 2>/dev/null | cut -c1-8)"
  else h="$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -c1-8)"; fi
  printf 'site-%s' "${h:-00000000}"
}
_ck_clock_c() {
  local f="${CK_DATA}/clock.state" c
  mkdir -p "$CK_DATA" 2>/dev/null
  ( flock 8
    c="$(cat "$f" 2>/dev/null)"; [ -z "$c" ] && c=0; c=$(( c + 1 )); printf '%s' "$c" > "$f"; printf '%s' "$c"
  ) 8>"${f}.lock"
}
_ck_emit_v2() {  # seq type subject body refs tags lease -> one v2 JSON line on stdout
  local seq="$1" type="$2" subject="$3" body="$4" refs="$5" tags="$6" lease="$7"
  local actor p c lease_obj base eid id hasher="sha256" hcmd="sha256sum"
  command -v b3sum >/dev/null 2>&1 && { hasher="blake3"; hcmd="b3sum"; }
  actor="$(_ck_actor)"
  p="$(date +%s%3N 2>/dev/null)"; case "$p" in *[!0-9]*|'') p="$(( $(now) * 1000 ))";; esac
  c="$(_ck_clock_c)"
  if [ "${lease:-0}" = 0 ] || [ -z "${lease:-}" ]; then lease_obj='null'
  else lease_obj="$(jq -nc --argjson l "$lease" --arg owner "$actor" --arg sid8 "$sid8" \
        'if ($l|type)=="object" then $l else {until:$l, owner:$owner, sid8:$sid8} end' 2>/dev/null)"; fi
  id="$(printf '%x%04x' "$(now)" "$(( ${RANDOM:-0} ))")"
  base="$(jq -nc \
    --arg sv "2.0" --arg actor "$actor" --argjson p "$p" --argjson c "$c" --argjson seq "$seq" \
    --argjson ts "$(now)" --arg sid "$sid" --arg sid8 "$sid8" --arg user "${USER:-}" --arg br "$curbr" \
    --arg type "$type" --arg subject "$subject" --arg body "$body" \
    --argjson refs "$refs" --argjson tags "$tags" --argjson lease "$lease_obj" --arg id "$id" \
    '{schema_version:$sv,eid:"",id:$id,actor:$actor,clock:{p:$p,c:$c},seq:$seq,ts:$ts,sid:$sid,sid8:$sid8,user:$user,branch:$br,type:$type,subject:$subject,body:$body,refs:$refs,tags:$tags,lease:$lease,supersedes:null,sig:null}' 2>/dev/null)"
  eid="${hasher}:$(printf '%s' "$base" | jq -Sc 'del(.eid,.sig)' 2>/dev/null | "$hcmd" 2>/dev/null | cut -d' ' -f1 | cut -c1-32)"
  printf '%s' "$base" | jq -c --arg eid "$eid" '.eid=$eid' 2>/dev/null
}

# ensure a STABLE per-(machine+user+clone) actor identity in the persistent
# plugin data dir. This is bootstrap.sh's essential work, inlined here so the
# ledger is SELF-bootstrapping (bootstrap.sh is not wired into any hook). Cheap
# and idempotent: a single jq validation once the file exists, a no-op after the
# first successful write. Best-effort — never fails ensure_dirs.
ensure_site() {
  local site="${CK_DATA}/site.json" seed h actor
  [ -s "$site" ] && jq -e '.actor' "$site" >/dev/null 2>&1 && return 0
  mkdir -p "$CK_DATA" 2>/dev/null || return 0
  seed="${HOSTNAME:-$(hostname 2>/dev/null || echo host)}-${USER:-$(id -un 2>/dev/null || echo user)}-${HOME:-/}"
  if command -v b3sum >/dev/null 2>&1; then h="$(printf '%s' "$seed" | b3sum 2>/dev/null | cut -c1-8)"
  else h="$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -c1-8)"; fi
  actor="site-${h:-00000000}"
  jq -nc --arg actor "$actor" --arg user "${USER:-}" --arg host "${HOSTNAME:-}" \
    '{actor:$actor, user:$user, host:$host}' > "$site" 2>/dev/null || return 0
  return 0
}

ensure_dirs() {
  mkdir -p "$agents" "$cursors" 2>/dev/null || return 1
  [ -f "${bus}/.gitignore" ] || printf '*\n' > "${bus}/.gitignore" 2>/dev/null
  [ -f "$LWRITE" ] || : > "$LWRITE" 2>/dev/null
  ensure_site   # self-bootstrap the stable actor id (best-effort, no-op once done)
  return 0
}

max_seq() {
  # The TRUE maximum seq over all parseable lines. A corrupt / truncated /
  # seq-less LAST line must NEVER reset this to 0 — doing so would hand the next
  # event seq=1 and permanently blind every `select(.seq > N)` cursor.
  [ -s "$ledger" ] || { echo 0; return; }
  # Fast path (O(1) on huge ledgers): the last line almost always carries the
  # max seq. Trust it only when it yields a plain integer; otherwise fall back to
  # a full tolerant scan.
  local last
  last="$(tail -n1 "$ledger" 2>/dev/null | jq -r '.seq // empty' 2>/dev/null)"
  case "$last" in
    ''|*[!0-9]*) : ;;                       # unparseable/seq-less → full scan
    *) printf '%s' "$last"; return ;;
  esac
  # Full scan: max seq across every line that parses, tolerating garbage lines.
  jq -Rrn '[inputs | fromjson? | .seq? | numbers] | max // 0' "$ledger" 2>/dev/null || echo 0
}

# append_event TYPE SUBJECT BODY [REFS_JSON] [TAGS_JSON] [LEASE]
# Helpers read type/subject/body/refs/tags/lease/seq from the caller's scope
# (bash dynamic scoping) so they work both inside and outside the flock subshell.
_ae_build_line() {
  if [ "${COORDKIT_EMIT_V2:-0}" = 1 ]; then
    _ck_emit_v2 "$seq" "$type" "$subject" "$body" "$refs" "$tags" "$lease"
  else
    jq -nc \
      --argjson seq "$seq" --argjson ts "$(now)" --arg sid "$sid" --arg sid8 "$sid8" \
      --arg br "$curbr" --arg type "$type" --arg subject "$subject" --arg body "$body" \
      --argjson refs "$refs" --argjson tags "$tags" --argjson lease "$lease" \
      '{seq:$seq,ts:$ts,sid:$sid,sid8:$sid8,branch:$br,type:$type,subject:$subject,body:$body,refs:$refs,tags:$tags,lease:$lease}'
  fi
}
_ae_emit_one() {
  local last seq line; last="$(max_seq)"; [ -z "$last" ] && last=0; seq=$(( last + 1 ))
  line="$(_ae_build_line)"
  ledger_emit "$line"
  printf '%s' "$seq"
}
append_event() {
  ensure_dirs || return 1
  local type="$1" subject="$2" body="$3" refs="${4:-[]}" tags="${5:-[]}" lease="${6:-0}"
  if [ "$CK_LOGSTORE" = 1 ]; then
    # logstore_append owns its OWN flock (transports/lib.sh) for the physical
    # byte-append, so we must NOT flock that same file here or the two locks
    # deadlock. But max_seq→emit still has to be atomic across instances, else two
    # writers read the same max and mint DUPLICATE seqs. Serialize seq allocation
    # on a SEPARATE dedicated lock file (fd 7): two DIFFERENT flock files can never
    # deadlock — this lock orders seq allocation, logstore's lock orders the write.
    ( flock 7; _ae_emit_one ) 7>"${lock}.seq"
  else
    ( flock 9; _ae_emit_one ) 9>"$lock" # direct mode: today's atomic seq+append
  fi
}

# liveness via the bus heartbeats (reuse, don't reinvent)
owner_live() {
  local f="${agents}/$1.json" l
  [ -f "$f" ] || return 1
  l="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"; [ -z "$l" ] && l=0
  [ $(( $(now) - l )) -le "$LIVE_TTL" ]
}

# last event (full json) for a subject of a given type
last_ev() { jq -c --arg s "$1" --arg t "$2" 'select(.subject==$s and .type==$t)' "$ledger" 2>/dev/null | tail -n1; }
# max seq for a subject+type (or 0). ALWAYS echoes a plain integer so callers'
# `[ "$x" -gt 0 ]` comparisons can never explode with "integer expression
# expected" when jq yields null/empty on a v1 or seq-less line.
seq_of() {
  local e n; e="$(last_ev "$1" "$2")"
  [ -n "$e" ] || { echo 0; return; }
  n="$(printf '%s' "$e" | jq -r '.seq // 0' 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

# echo the status of a task subject: done | blocked | claimed:<sid8> | open
task_status() {
  local s="$1" dn cl bl tk owner lease
  [ -f "$ledger" ] || { echo open; return; }
  dn="$(seq_of "$s" done)"; cl="$(seq_of "$s" claim)"; bl="$(seq_of "$s" block)"; tk="$(seq_of "$s" task)"
  if [ "$dn" -gt 0 ] && [ "$dn" -ge "$cl" ]; then echo done; return; fi
  if [ "$bl" -gt 0 ] && [ "$bl" -gt "$cl" ] && [ "$bl" -gt "$dn" ]; then echo blocked; return; fi
  if [ "$cl" -gt 0 ] && [ "$cl" -gt "$dn" ]; then
    local ev; ev="$(last_ev "$s" claim)"
    owner="$(printf '%s' "$ev" | jq -r '.sid')"
    lease="$(printf '%s' "$ev" | jq -r 'if (.lease|type)=="object" then (.lease.until // 0) else (.lease // 0) end' 2>/dev/null)"
    case "$lease" in ''|*[!0-9]*) lease=0 ;; esac   # non-numeric/null lease → treat as expired
    if [ "$lease" -gt "$(now)" ] && owner_live "$owner"; then
      echo "claimed:$(printf '%s' "$ev" | jq -r '.sid8')"; return
    fi
    echo open; return            # lease lapsed or owner dead -> reclaimable
  fi
  echo open
}

# deps satisfied? a task body may carry "dep:subjectA dep:subjectB"
deps_met() {
  local s="$1" body dep st
  body="$(jq -r --arg s "$s" 'select(.subject==$s and .type=="task") | .body' "$ledger" 2>/dev/null | tail -n1)"
  for dep in $(printf '%s' "$body" | grep -oE 'dep:[a-z0-9._-]+' | sed 's/^dep://'); do
    st="$(task_status "$dep")"; [ "$st" != "done" ] && return 1
  done
  return 0
}

distinct_subjects() { jq -r --arg t "$1" 'select(.type==$t) | .subject' "$ledger" 2>/dev/null | awk '!seen[$0]++'; }

# ── BOARD: projected task queue ──────────────────────────────────────────────
print_board() {
  [ -s "$ledger" ] || { echo "📋 ledger empty — no tasks yet. Use: claude-ledger.sh task \"<desc>\""; return; }
  echo "📋 Task queue (projected from ledger) — ${root}"
  local s st desc found=0
  for s in $(distinct_subjects task); do
    found=1
    st="$(task_status "$s")"
    desc="$(jq -r --arg s "$s" 'select(.subject==$s and .type=="task") | .body' "$ledger" 2>/dev/null | tail -n1)"
    case "$st" in
      done)        printf '  [x] %-44s %s\n' "$s" "done" ;;
      claimed:*)   printf '  [~] %-44s in-progress (%s)\n' "$s" "${st#claimed:}" ;;
      blocked)     printf '  [!] %-44s BLOCKED\n' "$s" ;;
      *)           if deps_met "$s"; then printf '  [ ] %-44s open\n' "$s"
                   else printf '  [ ] %-44s open (waiting on deps)\n' "$s"; fi ;;
    esac
    [ -n "$desc" ] && printf '        %s\n' "$desc"
  done
  [ "$found" = 0 ] && echo "  (no tasks)"
}

# latest decision per subject (subject \t sid8 \t body)
recent_decisions() {
  local s ev
  for s in $(distinct_subjects decision); do
    ev="$(last_ev "$s" decision)"
    printf '%s\t%s\t%s\n' "$s" "$(printf '%s' "$ev" | jq -r '.sid8')" "$(printf '%s' "$ev" | jq -r '.body' | cut -c1-$BODYCAP)"
  done
}

# questions with no later answer on the same subject
open_questions() {
  local s qd ad ev
  for s in $(distinct_subjects question); do
    qd="$(seq_of "$s" question)"; ad="$(seq_of "$s" answer)"
    if [ "$qd" -gt "$ad" ]; then
      ev="$(last_ev "$s" question)"
      printf '%s\t%s\t%s\n' "$s" "$(printf '%s' "$ev" | jq -r '.sid8')" "$(printf '%s' "$ev" | jq -r '.body' | cut -c1-$BODYCAP)"
    fi
  done
}

# ── DIGEST: the token-budgeted shared-context page ───────────────────────────
build_digest() {  # $1 = cursor seq (events strictly greater are "new")
  local cur="${1:-0}" out="" line tasks dec q delta n
  ensure_dirs
  [ -s "$ledger" ] || { printf ''; return; }

  # 1) materialized state — small, always included
  tasks=""
  local s st
  for s in $(distinct_subjects task); do
    st="$(task_status "$s")"
    case "$st" in
      open)      deps_met "$s" && tasks+="    ▸ ${s} (open)"$'\n' || tasks+="    ▸ ${s} (open · waiting on deps)"$'\n' ;;
      claimed:*) tasks+="    ~ ${s} (in-progress: ${st#claimed:})"$'\n' ;;
      blocked)   tasks+="    ! ${s} (BLOCKED)"$'\n' ;;
    esac
  done
  [ -n "$tasks" ] && out+="📋 Task queue:"$'\n'"$tasks"

  dec="$(recent_decisions | tail -n 5)"
  if [ -n "$dec" ]; then
    out+="🧭 Current decisions:"$'\n'
    while IFS=$'\t' read -r s who body; do [ -n "$s" ] && out+="    • ${s}: ${body} (${who})"$'\n'; done <<< "$dec"
  fi

  q="$(open_questions)"
  if [ -n "$q" ]; then
    out+="❓ Open questions:"$'\n'
    while IFS=$'\t' read -r s who body; do [ -n "$s" ] && out+="    • ${s}: ${body} (${who})"$'\n'; done <<< "$q"
  fi

  # 2) delta since this instance's cursor — paginated
  delta="$(jq -c --argjson c "$cur" 'select(.seq > $c)' "$ledger" 2>/dev/null)"
  if [ -n "$delta" ]; then
    n="$(printf '%s\n' "$delta" | grep -c . )"
    out+="🆕 ${n} new event(s) since you last looked"
    [ "$n" -gt "$PAGE" ] && out+=" (showing latest ${PAGE} — run /ctx for the rest)"
    out+=":"$'\n'
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      printf '%s\n' "$line"
    done < <(printf '%s\n' "$delta" | tail -n "$PAGE") | while IFS= read -r line; do
      printf '    %s · %s/%s · %s — %s\n' \
        "$(printf '%s' "$line" | jq -r '.sid8')" \
        "$(printf '%s' "$line" | jq -r '.type')" \
        "$(printf '%s' "$line" | jq -r '.subject')" \
        "$(printf '%s' "$line" | jq -r '.branch')" \
        "$(printf '%s' "$line" | jq -r '.body' | cut -c1-$BODYCAP)"
    done > "${bus}/.digest.$$"
    out+="$(cat "${bus}/.digest.$$" 2>/dev/null)"$'\n'; rm -f "${bus}/.digest.$$" 2>/dev/null
  fi
  printf '%s' "$out"
}

get_cursor() { local f="${cursors}/${sid}.json"; [ -f "$f" ] && jq -r '.seq // 0' "$f" 2>/dev/null || echo 0; }
set_cursor() { ensure_dirs; jq -nc --argjson seq "${1:-0}" '{seq:$seq}' > "${cursors}/${sid}.json" 2>/dev/null; }

inject() {  # $1 = context text, $2 = hook event name
  [ -z "$1" ] && return
  printf '{"hookSpecificOutput":{"hookEventName":"%s","additionalContext":%s}}\n' \
    "$2" "$(printf '%s' "$1" | jq -Rs .)"
}

refresh_view   # logstore mode: point reads at the ordered union (no-op in default mode)

case "$phase" in
  # ── SessionStart: register cursor + inject the shared-context digest ───────
  start)
    ensure_dirs
    cur="$(get_cursor)"
    mx="$(max_seq)"
    # fresh instance: start one page back so it gets recent context, not all history
    [ "$cur" = 0 ] && [ "$mx" -gt "$PAGE" ] && cur=$(( mx - PAGE ))
    dg="$(build_digest "$cur")"
    if [ -n "$dg" ]; then
      inject "🧠 SHARED CONTEXT (.claude-bus/ledger — what every instance knows):"$'\n'"$dg"$'\n'"(write to it: /led note|decide|task|claim|done · take work: /led next · full view: /ctx)" "SessionStart"
    fi
    set_cursor "$mx"
    exit 0 ;;

  # ── UserPromptSubmit: inject only what's new since the cursor, then advance ─
  prompt)
    ensure_dirs
    cur="$(get_cursor)"; mx="$(max_seq)"
    if [ "$mx" -gt "$cur" ]; then
      # NOTE: seq is a LOCAL-only counter (per physical log) — see the schema's
      # `seq` description. Cursors here dedupe by seq, which is correct in direct
      # mode (single monotonic writer) but is NOT authoritative cross-machine in
      # logstore/relay mode, where the total order is (clock.p, clock.c, actor).
      # A full clock-based read path is out of scope for this pass; the practical
      # effect is that after a cross-replica merge a few already-seen events may be
      # re-surfaced once. eid (content hash) is the durable dedup key if a future
      # pass wants exactly-once injection.
      delta="$(jq -c --argjson c "$cur" --arg me "$sid" 'select(.seq > $c and (.sid != $me))' "$ledger" 2>/dev/null)"
      if [ -n "$delta" ]; then
        body="🧠 New shared-context events from other instances:"$'\n'
        body+="$(printf '%s\n' "$delta" | tail -n "$PAGE" | while IFS= read -r l; do
          [ -z "$l" ] && continue
          printf '    %s · %s/%s — %s\n' \
            "$(printf '%s' "$l" | jq -r '.sid8')" "$(printf '%s' "$l" | jq -r '.type')" \
            "$(printf '%s' "$l" | jq -r '.subject')" "$(printf '%s' "$l" | jq -r '.body' | cut -c1-$BODYCAP)"
        done)"
        inject "$body" "UserPromptSubmit"
      fi
    fi
    set_cursor "$mx"
    exit 0 ;;

  # ── full digest (for /ctx, /led digest, watch) ────────────────────────────
  digest|catchup)
    ensure_dirs
    dg="$(build_digest 0)"
    if [ -n "$dg" ]; then echo "🧠 SHARED CONTEXT — ${root}"; echo; printf '%s\n' "$dg"
    else echo "🧠 Shared-context ledger is empty in ${root}. Seed it: claude-ledger.sh note \"...\""; fi
    exit 0 ;;

  board)
    ensure_dirs; print_board; exit 0 ;;

  # ── writes ────────────────────────────────────────────────────────────────
  note)
    shift; text="$*"; [ -z "$text" ] && { echo "usage: ... note \"<text>\""; exit 0; }
    s="$(append_event note "general" "$text")"; echo "📝 noted (seq ${s})"; exit 0 ;;
  decide)
    shift; subj="$(slug "${1:-}")"; shift || true; text="$*"
    { [ -z "$subj" ] || [ -z "$text" ]; } && { echo "usage: ... decide <subject> \"<decision>\""; exit 0; }
    s="$(append_event decision "$subj" "$text")"; echo "🧭 decision on '${subj}' recorded (seq ${s})"; exit 0 ;;
  ask)
    shift; subj="$(slug "${1:-}")"; shift || true; text="$*"
    { [ -z "$subj" ] || [ -z "$text" ]; } && { echo "usage: ... ask <subject> \"<question>\""; exit 0; }
    s="$(append_event question "$subj" "$text")"; echo "❓ question on '${subj}' posted (seq ${s})"; exit 0 ;;
  answer)
    shift; subj="$(slug "${1:-}")"; shift || true; text="$*"
    { [ -z "$subj" ] || [ -z "$text" ]; } && { echo "usage: ... answer <subject> \"<answer>\""; exit 0; }
    s="$(append_event answer "$subj" "$text")"; echo "💬 answer on '${subj}' recorded (seq ${s})"; exit 0 ;;
  task)
    shift; text="$*"; [ -z "$text" ] && { echo "usage: ... task \"<desc>\"  (add 'dep:<subject>' in the text for ordering)"; exit 0; }
    subj="$(slug "$text")"
    s="$(append_event task "$subj" "$text")"; echo "➕ task '${subj}' queued (seq ${s})"; exit 0 ;;
  claim)
    shift; subj="$(slug "${1:-}")"; [ -z "$subj" ] && { echo "usage: ... claim <subject>"; exit 0; }
    st="$(task_status "$subj")"
    case "$st" in
      claimed:*) echo "⚠ '${subj}' already in-progress (${st#claimed:}) — pick another or coordinate."; exit 0 ;;
      done)      echo "✓ '${subj}' is already done."; exit 0 ;;
    esac
    lease=$(( $(now) + LEASE_TTL ))
    s="$(append_event claim "$subj" "claimed by ${sid8} (branch:${curbr})" "[]" "[]" "$lease")"
    echo "🔒 claimed '${subj}' (lease ${LEASE_TTL}s, seq ${s})"; exit 0 ;;
  next)
    ensure_dirs
    picked=""
    for s in $(distinct_subjects task); do
      st="$(task_status "$s")"; [ "$st" = open ] || continue
      deps_met "$s" || continue
      picked="$s"; break
    done
    if [ -z "$picked" ]; then echo "🟢 no open tasks with satisfied deps — queue is clear or all in-progress."; print_board; exit 0; fi
    lease=$(( $(now) + LEASE_TTL ))
    sq="$(append_event claim "$picked" "auto-claimed by ${sid8} (branch:${curbr})" "[]" "[]" "$lease")"
    desc="$(jq -r --arg s "$picked" 'select(.subject==$s and .type=="task") | .body' "$ledger" 2>/dev/null | tail -n1)"
    echo "🤖 picked next task '${picked}' (seq ${sq}, lease ${LEASE_TTL}s):"; echo "    ${desc}"; exit 0 ;;
  done)
    shift; subj="$(slug "${1:-}")"; [ -z "$subj" ] && { echo "usage: ... done <subject>"; exit 0; }
    s="$(append_event done "$subj" "done by ${sid8}")"; echo "✅ '${subj}' marked done (seq ${s})"; exit 0 ;;
  block)
    shift; subj="$(slug "${1:-}")"; shift || true; why="$*"
    [ -z "$subj" ] && { echo "usage: ... block <subject> \"<why>\""; exit 0; }
    s="$(append_event block "$subj" "${why:-blocked}")"; echo "⛔ '${subj}' marked blocked (seq ${s})"; exit 0 ;;

  *) echo "phases: start|prompt|digest|board|note|decide|ask|answer|task|claim|next|done|block"; exit 0 ;;
esac
