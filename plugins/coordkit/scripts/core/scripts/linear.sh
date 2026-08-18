#!/usr/bin/env bash
# shellcheck shell=bash
# linear.sh — Linear ⇄ ledger bridge (`cobus linear ...`).
#
# Keeps coordkit's cross-machine ledger (tasks / claims / blockers / notes) and
# a Linear team in sync, so an agent on ANY machine can pick a Linear issue off
# the shared board and humans watching Linear see live progress from whichever
# machine is working it.
#
#   pull    Linear issues  →  ledger tasks   (subject linear-<identifier>, idempotent)
#   push    ledger events  →  ONE persistent Linear comment per issue (created on
#           first push, updated in place after), plus a workflow-state transition
#           (claim → In Progress, done → Done) and a `blocked` label.
#   sync    pull then push; --loop <secs> makes it a foreground daemon.
#   link    map an arbitrary ledger task subject onto a Linear issue.
#   status  mapping table, last sync, auth presence (never prints the key).
#
# Talks to https://api.linear.app/graphql with curl+jq only. The key comes from
# the environment ($LINEAR_API_KEY) and is NEVER written to coord.toml or the
# state file. Everything else lives in coord.toml's [linear] table:
#
#   [linear]
#   team_key      = "COD"              # required
#   project       = "coordkit"         # optional: only issues in this project
#   label         = "repo:coordkit"    # optional: only issues carrying this label
#   states        = "Todo,In Progress" # default pull filter (--state overrides)
#   claim_state   = "In Progress"      # ledger claim  → this workflow state
#   done_state    = "Done"             # ledger done   → this workflow state
#   blocked_label = "blocked"          # ledger block  → this label ("" = comment only)
#   poll_s        = 60                 # `sync --loop` default interval
#
# Local, gitignored bridge state (comment ids, issue ids, cached workflow-state
# ids, last-push fingerprints) is kept in <repo>/.claude/coord/linear/state.json.
#
# Testability: set COORDKIT_LINEAR_CURL=<script> to replace the HTTP call. The
# script receives the GraphQL request JSON on stdin and must print the response
# body; a non-zero exit is treated as a transport failure (retried with backoff).
# tests/linear-bridge.sh drives the whole bridge that way, offline.
set -uo pipefail

_ck_core="${COORDKIT_CORE_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}"
# shellcheck source=./common.sh
. "${_ck_core}/scripts/common.sh" || { echo "linear: coordkit common.sh not found" >&2; exit 127; }
LEDGER="${_ck_core}/scripts/ledger.sh"

ENDPOINT="${COORDKIT_LINEAR_ENDPOINT:-https://api.linear.app/graphql}"
RETRIES="${COORDKIT_LINEAR_RETRIES:-4}"
BACKOFF="${COORDKIT_LINEAR_BACKOFF_S:-1}"
TIMELINE_MAX="${COORDKIT_LINEAR_TIMELINE:-20}"
MARKER='<!-- coordkit:ledger:v1'
DRY_RUN=0
exec 5>&1   # real stdout, so --dry-run output survives being inside $(...) captures

usage() {
  cat <<'EOF'
cobus linear — Linear ⇄ ledger bridge

Usage:
  cobus linear pull [--state "Todo,In Progress"] [--assignee me] [--dry-run]
      fetch matching issues of [linear].team_key and upsert them as ledger tasks
      (subject linear-<identifier>, e.g. linear-cod-123). Idempotent: unchanged
      issues emit nothing. Issues already Done/Canceled in Linear close the task.
  cobus linear push [COD-123 ...|--all] [--dry-run]
      mirror each mapped task's ledger activity (claim owner + branch, notes,
      block reason, completion) into ONE persistent `coordkit ledger` comment on
      the issue (created once, then updated in place), move the issue to
      claim_state / done_state, and add/remove the blocked_label.
  cobus linear sync [--loop <secs>] [--dry-run]
      pull then push --all; --loop repeats forever (SIGINT-safe, errors are
      logged and retried next round).
  cobus linear link <task-subject> <COD-123>
      map an existing ledger task onto a Linear issue for push.
  cobus linear status
      config, auth presence (never the key), last pull/push, mapping table.

Env:  LINEAR_API_KEY (required for pull/push/sync; secrets never go in coord.toml)
      COORDKIT_LINEAR_ENDPOINT, COORDKIT_LINEAR_RETRIES, COORDKIT_LINEAR_BACKOFF_S,
      COORDKIT_LINEAR_CURL (offline HTTP stub, see tests/linear-bridge.sh)
Config: [linear] table in .claude/coord/coord.toml — team_key (required),
      project, label, states, claim_state, done_state, blocked_label, poll_s.
Docs: docs/LINEAR.md
EOF
}

# ── config ───────────────────────────────────────────────────────────────────
root="$(resolve_root "$(ck_project_dir)")"
TOML="$(ck_coord_toml "$root")"
STATE_DIR="$(ck_coord_dir "$root")/linear"
STATE_FILE="${STATE_DIR}/state.json"

