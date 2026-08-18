#!/usr/bin/env bash
# shellcheck shell=bash
# logseq.sh — Logseq ⇄ ledger bridge (`cobus logseq ...`).
#
# A Logseq graph (plain markdown, usually itself git/iCloud-synced across the
# user's machines) becomes a human-readable, editable window onto the shared
# coordination state, and Logseq TODOs can feed the agent task queue.
#
#   export [--journal] [--pages]   project ledger/bus state INTO the graph:
#       pages/<ns>___fleet.md      one bullet per repo/session/actor (status,
#                                  last seen, task, branch)
#       pages/<ns>___tasks.md      one Logseq task block per ledger task
#                                  (TODO/DOING/DONE/WAITING) keyed by a
#                                  `coordkit-task::` property so re-exports
#                                  update in place
#       journals/<today>.md        append-only log of notable ledger events
#                                  since the last export (cursor in state.json)
#   import [--dry-run]             scan the graph for `#<tag>` (or <ns>/inbox)
#                                  TODO/LATER/NOW/DOING blocks without a
#                                  coordkit-task:: property → `ledger task`,
#                                  write the subject back; DONE blocks that
#                                  carry a subject → `ledger done`
#   sync [--loop <secs>]           import, then export; optional foreground
#                                  loop; live HTTP API push when configured
#   status                         graph path, cursor, counts, API reachability
#
# File mode is the required, always-works path. Only lines between the
# `<!-- coordkit:begin X -->` / `<!-- coordkit:end X -->` markers of the two
# managed pages are ever rewritten; user blocks are edited one exact line at a
# time (property insert / marker flip), preserving indentation and CRLF, and
# every write is tmp + mv.
#
# STATE lives in <coord_dir>/logseq/state.json (added to git info/exclude):
#   {cursor_seq, seen_eids[], presence[], imported{}, exports, last_export_ts}
#
# Config: coord.toml [logseq] graph_dir | namespace | journal_format | tag |
#         api_url | linear_workspace  (env COORDKIT_LOGSEQ_* overrides;
#         LOGSEQ_API_TOKEN for the local HTTP API bearer token).
#
# Reads state ONLY through the ledger/bus projections (`ledger.sh board --json`,
# `ledger.sh events`, `bus.sh fleet --json`) and writes ONLY through the
# ledger's own verbs (`task`, `done`) — no second task system.
set -uo pipefail

CORE_ROOT="${COORDKIT_CORE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}"
# shellcheck source=./common.sh
. "${CORE_ROOT}/scripts/common.sh" || { echo "logseq: coordkit runtime not found" >&2; exit 1; }
LEDGER_SH="${CORE_ROOT}/scripts/ledger.sh"
BUS_SH="${CORE_ROOT}/scripts/bus.sh"

# ── config ───────────────────────────────────────────────────────────────────
root="$(resolve_root "$(ck_project_dir)")"
toml="$(ck_coord_toml "$root")"
_cfg() {  # <env-name> <toml-key> <default>
  local v="${!1:-}"
  [ -n "$v" ] || v="$(ck_toml_table_get "$toml" logseq "$2" 2>/dev/null || true)"
  [ -n "$v" ] || v="$3"
  printf '%s' "$v"
}
GRAPH="$(_cfg COORDKIT_LOGSEQ_GRAPH_DIR graph_dir "")"
NS="$(_cfg COORDKIT_LOGSEQ_NAMESPACE namespace coordkit)"
JFMT="$(_cfg COORDKIT_LOGSEQ_JOURNAL_FORMAT journal_format yyyy_MM_dd)"
TAG="$(_cfg COORDKIT_LOGSEQ_TAG tag "#coordkit")"
API_URL="$(_cfg COORDKIT_LOGSEQ_API_URL api_url "")"
LINEAR_WS="$(_cfg COORDKIT_LOGSEQ_LINEAR_WORKSPACE linear_workspace "")"
API_TOKEN="${LOGSEQ_API_TOKEN:-}"
case "$GRAPH" in "~"*) GRAPH="${HOME}${GRAPH#\~}" ;; esac
TAG="${TAG#\#}"   # bare tag name; "#" is re-added where needed
STATE_DIR="$(ck_coord_dir "$root")/logseq"
STATE="${STATE_DIR}/state.json"

# Logseq date pattern → date(1) format (covers the patterns Logseq itself offers).
_journal_datefmt() {
  printf '%s' "$1" | sed -e 's/yyyy/%Y/g; s/MMMM/%B/g; s/MMM/%b/g; s/MM/%m/g; s/dd/%d/g; s/EEEE/%A/g; s/EEE/%a/g; s/do/%d/g'
}
PAGES_DIR="${GRAPH}/pages"
JOURNALS_DIR="${GRAPH}/journals"
_page_file() { printf '%s/%s.md' "$PAGES_DIR" "$(printf '%s' "$1" | sed 's#/#___#g')"; }
FLEET_PAGE="${NS}/fleet"; TASKS_PAGE="${NS}/tasks"; INBOX_PAGE="${NS}/inbox"; LOG_PAGE="${NS}/log"
FLEET_FILE="$(_page_file "$FLEET_PAGE")"; TASKS_FILE="$(_page_file "$TASKS_PAGE")"
INBOX_FILE="$(_page_file "$INBOX_PAGE")"
BEGIN_MARK() { printf '<!-- coordkit:begin %s -->' "$1"; }
END_MARK()   { printf '<!-- coordkit:end %s -->' "$1"; }

now() { date +%s; }
iso() { date '+%Y-%m-%d %H:%M'; }
hm_of() { date -d "@$1" '+%H:%M' 2>/dev/null || date -r "$1" '+%H:%M' 2>/dev/null || printf '??:??'; }
iso_of() { date -d "@$1" '+%Y-%m-%d %H:%M' 2>/dev/null || date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$1"; }
die() { printf 'logseq: %s\n' "$*" >&2; exit 1; }
need_graph() {
  [ -n "$GRAPH" ] || die "no graph_dir configured — set [logseq] graph_dir in ${toml} (or COORDKIT_LOGSEQ_GRAPH_DIR)"
  [ -d "$GRAPH" ] || die "graph_dir does not exist: ${GRAPH}"
  mkdir -p "$PAGES_DIR" "$JOURNALS_DIR" 2>/dev/null || die "cannot create pages/ journals/ under ${GRAPH}"
}

# ── state.json ───────────────────────────────────────────────────────────────
state_load() {
  mkdir -p "$STATE_DIR" 2>/dev/null
  ck_git_info_exclude_add "$root" '/.claude/coord/logseq/' 2>/dev/null || true
  if [ -s "$STATE" ] && jq -e 'type=="object"' "$STATE" >/dev/null 2>&1; then STATE_JSON="$(cat "$STATE")"
  else STATE_JSON='{"cursor_seq":0,"seen_eids":[],"presence":[],"imported":{},"exports":0}'; fi
}
state_save() {  # atomic
  local tmp="${STATE}.tmp.$$"
  printf '%s\n' "$STATE_JSON" | jq -c . > "$tmp" 2>/dev/null && mv -f "$tmp" "$STATE" || rm -f "$tmp"
}
state_get() { printf '%s' "$STATE_JSON" | jq -r "$1" 2>/dev/null; }
state_set() { STATE_JSON="$(printf '%s' "$STATE_JSON" | jq -c "$@" 2>/dev/null)" ; [ -n "$STATE_JSON" ] || die "state update failed"; }

# ── atomic file writes that preserve the file's line-ending convention ───────
_has_crlf() { [ -f "$1" ] && grep -q $'\r$' "$1" 2>/dev/null; }
# write_file <path> <content-on-stdin>: tmp + mv; CRLF re-applied when the
# existing file uses it; returns 1 (and touches nothing) when content is identical.
write_file() {
  local f="$1" tmp="$1.tmp.$$" crlf=0
  _has_crlf "$f" && crlf=1
  if [ "$crlf" = 1 ]; then sed 's/\r$//; s/$/\r/' > "$tmp"; else cat > "$tmp"; fi
  if [ -f "$f" ] && cmp -s "$f" "$tmp"; then rm -f "$tmp"; return 1; fi
  mv -f "$tmp" "$f"
}

# replace_region <file> <section> <page-title> <body-on-stdin>
# Rewrites only the lines strictly between the begin/end markers of <section>;
# missing file → created with a properties block; missing markers → appended.
replace_region() {
  local f="$1" sec="$2" title="$3" body b e
  body="$(cat)"
  b="$(BEGIN_MARK "$sec")"; e="$(END_MARK "$sec")"
  if [ ! -f "$f" ]; then
    {
      printf 'title:: %s\ntype:: coordkit\nupdated:: %s\n\n' "$title" "$(iso)"
      printf '%s\n%s\n%s\n' "$b" "$body" "$e"
    } | write_file "$f"
    return
  fi
  if ! grep -qF -- "$b" "$f" 2>/dev/null; then
    { sed 's/\r$//' "$f"; printf '\n%s\n%s\n%s\n' "$b" "$body" "$e"; } | write_file "$f"
    return
  fi
  LS_BODY="$body" LS_B="$b" LS_E="$e" LS_UPD="$(iso)" awk '
    BEGIN { b=ENVIRON["LS_B"]; e=ENVIRON["LS_E"]; body=ENVIRON["LS_BODY"]; upd=ENVIRON["LS_UPD"]; inr=0; done=0 }
    { line=$0; sub(/\r$/, "", line) }
    !inr && !done && index(line, b) && line ~ /^[ \t]*(- )?<!-- coordkit:begin/ { print line; print body; inr=1; next }
    inr && index(line, e) && line ~ /^[ \t]*(- )?<!-- coordkit:end/ { print line; inr=0; done=1; next }
    inr { next }
    line ~ /^updated:: / && !done { print "updated:: " upd; next }
    { print line }
  ' "$f" | write_file "$f"
}

# ── projections (read-only calls into ledger/bus) ─────────────────────────────
board_json()  { bash "$LEDGER_SH" board --json 2>/dev/null || echo '[]'; }
events_since(){ bash "$LEDGER_SH" events --since "${1:-0}" 2>/dev/null; }
fleet_json()  { bash "$BUS_SH" fleet --json "$root" 2>/dev/null || echo '{"repos":[]}'; }

# ledger status → Logseq marker
marker_of() { case "$1" in done) echo DONE ;; claimed:*) echo DOING ;; blocked) echo WAITING ;; *) echo TODO ;; esac; }