_cfg() { # <key> <default>
  local v
  v="$(ck_first_env "COORDKIT_LINEAR_$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')" 2>/dev/null)"
  [ -n "$v" ] || v="$(ck_toml_table_get "$TOML" linear "$1" 2>/dev/null)"
  printf '%s' "${v:-$2}"
}
TEAM_KEY="$(_cfg team_key "")"
PROJECT="$(_cfg project "")"
LABEL="$(_cfg label "")"
STATES="$(_cfg states "Todo,In Progress")"
CLAIM_STATE="$(_cfg claim_state "In Progress")"
DONE_STATE="$(_cfg done_state "Done")"
BLOCKED_LABEL="$(_cfg blocked_label "blocked")"
POLL_S="$(_cfg poll_s 60)"
case "$POLL_S" in ''|*[!0-9]*|0) POLL_S=60 ;; esac

now() { date +%s; }
_err() { printf 'linear: %s\n' "$*" >&2; }
_die() { local code="$1"; shift; _err "$@"; exit "$code"; }

require_team() {
  [ -n "$TEAM_KEY" ] || _die 2 "no [linear].team_key in ${TOML} (add e.g. team_key = \"COD\") — see docs/LINEAR.md"
}
require_key() {
  [ -n "${COORDKIT_LINEAR_CURL:-}" ] && return 0
  [ -n "${LINEAR_API_KEY:-}" ] && return 0
  _die 2 "LINEAR_API_KEY is not set. Create a personal API key (Linear → Settings → Security & access → Personal API keys) and export it in your shell (never in coord.toml). See docs/LINEAR.md."
}
_ident_ok() { printf '%s' "$1" | grep -Eq '^[A-Z][A-Z0-9]*-[0-9]+$'; }
_ident_subject() { slug "linear-$1"; }   # COD-123 -> linear-cod-123
_ident_number() { printf '%s' "${1##*-}"; }

# ── local state (.claude/coord/linear/state.json, gitignored) ───────────────
state_init() {
  mkdir -p "$STATE_DIR" 2>/dev/null || return 1
  [ -f "${STATE_DIR}/.gitignore" ] || printf '*\n' > "${STATE_DIR}/.gitignore" 2>/dev/null
  ck_git_info_exclude_add "$root" '/.claude/coord/linear/' 2>/dev/null || true
  jq -e 'type=="object"' "$STATE_FILE" >/dev/null 2>&1 || printf '{"issues":{},"links":{},"states":{}}\n' > "$STATE_FILE"
}
state_get() { jq -r "$@" "$STATE_FILE" 2>/dev/null; }   # [--arg ...] <filter>
# state_set <jq-filter> [jq --arg/--argjson pairs...]  (atomic, locked)
state_set() {
  local filter="$1"; shift
  ( flock 6
    jq -c "$@" "$filter" "$STATE_FILE" > "${STATE_FILE}.tmp.$$" 2>/dev/null && mv -f "${STATE_FILE}.tmp.$$" "$STATE_FILE"
  ) 6>"${STATE_FILE}.lock"
}

# ── GraphQL transport ────────────────────────────────────────────────────────
# _linear_http: request JSON on stdin → response body on stdout.
# exit 0 = HTTP 200; 75 = retryable (network / 429 / 5xx); 77 = auth (401/403);
# 1 = other non-retryable HTTP error.
_linear_http() {
  if [ -n "${COORDKIT_LINEAR_CURL:-}" ]; then
    local rc; "$COORDKIT_LINEAR_CURL"; rc=$?
    [ "$rc" = 0 ] && return 0
    return 75
  fi
  local body code
  body="$(mktemp "${TMPDIR:-/tmp}/ck-linear.XXXXXX")" || return 75
  code="$(curl -sS --max-time 30 -o "$body" -w '%{http_code}' \
      -H 'Content-Type: application/json' -H "Authorization: ${LINEAR_API_KEY}" \
      --data-binary @- "$ENDPOINT" 2>/dev/null)"
  local rc=$?
  if [ "$rc" != 0 ]; then rm -f "$body"; return 75; fi
  case "$code" in
    200) cat "$body"; rm -f "$body"; return 0 ;;
    401|403) rm -f "$body"; return 77 ;;
    429|5*) rm -f "$body"; return 75 ;;
    *) cat "$body" >&2; rm -f "$body"; return 1 ;;
  esac
}
# linear_gql <query> [variables_json] → response JSON (data) on stdout.
# Retries transport failures with exponential backoff; GraphQL-level errors are
# printed to stderr and return 1 (a bridge round can carry on with other issues).
linear_gql() {
  local query="$1" vars="${2:-{\}}" req out rc attempt=0 wait
  req="$(jq -nc --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')" || return 1
  while :; do
    out="$(printf '%s' "$req" | _linear_http)"; rc=$?
    case "$rc" in
      0) ;;
      77) _die 3 "Linear rejected the API key (HTTP 401/403). Check LINEAR_API_KEY." ;;
      75)
        attempt=$(( attempt + 1 ))
        if [ "$attempt" -gt "$RETRIES" ]; then _err "Linear API unreachable after ${RETRIES} retries"; return 75; fi
        wait="$(awk -v b="$BACKOFF" -v a="$attempt" 'BEGIN{printf "%.2f", b * (2 ^ (a - 1))}')"
        _err "transient Linear API failure (attempt ${attempt}/${RETRIES}) — retrying in ${wait}s"
        sleep "$wait"; continue ;;
      *) return 1 ;;
    esac
    if printf '%s' "$out" | jq -e '.errors? | length > 0' >/dev/null 2>&1; then
      _err "GraphQL error: $(printf '%s' "$out" | jq -r '[.errors[].message] | join("; ")' 2>/dev/null)"
      return 1
    fi
    printf '%s' "$out"; return 0
  done
}
# linear_mutate <query> <vars> — like linear_gql, but honours --dry-run by
# printing the mutation it WOULD send and returning a synthetic success.
linear_mutate() {
  if [ "$DRY_RUN" = 1 ]; then
    { printf 'DRY-RUN mutation → %s\n' "$ENDPOINT"
      printf '%s\n' "$1" | sed 's/^/    /'
      printf '    variables: %s\n' "$(printf '%s' "$2" | jq -c . 2>/dev/null || printf '%s' "$2")"; } >&5
    printf '{"data":{"dryRun":true}}'; return 0
  fi
  linear_gql "$1" "$2"
}

# ── Linear lookups ───────────────────────────────────────────────────────────
Q_ISSUE_FIELDS='id identifier number title url priority updatedAt state { id name type } assignee { name displayName email } team { id key } labels { nodes { id name } }'

# issue_lookup COD-123 → issue node JSON (or empty)
issue_lookup() {
  local ident="$1" n out
  n="$(_ident_number "$ident")"
  out="$(linear_gql "query(\$key:String!,\$n:Float!){ issues(first:1, filter:{ team:{ key:{ eq:\$key } }, number:{ eq:\$n } }) { nodes { ${Q_ISSUE_FIELDS} } } }" \
        "$(jq -nc --arg k "${ident%%-*}" --argjson n "$n" '{key:$k, n:$n}')")" || return 1
  printf '%s' "$out" | jq -c '.data.issues.nodes[0] // empty'
}
# workflow_state_id <team_key> <state name> — cached in state.json
workflow_state_id() {
  local key="$1" name="$2" id
  id="$(state_get --arg k "$key" --arg n "$name" '.states[$k][$n] // empty')"
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  id="$(linear_gql 'query($key:String!,$name:String!){ workflowStates(filter:{ team:{ key:{ eq:$key } }, name:{ eq:$name } }) { nodes { id name type } } }' \
        "$(jq -nc --arg key "$key" --arg name "$name" '{key:$key,name:$name}')" | jq -r '.data.workflowStates.nodes[0].id // empty')"
  [ -n "$id" ] || { _err "no workflow state named '${name}' in team ${key}"; return 1; }
  state_set '.states[$k][$n]=$id' --arg k "$key" --arg n "$name" --arg id "$id"
  printf '%s' "$id"
}
# label_id <team_id> <name> — find (workspace or team label) or create on the team
label_id() {
  local team_id="$1" name="$2" id
  id="$(state_get --arg n "$name" '.labels[$n] // empty')"
  [ -n "$id" ] && { printf '%s' "$id"; return 0; }
  id="$(linear_gql 'query($name:String!){ issueLabels(first:5, filter:{ name:{ eq:$name } }) { nodes { id name team { id } } } }' \
        "$(jq -nc --arg name "$name" '{name:$name}')" | jq -r --arg t "$team_id" '[.data.issueLabels.nodes[] | select(.team==null or .team.id==$t)][0].id // empty')"
  if [ -z "$id" ]; then
    id="$(linear_mutate 'mutation($name:String!,$teamId:String!){ issueLabelCreate(input:{ name:$name, teamId:$teamId }) { success issueLabel { id } } }' \
          "$(jq -nc --arg name "$name" --arg teamId "$team_id" '{name:$name,teamId:$teamId}')" | jq -r '.data.issueLabelCreate.issueLabel.id // empty')"
  fi
  [ -n "$id" ] || return 1
  state_set '.labels[$n]=$id' --arg n "$name" --arg id "$id"
  printf '%s' "$id"
}