# ── export: tasks page ───────────────────────────────────────────────────────
render_tasks() {  # board json on stdin → markdown lines
  jq -r --arg ns "$NS" --arg tag "$TAG" --arg ws "$LINEAR_WS" '
    def marker: if .status == "done" then "DONE"
                elif (.status|startswith("claimed:")) then "DOING"
                elif .status == "blocked" then "WAITING"
                else "TODO" end;
    def linear_key: (.desc | capture("linear:(?<k>[A-Z][A-Z0-9]+-[0-9]+)")? // {k:null}) | .k;
    def url: (.desc | capture("(?<u>https?://[^ )\\]]+)")? // {u:null} | .u) as $u
             | if $u then $u
               elif (linear_key != null and $ws != "") then "https://linear.app/\($ws)/issue/\(linear_key)"
               else null end;
    def line1: "- \(marker) \(.desc | gsub("[\r\n]+"; " "))";
    if length == 0 then "- (no tasks in the ledger yet — `cobus task \"...\"` or add a #\($tag) TODO in Logseq)"
    else .[]
      | [ line1,
          "  coordkit-task:: \(.subject)",
          "  coordkit-status:: \(.status)",
          (if (.status|startswith("claimed:")) then "  coordkit-owner:: \(.owner_sid8 // (.status|ltrimstr("claimed:")))" else empty end),
          (if (.status|startswith("claimed:")) and .owner_host then "  coordkit-host:: \(.owner_host)" else empty end),
          (if (.status|startswith("claimed:")) and .owner_branch then "  coordkit-branch:: \(.owner_branch)" else empty end),
          (if .status == "blocked" and (.block_body // "") != "" then "  coordkit-blocked:: \(.block_body | gsub("[\r\n]+"; " "))" else empty end),
          (if linear_key then "  coordkit-ref:: linear:\(linear_key)" else empty end),
          (if url then "  coordkit-url:: \(url)" else empty end),
          (if .status == "open" and (.ready|not) then "  coordkit-waiting-on:: deps" else empty end)
        ] | .[]
    end'
}
export_tasks() {
  local body
  body="$(board_json | render_tasks)"
  if printf '%s\n' "$body" | replace_region "$TASKS_FILE" tasks "$TASKS_PAGE"; then echo "  tasks  → ${TASKS_FILE} (updated)"
  else echo "  tasks  → ${TASKS_FILE} (unchanged)"; fi
}

# ── export: fleet page ───────────────────────────────────────────────────────
render_fleet() {  # $1 = fleet json, $2 = events (ndjson) for the actor projection
  printf '%s' "$1" | jq -r --arg ns "$NS" '
    def ago: if . < 60 then "\(.)s" elif . < 3600 then "\((. / 60)|floor)m" else "\((. / 3600)|floor)h" end;
    "- **This machine** — \(.machine // "?") · \(.repos | length) repo(s)",
    (.repos[]
      | "\t- `\(.path)`\(if .this_repo then " (this repo)" else "" end) · \(.live) live · \(.idle) idle" + (if (.branches|length) > 0 then " · branch: \(.branches | join(", "))" else "" end),
        (.agents[] | "\t\t- \(.sid8) [\(.host), \(.state), \(.age|ago) ago] branch:\(.branch)" + (if .task != "" then " · task: \(.task)" else "" end)),
        (if (.agents|length) == 0 then "\t\t- (no live sessions)" else empty end)
    )'
  printf -- '- **Actors seen in the shared ledger** — one per site/actor, latest event wins\n'
  if [ -n "$2" ]; then
    printf '%s\n' "$2" | jq -rs '
      def tsf: . | strflocaltime("%Y-%m-%d %H:%M");
      map(select(type=="object" and (.actor // "") != ""))
      | group_by(.actor) | map(max_by(.seq // 0))
      | sort_by(-(.ts // 0))
      | if length == 0 then "\t- (no actor-stamped events yet)" else
        .[] | "\t- `\(.actor)`" + (if (.user // "") != "" then " (\(.user))" else "" end)
              + " · host:\(.host // "?") · branch:\(.branch // "?") · last: \(.type)/\(.subject) at \((.ts // 0)|tsf) (seq \(.seq // 0))" end'
  else
    printf '\t- (ledger empty)\n'
  fi
}
export_fleet() {
  local fj ev body
  fj="$(fleet_json)"; ev="$(events_since 0)"
  body="$(render_fleet "$fj" "$ev")"
  if printf '%s\n' "$body" | replace_region "$FLEET_FILE" fleet "$FLEET_PAGE"; then echo "  fleet  → ${FLEET_FILE} (updated)"
  else echo "  fleet  → ${FLEET_FILE} (unchanged)"; fi
}

# ── export: journal (append-only, incremental) ───────────────────────────────
journal_file() { printf '%s/%s.md' "$JOURNALS_DIR" "$(date "+$(_journal_datefmt "$JFMT")")"; }
export_journal() {
  local cur seen ev fj lines="" n=0 jf presence_now presence_prev diff eids_new maxseq
  cur="$(state_get '.cursor_seq // 0')"; case "$cur" in ''|*[!0-9]*) cur=0 ;; esac
  seen="$(state_get '.seen_eids // [] | tojson')"; [ -n "$seen" ] || seen='[]'
  ev="$(events_since "$cur")"
  # eid-dedup on top of the seq cursor: in git/relay mode two replicas can mint
  # the same seq, and a late-arriving replica event may sort below the cursor.
  # v1 events (no eid) fall back to a synthetic key.
  local filtered
  filtered="$(printf '%s\n' "$ev" | jq -c --argjson seen "$seen" '
      select(type=="object")
      | (.eid // "seq:\(.seq // 0):\(.sid8 // ""):\(.type // ""):\(.subject // "")") as $k
      | select(($seen | index($k)) == null)
      | select(.type as $t | ["task","claim","done","block","note","decision","question","answer"] | index($t) != null)
      | .__k = $k' 2>/dev/null)"
  if [ -n "$filtered" ]; then
    lines="$(printf '%s\n' "$filtered" | jq -r --arg ns "$NS" '
      def when: ((.ts // 0) | strflocaltime("%H:%M"));
      def who: "\(.sid8 // .actor // "?")@\(.host // "?"):\(.branch // "?")";
      def bodyline: ((.body // "") | gsub("[\r\n]+"; " ") | if length > 200 then .[0:200] + "…" else . end);
      "\t- \(when) **\(.type)** `\(.subject)` — \(bodyline) (\(who))"')"
    n="$(printf '%s\n' "$filtered" | grep -c . || true)"
    eids_new="$(printf '%s\n' "$filtered" | jq -sc '[.[].__k]')"
    maxseq="$(printf '%s\n' "$filtered" | jq -s '[.[].seq // 0] | max // 0')"
    [ "$maxseq" -gt "$cur" ] 2>/dev/null || maxseq="$cur"
    state_set --argjson e "$eids_new" --argjson m "$maxseq" '.cursor_seq = $m | .seen_eids = ((.seen_eids // []) + $e | .[-500:])'
  fi
  # presence changes: sessions that appeared / disappeared since the last export
  fj="$(fleet_json)"
  presence_now="$(printf '%s' "$fj" | jq -c '[.repos[] | .path as $p | .agents[] | "\(.sid8)@\(.host) \($p) [\(.branch)]"] | sort' 2>/dev/null)"
  [ -n "$presence_now" ] || presence_now='[]'
  presence_prev="$(state_get '(.presence // []) | if type == "array" then . else [] end | tojson')"; [ -n "$presence_prev" ] || presence_prev='[]'
  diff="$(jq -nr --argjson a "$presence_prev" --argjson b "$presence_now" --arg hm "$(hm_of "$(now)")" '
    (($b - $a)[] | "\t- \($hm) **session** \(.) appeared"),
    (($a - $b)[] | "\t- \($hm) **session** \(.) gone")' 2>/dev/null)"
  if [ -n "$diff" ]; then
    lines="${lines:+${lines}$'\n'}${diff}"
    n=$(( n + $(printf '%s\n' "$diff" | grep -c .) ))
  fi
  state_set --argjson p "$presence_now" '.presence = $p'
  jf="$(journal_file)"
  if [ -z "$lines" ]; then echo "  journal→ ${jf} (nothing new)"; return 0; fi
  # Append under a `- [[<ns>/log]]` parent: reuse it when it is already the last
  # top-level bullet in today's journal, else open a new one. Append-only.
  local parent="- [[${LOG_PAGE}]]" last_top=""
  if [ -f "$jf" ]; then last_top="$(sed 's/\r$//' "$jf" | grep -E '^- ' | tail -n1)"; fi
  {
    if [ -f "$jf" ]; then sed 's/\r$//' "$jf"; fi
    if [ "$last_top" != "$parent" ]; then printf '%s\n' "$parent"; fi
    printf '%s\n' "$lines"
  } | write_file "$jf" || true
  echo "  journal→ ${jf} (+${n} event(s))"
}

# ── graph scan: task-marker blocks (used by import + export reconcile) ────────
# Emits: file <US> lineno <US> indent <US> marker <US> text <US> subject <US> tagged
#   subject = value of coordkit-task:: on the block (or empty), tagged = 1 when the
#   block carries #<tag> / #[[<tag>]] or lives on the <ns>/inbox page.
US=$'\x1f'
scan_blocks() {
  local f inbox_base
  inbox_base="$(basename "$INBOX_FILE")"
  find "$PAGES_DIR" "$JOURNALS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | while IFS= read -r f; do
    case "$(basename "$f")" in
      "$(basename "$FLEET_FILE")"|"$(basename "$TASKS_FILE")") continue ;;
    esac
    LS_F="$f" LS_TAG="$TAG" LS_INBOX="$([ "$(basename "$f")" = "$inbox_base" ] && echo 1 || echo 0)" awk -v US="$US" '
      function flush() {
        if (bl) {
          tagged = inbox
          if (index(" " text " ", " #" tag " ") || index(text, "#[[" tag "]]") || index(text, "#" tag " ") || text ~ ("#" tag "$")) tagged = 1
          if (tagged || subj != "") printf "%s%s%d%s%s%s%s%s%s%s%s%s%d\n", ENVIRON["LS_F"], US, bl, US, ind, US, mk, US, text, US, subj, US, tagged
        }
        bl = 0; subj = ""; text = ""; mk = ""; ind = ""
      }
      BEGIN { tag = ENVIRON["LS_TAG"]; inbox = ENVIRON["LS_INBOX"] + 0; bl = 0 }
      { line = $0; sub(/\r$/, "", line) }
      line ~ /^[ \t]*- / {
        flush()
        if (match(line, /^[ \t]*- (TODO|LATER|NOW|DOING|DONE|WAITING|CANCELED|CANCELLED|IN-PROGRESS|WAIT) /)) {
          bl = NR
          ind = line; sub(/- .*$/, "", ind)
          rest = substr(line, RSTART + length(ind) + 2)
          mk = rest; sub(/ .*$/, "", mk)
          text = substr(rest, length(mk) + 2)
          gsub(/^[ \t]+|[ \t]+$/, "", text)
        }
        next
      }
      bl && line ~ /^[ \t]+coordkit-task:: / { subj = line; sub(/^[ \t]+coordkit-task:: */, "", subj); gsub(/[ \t]+$/, "", subj) }
      END { flush() }
    ' "$f"
  done
}

# insert_after <file> <lineno> <text> — insert one line after lineno (CRLF-aware)
insert_after() {
  LS_N="$2" LS_T="$3" awk '
    BEGIN { n = ENVIRON["LS_N"] + 0; t = ENVIRON["LS_T"] }
    { print }
    NR == n { if ($0 ~ /\r$/) print t "\r"; else print t }
  ' "$1" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}
# set_marker <file> <lineno> <new-marker> — swap the task marker on one bullet line
set_marker() {
  LS_N="$2" LS_M="$3" awk '
    BEGIN { n = ENVIRON["LS_N"] + 0; m = ENVIRON["LS_M"] }
    NR == n && match($0, /^[ \t]*- (TODO|LATER|NOW|DOING|DONE|WAITING|CANCELED|CANCELLED|IN-PROGRESS|WAIT) /) {
      pre = $0; sub(/- .*$/, "", pre)
      rest = substr($0, RSTART + length(pre) + 2); sub(/^[^ ]+ /, "", rest)
      print pre "- " m " " rest; next
    }
    { print }
  ' "$1" > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1"
}
strip_tag() {  # remove the #tag token from a block text
  printf '%s' "$1" | sed -E "s/(^| )#\[\[${TAG}\]\]( |$)/ /g; s/(^| )#${TAG}( |$)/ /g; s/[[:space:]]+/ /g; s/^ //; s/ $//"
}

# ── import ───────────────────────────────────────────────────────────────────
do_import() {
  local dry="${1:-0}" f ln ind mk text subj tagged desc st board out created=0 closed=0 linked=0 skipped=0
  board="$(board_json)"
  # Group per file so line numbers stay valid: collect insertions, apply from
  # the bottom up (insert_after re-reads the file each time; descending order
  # keeps earlier line numbers stable).
  local plan=""
  while IFS="$US" read -r f ln ind mk text subj tagged; do
    [ -n "$f" ] || continue
    if [ -z "$subj" ]; then
      [ "$tagged" = 1 ] || continue
      case "$mk" in TODO|LATER|NOW|DOING) ;; *) continue ;; esac
      desc="$(strip_tag "$text")"
      [ -n "$desc" ] || { skipped=$(( skipped + 1 )); continue; }
      subj="$(slug "$desc")"
      st="$(printf '%s' "$board" | jq -r --arg s "$subj" '.[] | select(.subject == $s) | .status' | head -n1)"
      if [ -n "$st" ]; then
        # already a ledger task (e.g. created by an earlier import that could not
        # write back) — just link the block, don't queue a duplicate.
        [ "$dry" = 1 ] && { echo "  would link  ${f##*/}:${ln} → ${subj} (exists: ${st})"; continue; }
        linked=$(( linked + 1 ))
      else
        [ "$dry" = 1 ] && { echo "  would create ${f##*/}:${ln} → task '${subj}': ${desc}"; continue; }
        out="$(bash "$LEDGER_SH" task "$desc" 2>/dev/null)"
        case "$out" in *"'${subj}'"*) ;; *) echo "  ⚠ ledger task failed for ${f##*/}:${ln}: ${out}"; continue ;; esac
        created=$(( created + 1 ))
      fi
      plan+="${f}${US}${ln}${US}${ind}${US}${subj}"$'\n'
      state_set --arg s "$subj" --arg f "$f" --argjson l "$ln" --argjson t "$(now)" '.imported[$s] = {file:$f, line:$l, ts:$t}'
    else
      case "$mk" in
        DONE|CANCELED|CANCELLED)
          st="$(printf '%s' "$board" | jq -r --arg s "$subj" '.[] | select(.subject == $s) | .status' | head -n1)"
          [ -n "$st" ] || { skipped=$(( skipped + 1 )); continue; }
          [ "$st" = done ] && continue
          [ "$dry" = 1 ] && { echo "  would close ${subj} (Logseq block is ${mk})"; continue; }
          bash "$LEDGER_SH" done "$subj" >/dev/null 2>&1 && closed=$(( closed + 1 )) ;;
      esac
    fi
  done < <(scan_blocks)
  # apply property write-backs, per file, bottom-up
  if [ -n "$plan" ]; then
    printf '%s' "$plan" | sort -t"$US" -k1,1 -k2,2nr | while IFS="$US" read -r f ln ind subj; do
      [ -n "$f" ] || continue
      insert_after "$f" "$ln" "${ind}  coordkit-task:: ${subj}"
    done
  fi
  [ "$dry" = 1 ] && { echo "  (dry-run — nothing written)"; return 0; }
  echo "  import: ${created} created, ${linked} linked, ${closed} closed, ${skipped} skipped"
}

# ── export-side reconcile: ledger done → flip user blocks to DONE ─────────────
reconcile_blocks() {
  local board f ln ind mk text subj tagged st flipped=0
  board="$(board_json)"
  while IFS="$US" read -r f ln ind mk text subj tagged; do
    [ -n "$subj" ] || continue
    case "$mk" in DONE|CANCELED|CANCELLED) continue ;; esac
    st="$(printf '%s' "$board" | jq -r --arg s "$subj" '.[] | select(.subject == $s) | .status' | head -n1)"
    [ "$st" = done ] || continue
    set_marker "$f" "$ln" DONE && flipped=$(( flipped + 1 ))
  done < <(scan_blocks)
  [ "$flipped" -gt 0 ] && echo "  blocks → ${flipped} Logseq block(s) flipped to DONE"
  return 0
}

# ── optional live path: Logseq local HTTP API ────────────────────────────────
api_call() {  # <method> <args-json>  → response body; non-zero when unreachable
  [ -n "$API_URL" ] && [ -n "$API_TOKEN" ] || return 1
  command -v curl >/dev/null 2>&1 || return 1
  curl -sS -m 3 -X POST "$API_URL" -H "Authorization: Bearer ${API_TOKEN}" -H 'Content-Type: application/json' \
    --data "$(jq -nc --arg m "$1" --argjson a "${2:-[]}" '{method:$m, args:$a}')" 2>/dev/null
}
api_reachable() { [ -n "$API_URL" ] || return 1; api_call logseq.App.getInfo '[]' >/dev/null 2>&1; }
# Best-effort: for every ledger task that already has a block in the open graph
# (found through its coordkit-task property), push the freshly rendered content
# so an open Logseq refreshes without waiting for its file watcher. New blocks
# and the fleet page are left to the file watcher. Any failure → silent.
api_push() {
  api_reachable || return 0
  local blocks board updated=0 uuid subj content
  blocks="$(api_call logseq.DB.datascriptQuery '["[:find (pull ?b [:block/uuid :block/content :block/properties]) :where [?b :block/properties ?p] [(get ?p :coordkit-task)]]"]' 2>/dev/null)"
  [ -n "$blocks" ] || return 0
  board="$(board_json | render_tasks)"
  while IFS=$'\t' read -r uuid subj; do
    [ -n "$uuid" ] && [ -n "$subj" ] || continue
    content="$(printf '%s\n' "$board" | awk -v s="$subj" '
      /^- / { if (buf != "" && hit) print buf; buf = substr($0, 3); hit = 0; next }
      /^  coordkit-task:: / { if ($2 == s) hit = 1 }
      /^  / { buf = buf "\n" substr($0, 3); next }
      END { if (buf != "" && hit) print buf }')"
    [ -n "$content" ] || continue
    api_call logseq.Editor.updateBlock "$(jq -nc --arg u "$uuid" --arg c "$content" '[$u, $c]')" >/dev/null 2>&1 && updated=$(( updated + 1 ))
  done < <(printf '%s' "$blocks" | jq -r '.[]? | .[0]? | select(.properties["coordkit-task"] != null) | "\(.uuid // .["block/uuid"] // "")\t\(.properties["coordkit-task"])"' 2>/dev/null)
  [ "$updated" -gt 0 ] && echo "  api    → ${updated} block(s) refreshed via ${API_URL}"
  return 0
}

# ── commands ─────────────────────────────────────────────────────────────────
cmd_export() {
  local pages=1 journal=1
  if [ $# -gt 0 ]; then pages=0; journal=0; fi
  while [ $# -gt 0 ]; do case "$1" in --pages) pages=1 ;; --journal) journal=1 ;; esac; shift; done
  need_graph; state_load
  echo "🪵 coordkit → logseq export (${GRAPH})"
  if [ "$pages" = 1 ]; then reconcile_blocks; export_tasks; export_fleet; fi
  [ "$journal" = 1 ] && export_journal
  state_set --argjson t "$(now)" '.exports = ((.exports // 0) + 1) | .last_export_ts = $t'
  state_save
}
cmd_import() {
  local dry=0
  while [ $# -gt 0 ]; do case "$1" in --dry-run|-n) dry=1 ;; esac; shift; done
  need_graph; state_load
  echo "🪵 logseq → coordkit import (${GRAPH})"
  do_import "$dry"
  [ "$dry" = 1 ] || state_save
}
cmd_sync() {
  local loop=0
  while [ $# -gt 0 ]; do case "$1" in --loop) loop="${2:-0}"; shift ;; esac; shift; done
  case "$loop" in ''|*[!0-9]*) loop=0 ;; esac
  need_graph
  _one() { state_load; do_import 0; reconcile_blocks; export_tasks; export_fleet; export_journal; api_push
           state_set --argjson t "$(now)" '.exports = ((.exports // 0) + 1) | .last_export_ts = $t'; state_save; }
  if [ "$loop" -gt 0 ]; then
    trap 'echo; echo "logseq sync: stopped"; exit 0' INT TERM
    echo "🪵 coordkit ⇄ logseq sync loop every ${loop}s (ctrl-c to stop)"
    while :; do echo "── $(iso)"; _one; sleep "$loop" & wait $!; done
  else
    echo "🪵 coordkit ⇄ logseq sync (${GRAPH})"; _one
  fi
}
cmd_status() {
  state_load
  local n_tasks n_open imported reach="not configured" cur
  echo "🪵 coordkit ⇄ logseq status"
  echo "  repo:        ${root}"
  echo "  config:      ${toml}"
  echo "  graph_dir:   ${GRAPH:-(unset)}$([ -n "$GRAPH" ] && [ ! -d "$GRAPH" ] && printf ' (missing)')"
  echo "  namespace:   ${NS}   tag: #${TAG}   journal_format: ${JFMT}"
  echo "  pages:       ${TASKS_FILE##*/}$([ -f "$TASKS_FILE" ] || printf ' (not exported yet)') · ${FLEET_FILE##*/}$([ -f "$FLEET_FILE" ] || printf ' (not exported yet)')"
  cur="$(state_get '.cursor_seq // 0')"
  echo "  state:       ${STATE} — cursor seq ${cur}, exports $(state_get '.exports // 0'), last export $( t="$(state_get '.last_export_ts // empty')"; [ -n "$t" ] && iso_of "$t" || echo never)"
  n_tasks="$(board_json | jq 'length')"; n_open="$(board_json | jq '[.[] | select(.status != "done")] | length')"
  imported="$(state_get '.imported // {} | length')"
  echo "  ledger:      ${n_tasks} task(s), ${n_open} not done; ${imported} imported from Logseq"
  if [ -n "$API_URL" ]; then
    if [ -z "$API_TOKEN" ]; then reach="${API_URL} (LOGSEQ_API_TOKEN not set)"
    elif api_reachable; then reach="${API_URL} (reachable)"; else reach="${API_URL} (unreachable — file mode only)"; fi
  fi
  echo "  http api:    ${reach}"
}
usage() {
  cat <<EOF
cobus logseq — Logseq ⇄ ledger bridge

  cobus logseq export [--journal] [--pages]   write ${NS}/fleet, ${NS}/tasks pages + today's journal
  cobus logseq import [--dry-run]              #${TAG} TODO blocks → ledger tasks; DONE blocks → ledger done
  cobus logseq sync [--loop <secs>]            import then export (loop: foreground, ctrl-c to stop)
  cobus logseq status                          graph path, cursor, counts, API reachability

config: [logseq] in ${toml}  (graph_dir, namespace, journal_format, tag, api_url, linear_workspace)
docs:   docs/LOGSEQ.md
EOF
}

case "${1:-}" in
  export) shift; cmd_export "$@" ;;
  import) shift; cmd_import "$@" ;;
  sync)   shift; cmd_sync "$@" ;;
  status) shift; cmd_status "$@" ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