# ── pull ─────────────────────────────────────────────────────────────────────
cmd_pull() {
  local states="$STATES" assignee_me=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --state|--states) shift; states="${1:-}" ;;
      --assignee) shift; [ "${1:-}" = me ] || _die 2 "only --assignee me is supported"; assignee_me=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; return 0 ;;
      *) _die 2 "pull: unknown argument: $1" ;;
    esac; shift
  done
  require_team; require_key; state_init || _die 1 "cannot write ${STATE_DIR}"
  local filter
  filter="$(jq -nc --arg key "$TEAM_KEY" --arg states "$states" --arg project "$PROJECT" --arg label "$LABEL" --argjson me "$assignee_me" '
    {team:{key:{eq:$key}}}
    + (if $states != "" then {state:{name:{in:($states|split(",")|map(gsub("^\\s+|\\s+$";"")|select(.!="")))}}} else {} end)
    + (if $project != "" then {project:{name:{eq:$project}}} else {} end)
    + (if $label != "" then {labels:{name:{eq:$label}}} else {} end)
    + (if $me == 1 then {assignee:{isMe:{eq:true}}} else {} end)')"
  local after=null page nodes all='[]' has
  while :; do
    page="$(linear_gql "query(\$filter:IssueFilter,\$after:String){ issues(first:50, after:\$after, filter:\$filter, orderBy:updatedAt) { nodes { ${Q_ISSUE_FIELDS} } pageInfo { hasNextPage endCursor } } }" \
            "$(jq -nc --argjson f "$filter" --argjson a "$after" '{filter:$f, after:$a}')")" || return 1
    nodes="$(printf '%s' "$page" | jq -c '.data.issues.nodes // []')"
    all="$(jq -nc --argjson a "$all" --argjson b "$nodes" '$a + $b')"
    has="$(printf '%s' "$page" | jq -r '.data.issues.pageInfo.hasNextPage // false')"
    [ "$has" = true ] || break
    after="$(printf '%s' "$page" | jq -c '.data.issues.pageInfo.endCursor')"
  done
  local total upserted=0 unchanged=0 closed=0 board
  total="$(printf '%s' "$all" | jq 'length')"
  board="$(bash "$LEDGER" tasks-json linear- 2>/dev/null)"
  local ident subj desc refs tags stype out st
  while IFS=$'\t' read -r ident subj desc refs tags stype; do
    [ -n "$ident" ] || continue
    if [ "$DRY_RUN" = 1 ]; then
      printf 'DRY-RUN ledger: task-as %s %s\n' "$subj" "$desc"
    else
      out="$(bash "$LEDGER" task-as "$subj" "$desc" "$(printf '%s' "$refs" | base64 -d 2>/dev/null)" "$(printf '%s' "$tags" | base64 -d 2>/dev/null)" 2>/dev/null)"
      case "$out" in unchanged*) unchanged=$(( unchanged + 1 )) ;; *) upserted=$(( upserted + 1 )); printf '  %s\n' "$out" ;; esac
    fi
    case "$stype" in
      completed|canceled)
        st="$(printf '%s' "$board" | jq -r --arg s "$subj" 'select(.subject==$s) | .status' | head -n1)"
        if [ "${st:-open}" != done ]; then
          if [ "$DRY_RUN" = 1 ]; then printf 'DRY-RUN ledger: done %s (Linear state is %s)\n' "$subj" "$stype"
          else bash "$LEDGER" done "$subj" >/dev/null 2>&1; closed=$(( closed + 1 )); fi
        fi ;;
    esac
  done < <(printf '%s' "$all" | jq -r '
      .[] | (.identifier) as $id
      | ("linear-" + ($id|ascii_downcase)) as $subj
      | (.assignee.displayName // .assignee.name // "") as $who
      | ($id + ": " + .title + " [" + .state.name
          + (if .priority != null and .priority > 0 then " · P" + (.priority|tostring) else "" end)
          + (if $who != "" then " · @" + $who else "" end) + "] " + .url) as $desc
      | ([ "linear", "state:" + .state.name ]
          + (if .priority != null then ["priority:" + (.priority|tostring)] else [] end)
          + (if $who != "" then ["assignee:" + $who] else [] end)) as $tags
      | [$id, $subj, $desc, ([.url]|tojson|@base64), ($tags|tojson|@base64), (.state.type // "")] | @tsv')
  # remember every fetched issue locally (id, subject, url, state) for push/status
  if [ "$DRY_RUN" != 1 ]; then
    state_set '
      reduce $all[] as $i (.;
        .issues[$i.identifier] = ((.issues[$i.identifier] // {}) + {
          id:$i.id, subject:("linear-" + ($i.identifier|ascii_downcase)), url:$i.url, title:$i.title,
          team_id:$i.team.id, state:$i.state.name, state_type:$i.state.type, pulled_at:$now }))
      | .last_pull=$now' --argjson all "$all" --argjson now "$(now)"
  fi
  printf 'linear pull: %s issue(s) matched [team %s%s%s, states: %s] → %s upserted, %s unchanged, %s closed\n' \
    "$total" "$TEAM_KEY" "${PROJECT:+, project $PROJECT}" "${LABEL:+, label $LABEL}" "${states:-any}" "$upserted" "$unchanged" "$closed"
}

# ── push ─────────────────────────────────────────────────────────────────────
# ledger_projection <subject> <identifier> <events-file> → JSON summary of the
# task's ledger history: bridge status, last claim/done/block, timeline lines.
ledger_projection() {
  local subj="$1" ident="$2" evf="$3"
  jq -Rsc --arg s "$subj" --arg id "$ident" --argjson now "$(now)" --argjson max "$TIMELINE_MAX" '
    [split("\n")[] | select(length>0) | fromjson? | select(type=="object")]
    | map(select(((.subject // "") == $s)
                 or ((.type // "") == "note" and (((.body // "")|ascii_downcase) | (contains($id|ascii_downcase) or contains($s))))))
    | sort_by((.seq // 0), (.ts // 0))
    | . as $ev
    | ([ $ev[] | select(.type=="claim") ] | last) as $claim
    | ([ $ev[] | select(.type=="done")  ] | last) as $done
    | ([ $ev[] | select(.type=="block") ] | last) as $block
    | ([ $ev[] | select(.type=="task")  ] | last) as $task
    | ([ $ev[] | select(.type=="claim" or .type=="done" or .type=="block") ] | last) as $lastct
    | ($claim.lease | if type=="object" then (.until // 0) elif type=="number" then . else 0 end) as $until
    | (if $lastct == null then "open"
       elif $lastct.type == "done" then "done"
       elif $lastct.type == "block" then "blocked"
       elif $until > $now then "in-progress"
       else "claim-expired" end) as $status
    | {subject:$s, identifier:$id, status:$status, n:($ev|length),
       task:$task, claim:$claim, done:$done, block:$block,
       lease_until:$until,
       last:($ev|last),
       timeline:([ $ev | .[-($max):][]?
                   | "- `" + ((.ts // 0)|todate) + "` **" + (.type // "?") + "** · `"
                     + ((.actor // .sid8 // "?")|tostring) + "`" + (if (.branch // "") != "" then " (" + .branch + ")" else "" end)
                     + " — " + ((.body // "")|tostring|gsub("[\\r\\n]+";" ")|.[0:240]) ] | join("\n"))}
  ' "$evf"
}
compose_comment() { # <projection-json> <ident> <issue-url> → markdown body on stdout
  local proj="$1" ident="$2" me_actor me_host
  me_actor="$(ck_actor)"; me_host="$(hostname 2>/dev/null || printf 'unknown-host')"
  printf '%s' "$proj" | jq -r --arg ident "$ident" --arg repo "$(basename "$root")" \
      --arg me_actor "$me_actor" --arg me_host "$me_host" --arg pushed "$(date -u '+%Y-%m-%d %H:%M:%S UTC')" '
    def line(k; v): "- **" + k + ":** " + v;
    (.claim // {}) as $c
    | (if $c.actor == $me_actor then " ← this machine: `" + $me_host + "`" else "" end) as $mine
    | [ "<!-- coordkit:ledger:v1 subject=" + .subject + " -->",
        "## coordkit ledger · " + $ident,
        "",
        line("Ledger status"; "`" + .status + "`"
             + (if .status == "claim-expired" then " (lease lapsed at " + (.lease_until|todate) + " — reclaimable)" else "" end)),
        (if $c != {} then
           line("Worker"; "`" + (($c.actor // $c.sid8 // "?")|tostring) + "`"
                + " · user `" + (($c.user // "?")|tostring) + "` · session `" + (($c.sid8 // "?")|tostring) + "` · host `" + (($c.host // "?")|tostring) + "`" + $mine)
         else line("Worker"; "_unclaimed_") end),
        line("Branch"; (if ($c.branch // "") != "" then "`" + $c.branch + "`" else "_n/a_" end)),
        line("Last ledger event"; (if .last then "`" + ((.last.ts // 0)|todate) + "` · seq " + ((.last.seq // 0)|tostring) + " · " + (.last.type // "?") else "_none_" end)),
        line("Ledger task"; "`" + .subject + "` in repo `" + $repo + "` (" + (.n|tostring) + " event(s))"),
        (if .status == "blocked" then "", "### ⛔ Blocked", "> " + ((.block.body // "")|tostring), "" else empty end),
        (if .status == "done" then "", "### ✅ Done", "> " + ((.done.body // "")|tostring) + " at `" + ((.done.ts // 0)|todate) + "`", "" else empty end),
        "",
        "### Timeline (last " + (( .timeline|split("\n")|map(select(length>0))|length )|tostring) + " ledger events)",
        (if .timeline == "" then "_no ledger events yet_" else .timeline end),
        "",
        "---",
        "_Maintained by **coordkit** (`cobus linear push`) — regenerated in place on every push, do not edit by hand. Separate from Symphony'"'"'s `## Codex Workpad` comment. Last push from `" + $me_host + "` (`" + $me_actor + "`) at " + $pushed + "._"
      ] | join("\n")'
}
_body_hash() { printf '%s' "$1" | sed '$d' | sha256sum | cut -c1-32; }   # footer (last line) carries the push timestamp → excluded

find_marker_comment() { # <issue-id> <subject> → comment id or empty
  linear_gql 'query($id:String!){ issue(id:$id) { comments(first:50) { nodes { id body } } } }' \
    "$(jq -nc --arg id "$1" '{id:$id}')" 2>/dev/null \
    | jq -r --arg m "${MARKER} subject=$2 " '[.data.issue.comments.nodes[]? | select(.body|startswith($m))][0].id // empty'
}

push_one() { # <identifier> <events-file>
  local ident="$1" evf="$2" subj issue iid team_id cur_state cur_type url proj status body hash prev_hash cid out
  subj="$(state_get --arg i "$ident" '.issues[$i].subject // empty')"
  [ -n "$subj" ] || subj="$(_ident_subject "$ident")"
  proj="$(ledger_projection "$subj" "$ident" "$evf")"
  status="$(printf '%s' "$proj" | jq -r '.status')"
  if [ "$(printf '%s' "$proj" | jq -r '.n')" = 0 ]; then
    printf '  %-10s %-22s no ledger activity — nothing to push\n' "$ident" "$subj"; return 0
  fi
  issue="$(issue_lookup "$ident")" || { _err "${ident}: lookup failed — skipped"; return 1; }
  [ -n "$issue" ] || { _err "${ident}: not found in team ${ident%%-*} — skipped"; return 1; }
  iid="$(printf '%s' "$issue" | jq -r .id)"; team_id="$(printf '%s' "$issue" | jq -r .team.id)"
  cur_state="$(printf '%s' "$issue" | jq -r .state.name)"; cur_type="$(printf '%s' "$issue" | jq -r .state.type)"
  url="$(printf '%s' "$issue" | jq -r .url)"
  state_set '.issues[$i] = ((.issues[$i] // {}) + {id:$iid, subject:$s, url:$u, team_id:$t, state:$st, state_type:$ty})' \
    --arg i "$ident" --arg iid "$iid" --arg s "$subj" --arg u "$url" --arg t "$team_id" --arg st "$cur_state" --arg ty "$cur_type"

  local actions=""
  # 1) workflow-state transition (never demote: claim only lifts an unstarted issue)
  local want="" sid_
  case "$status" in
    done)        [ "$cur_type" = completed ] || [ "$cur_type" = canceled ] || want="$DONE_STATE" ;;
    in-progress) [ "$cur_type" = unstarted ] && want="$CLAIM_STATE" ;;
  esac
  if [ -n "$want" ] && [ "$want" != "$cur_state" ]; then
    sid_="$(workflow_state_id "${ident%%-*}" "$want")" && \
      linear_mutate 'mutation($id:String!,$stateId:String!){ issueUpdate(id:$id, input:{ stateId:$stateId }) { success } }' \
        "$(jq -nc --arg id "$iid" --arg stateId "$sid_" '{id:$id,stateId:$stateId}')" >/dev/null \
      && { actions="${actions} state→${want}"; state_set '.issues[$i].state=$st' --arg i "$ident" --arg st "$want"; }
  fi
  # 2) blocked label
  if [ -n "$BLOCKED_LABEL" ]; then
    local has_label lid
    has_label="$(printf '%s' "$issue" | jq -r --arg n "$BLOCKED_LABEL" '[.labels.nodes[]?|select(.name==$n)]|length')"
    if [ "$status" = blocked ] && [ "${has_label:-0}" = 0 ]; then
      lid="$(label_id "$team_id" "$BLOCKED_LABEL")" && \
        linear_mutate 'mutation($id:String!,$labelId:String!){ issueAddLabel(id:$id, labelId:$labelId) { success } }' \
          "$(jq -nc --arg id "$iid" --arg labelId "$lid" '{id:$id,labelId:$labelId}')" >/dev/null \
        && { actions="${actions} +label:${BLOCKED_LABEL}"; state_set '.issues[$i].blocked_label=true' --arg i "$ident"; }
    elif [ "$status" != blocked ] && [ "${has_label:-0}" != 0 ] && [ "$(state_get --arg i "$ident" '.issues[$i].blocked_label // false')" = true ]; then
      lid="$(label_id "$team_id" "$BLOCKED_LABEL")" && \
        linear_mutate 'mutation($id:String!,$labelId:String!){ issueRemoveLabel(id:$id, labelId:$labelId) { success } }' \
          "$(jq -nc --arg id "$iid" --arg labelId "$lid" '{id:$id,labelId:$labelId}')" >/dev/null \
        && { actions="${actions} -label:${BLOCKED_LABEL}"; state_set '.issues[$i].blocked_label=false' --arg i "$ident"; }
    fi
  fi
  # 3) the ONE persistent comment (create once, then update in place)
  body="$(compose_comment "$proj" "$ident")"
  hash="$(_body_hash "$body")"
  prev_hash="$(state_get --arg i "$ident" '.issues[$i].last_push_hash // empty')"
  cid="$(state_get --arg i "$ident" '.issues[$i].comment_id // empty')"
  if [ "$hash" = "$prev_hash" ] && [ -n "$cid" ]; then
    printf '  %-10s %-22s %-13s comment unchanged%s\n' "$ident" "$subj" "$status" "${actions:+ ·$actions}"; return 0
  fi
  [ -n "$cid" ] || cid="$(find_marker_comment "$iid" "$subj")"
  if [ -n "$cid" ]; then
    out="$(linear_mutate 'mutation($id:String!,$body:String!){ commentUpdate(id:$id, input:{ body:$body }) { success comment { id } } }' \
            "$(jq -nc --arg id "$cid" --arg body "$body" '{id:$id,body:$body}')")" || { _err "${ident}: comment update failed"; return 1; }
    actions="${actions} comment-updated"
  else
    out="$(linear_mutate 'mutation($issueId:String!,$body:String!){ commentCreate(input:{ issueId:$issueId, body:$body }) { success comment { id } } }' \
            "$(jq -nc --arg issueId "$iid" --arg body "$body" '{issueId:$issueId,body:$body}')")" || { _err "${ident}: comment create failed"; return 1; }
    cid="$(printf '%s' "$out" | jq -r '.data.commentCreate.comment.id // empty')"
    actions="${actions} comment-created"
  fi
  if [ "$DRY_RUN" != 1 ]; then
    state_set '.issues[$i] += {comment_id:(if $cid != "" then $cid else .issues[$i].comment_id end), last_push_hash:$h, last_push_ts:$now, last_push_status:$st} | .last_push=$now' \
      --arg i "$ident" --arg cid "$cid" --arg h "$hash" --argjson now "$(now)" --arg st "$status"
  fi
  printf '  %-10s %-22s %-13s%s\n' "$ident" "$subj" "$status" "${actions:+ ·$actions}"
}

cmd_push() {
  local idents=() all=0 a
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) all=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; return 0 ;;
      -*) _die 2 "push: unknown option: $1" ;;
      *) a="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; _ident_ok "$a" || _die 2 "push: '$1' is not a Linear identifier (e.g. COD-123)"; idents+=("$a") ;;
    esac; shift
  done
  require_team; require_key; state_init || _die 1 "cannot write ${STATE_DIR}"
  if [ "${#idents[@]}" = 0 ]; then
    all=1
    # every mapped issue: pulled ones + explicit links + any linear-<team>-N task on the board
    while IFS= read -r a; do [ -n "$a" ] && idents+=("$a"); done < <(
      { state_get '.issues | keys[]'; state_get '.links[]';
        bash "$LEDGER" tasks-json "linear-$(printf '%s' "$TEAM_KEY" | tr '[:upper:]' '[:lower:]')-" 2>/dev/null \
          | jq -r '.subject | ltrimstr("linear-") | ascii_upcase'; } | grep -E '^[A-Z][A-Z0-9]*-[0-9]+$' | sort -u)
  fi
  [ "${#idents[@]}" -gt 0 ] || { echo "linear push: nothing mapped yet — run \`cobus linear pull\` or \`cobus linear link <task> <ID>\` first."; return 0; }
  local evf; evf="$(mktemp "${TMPDIR:-/tmp}/ck-linear-ev.XXXXXX")"
  bash "$LEDGER" events > "$evf" 2>/dev/null
  local ok=0 fail=0
  printf 'linear push [%s]%s\n' "$( [ "$all" = 1 ] && printf 'all mapped: %s issue(s)' "${#idents[@]}" || printf '%s issue(s)' "${#idents[@]}")" "$( [ "$DRY_RUN" = 1 ] && printf ' (dry-run)')"
  for a in "${idents[@]}"; do
    if push_one "$a" "$evf"; then ok=$(( ok + 1 )); else fail=$(( fail + 1 )); fi
  done
  rm -f "$evf"
  printf 'linear push: %s ok, %s failed\n' "$ok" "$fail"
  [ "$fail" = 0 ]
}

# ── sync ─────────────────────────────────────────────────────────────────────
cmd_sync() {
  local loop=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --loop) shift; loop="${1:-$POLL_S}"; case "$loop" in ''|*[!0-9]*) loop="$POLL_S" ;; esac; [ "$loop" -gt 0 ] || loop="$POLL_S" ;;
      --dry-run) DRY_RUN=1 ;;
      -h|--help) usage; return 0 ;;
      *) _die 2 "sync: unknown argument: $1" ;;
    esac; shift
  done
  require_team; require_key
  local stop=0
  trap 'stop=1' INT TERM
  while :; do
    cmd_pull || _err "pull failed$( [ "$loop" -gt 0 ] && printf ' — will retry next round')"
    cmd_push --all || _err "push had failures$( [ "$loop" -gt 0 ] && printf ' — will retry next round')"
    [ "$loop" -gt 0 ] || break
    [ "$stop" = 1 ] && break
    printf 'linear sync: sleeping %ss (Ctrl-C to stop)\n' "$loop"
    sleep "$loop" & _sl=$!; wait "$_sl" 2>/dev/null
    [ "$stop" = 1 ] && { kill "$_sl" 2>/dev/null; echo "linear sync: stopped."; break; }
  done
  return 0
}

# ── link / status ────────────────────────────────────────────────────────────
cmd_link() {
  local subj ident
  subj="$(slug "${1:-}")"; ident="$(printf '%s' "${2:-}" | tr '[:lower:]' '[:upper:]')"
  { [ -n "$subj" ] && _ident_ok "$ident"; } || _die 2 "usage: cobus linear link <task-subject> <COD-123>"
  state_init || _die 1 "cannot write ${STATE_DIR}"
  state_set '.links[$s]=$i | .issues[$i] = ((.issues[$i] // {}) + {subject:$s, linked_at:$now})' \
    --arg s "$subj" --arg i "$ident" --argjson now "$(now)"
  bash "$LEDGER" note "linear: task '${subj}' ↔ ${ident} (linked by $(ck_actor))" >/dev/null 2>&1 || true
  echo "🔗 linked ledger task '${subj}' ↔ ${ident} (state: ${STATE_FILE})"
}
_when() { [ -n "${1:-}" ] && [ "$1" -gt 0 ] 2>/dev/null && date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ' 2>/dev/null || printf 'never'; }
cmd_status() {
  local auth="missing" lp lpush
  [ -n "${LINEAR_API_KEY:-}" ] && auth="present (env LINEAR_API_KEY, ${#LINEAR_API_KEY} chars)"
  [ -n "${COORDKIT_LINEAR_CURL:-}" ] && auth="${auth}; HTTP stubbed via COORDKIT_LINEAR_CURL"
  echo "🔗 coordkit ⇄ Linear bridge — ${root}"
  printf '  config:    %s\n' "$TOML"
  printf '  team_key:  %s\n' "${TEAM_KEY:-(unset — required)}"
  printf '  project:   %s   label: %s\n' "${PROJECT:-(any)}" "${LABEL:-(any)}"
  printf '  states:    %s   claim→%s   done→%s   blocked→label:%s\n' "$STATES" "$CLAIM_STATE" "$DONE_STATE" "${BLOCKED_LABEL:-(comment only)}"
  printf '  poll_s:    %s   endpoint: %s\n' "$POLL_S" "$ENDPOINT"
  printf '  auth:      %s\n' "$auth"
  printf '  state:     %s\n' "$STATE_FILE"
  if jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    lp="$(state_get '.last_pull // empty')"; lpush="$(state_get '.last_push // empty')"
    printf '  last pull: %s   last push: %s\n' "$(_when "$lp")" "$(_when "$lpush")"
    echo
    printf '  %-10s %-24s %-14s %-14s %-8s %s\n' ISSUE LEDGER-TASK LINEAR-STATE LEDGER-STATUS COMMENT LAST-PUSH
    local board; board="$(bash "$LEDGER" tasks-json linear- 2>/dev/null)"
    state_get '.issues | to_entries[] | [.key, (.value.subject // ""), (.value.state // "?"), (if .value.comment_id then "yes" else "no" end), (.value.last_push_ts // 0|tostring)] | @tsv' \
    | while IFS=$'\t' read -r i s st c t; do
        local ls; ls="$(printf '%s' "$board" | jq -r --arg s "$s" 'select(.subject==$s)|.status' | head -n1)"
        printf '  %-10s %-24s %-14s %-14s %-8s %s\n' "$i" "$s" "$st" "${ls:-—}" "$c" "$(_when "$t")"
      done
    [ "$(state_get '.issues|length')" = 0 ] && echo "  (no issues mapped yet — run: cobus linear pull)"
    :
  else
    echo "  (no bridge state yet — run: cobus linear pull)"
  fi
}

# ── dispatch ─────────────────────────────────────────────────────────────────
for _a in "$@"; do [ "$_a" = --dry-run ] && DRY_RUN=1; done
cmd="${1:-}"; shift || true
case "$cmd" in
  pull)   cmd_pull "$@" ;;
  push)   cmd_push "$@" ;;
  sync)   cmd_sync "$@" ;;
  link)   cmd_link "$@" ;;
  status) cmd_status "$@" ;;
  ""|-h|--help|help) usage ;;
  *) _die 2 "unknown subcommand '${cmd}' — try: cobus linear --help" ;;
esac
