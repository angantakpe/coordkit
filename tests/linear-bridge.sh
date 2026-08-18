#!/usr/bin/env bash
# tests/linear-bridge.sh — offline coverage for `cobus linear` (scripts/linear.sh).
# The Linear GraphQL endpoint is replaced by tests/fixtures/fake-linear-gql.sh via
# COORDKIT_LINEAR_CURL; nothing here touches the network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
FAKE="${ROOT}/tests/fixtures/fake-linear-gql.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-linear.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
trap 'status=$?; printf "linear-bridge: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

repo="$tmp/repo"
mkdir -p "$repo/.claude/coord" "$tmp/data"
git -C "$repo" init -q
git -C "$repo" checkout -q -b feature/cod-1 2>/dev/null || true
cat > "$repo/.claude/coord/coord.toml" <<'EOF'
mode = "local"

[linear]
team_key = "COD"
states = "Todo,In Progress"
poll_s = 5
EOF

export FAKE_LINEAR_DB="$tmp/db.json" FAKE_LINEAR_LOG="$tmp/gql.log" FAKE_LINEAR_FAIL="$tmp/fail"
cat > "$FAKE_LINEAR_DB" <<'EOF'
{
  "issues": [
    {"id":"iss-1","identifier":"COD-1","number":1,"title":"Add the bridge","url":"https://linear.app/x/issue/COD-1","priority":2,"updatedAt":"2026-08-18T00:00:00Z",
     "state":{"id":"ws-todo","name":"Todo","type":"unstarted"},"assignee":{"name":"Anga","displayName":"anga","email":"a@x","isMe":true},
     "team":{"id":"team-cod","key":"COD"},"labels":{"nodes":[]}},
    {"id":"iss-2","identifier":"COD-2","number":2,"title":"Second issue","url":"https://linear.app/x/issue/COD-2","priority":0,"updatedAt":"2026-08-18T00:00:00Z",
     "state":{"id":"ws-in-progress","name":"In Progress","type":"started"},"assignee":null,
     "team":{"id":"team-cod","key":"COD"},"labels":{"nodes":[]}},
    {"id":"iss-3","identifier":"COD-3","number":3,"title":"Already shipped","url":"https://linear.app/x/issue/COD-3","priority":1,"updatedAt":"2026-08-18T00:00:00Z",
     "state":{"id":"ws-done","name":"Done","type":"completed"},"assignee":null,
     "team":{"id":"team-cod","key":"COD"},"labels":{"nodes":[]}}
  ],
  "comments": [
    {"id":"cmt-symphony","issueId":"iss-1","body":"## Codex Workpad\n- [ ] something"}
  ],
  "labels": []
}
EOF
: > "$FAKE_LINEAR_LOG"

run() {  # run <args...> — cobus linear from inside the repo, offline
  ( cd "$repo" && env COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/data" COORDKIT_HOST=cli \
      COORDKIT_LINEAR_CURL="$FAKE" COORDKIT_LINEAR_BACKOFF_S=0 COORDKIT_LINEAR_RETRIES=3 \
      "$PLUGIN/bin/cobus" linear "$@" )
}
ledger() { ( cd "$repo" && env COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/data" COORDKIT_HOST=cli "$PLUGIN/bin/cobus" "$@" ); }
LEDGER_FILE="$repo/.coordkit-bus/ledger.jsonl"
STATE="$repo/.claude/coord/linear/state.json"
expect() {  # expect <grep-pattern> <cmd...> — run cmd, assert pattern in its stdout (no SIGPIPE)
  local pat="$1" o; shift; o="$("$@")" || true
  printf '%s\n' "$o" | grep -q -- "$pat" || { printf 'expected /%s/ in output of: %s\n%s\n' "$pat" "$*" "$o" >&2; return 1; }
}
mutations() { jq -r 'select(.query|test("mutation")) | .query | capture("\\{ (?<m>[a-zA-Z]+)\\(") | .m' "$FAKE_LINEAR_LOG"; }

# ── 1. missing key → clear message, non-zero exit, no crash ─────────────────
rc=0
out="$( cd "$repo" && env -u LINEAR_API_KEY -u COORDKIT_LINEAR_CURL COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/data" "$PLUGIN/bin/cobus" linear pull 2>&1 )" || rc=$?
test "$rc" -eq 2
printf '%s' "$out" | grep -q 'LINEAR_API_KEY is not set'
printf '%s' "$out" | grep -q 'docs/LINEAR.md'
# status must never print a key value
out="$( cd "$repo" && env LINEAR_API_KEY='lin_api_SECRETVALUE' COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/data" "$PLUGIN/bin/cobus" linear status )"
printf '%s' "$out" | grep -q 'auth:      present'
! printf '%s' "$out" | grep -q 'SECRETVALUE'
# help never needs a key
expect 'cobus linear pull' run --help

# ── 2. pull creates tasks idempotently ──────────────────────────────────────
out="$(run pull)"
printf '%s\n' "$out" | grep -q '2 issue(s) matched'
printf '%s\n' "$out" | grep -q '2 upserted, 0 unchanged'
test "$(jq -r 'select(.type=="task") | .subject' "$LEDGER_FILE" | sort | tr '\n' ' ')" = "linear-cod-1 linear-cod-2 "
jq -e 'select(.subject=="linear-cod-1" and .type=="task") | (.body|test("COD-1: Add the bridge \\[Todo · P2 · @anga\\] https://linear.app/x/issue/COD-1")) and (.refs==["https://linear.app/x/issue/COD-1"]) and (.tags|index("linear")) and (.tags|index("state:Todo"))' "$LEDGER_FILE" >/dev/null
test "$(jq -r '.issues["COD-1"].id' "$STATE")" = "iss-1"
test "$(jq -r '.issues["COD-1"].subject' "$STATE")" = "linear-cod-1"
n_before="$(wc -l < "$LEDGER_FILE")"
out="$(run pull)"
printf '%s\n' "$out" | grep -q '0 upserted, 2 unchanged'
test "$(wc -l < "$LEDGER_FILE")" -eq "$n_before"          # re-pull emitted nothing
# state dir is gitignored (dir-local .gitignore + info/exclude)
test "$(cat "$repo/.claude/coord/linear/.gitignore")" = '*'
grep -qxF '/.claude/coord/linear/' "$repo/.git/info/exclude"
test -z "$(git -C "$repo" status --porcelain -- .claude/coord/linear 2>/dev/null)"
# --assignee me narrows to isMe issues; --state widens; a Done issue closes the task
out="$(run pull --assignee me)"
printf '%s\n' "$out" | grep -q '1 issue(s) matched'
out="$(run pull --state 'Todo,In Progress,Done')"
printf '%s\n' "$out" | grep -q '3 issue(s) matched'
printf '%s\n' "$out" | grep -q '1 upserted, 2 unchanged, 1 closed'
jq -e 'select(.type=="done" and .subject=="linear-cod-3")' "$LEDGER_FILE" >/dev/null
test "$(ledger tasks-json linear-cod-3 | jq -r .status)" = done
# no mutation ever crossed the wire during pull
test "$(mutations | wc -l)" -eq 0

# ── 3. push: nothing beyond the task itself → comment created, no transition ─
out="$(run push COD-2)"
printf '%s\n' "$out" | grep -q 'COD-2 .*linear-cod-2 .*open .* comment-created'
test "$(mutations | tr '\n' ' ')" = "commentCreate "
body="$(jq -r '.comments[] | select(.issueId=="iss-2") | .body' "$FAKE_LINEAR_DB")"
printf '%s\n' "$body" | head -n1 | grep -qx '<!-- coordkit:ledger:v1 subject=linear-cod-2 -->'
printf '%s\n' "$body" | grep -q '^## coordkit ledger · COD-2'
printf '%s\n' "$body" | grep -q 'Ledger status:\*\* `open`'
printf '%s\n' "$body" | grep -q 'Codex Workpad'      # explicitly disclaims Symphony's comment
test "$(jq -r '.issues["COD-2"].comment_id' "$STATE")" = "cmt-2"
# idempotent: identical ledger → no second mutation
out="$(run push COD-2)"
printf '%s\n' "$out" | grep -q 'comment unchanged'
test "$(mutations | wc -l)" -eq 1

# ── 4. claim → In Progress transition + worker/branch/host in the comment ────
ledger claim linear-cod-1 >/dev/null
ledger note "COD-1: wired the GraphQL client, tests next" >/dev/null
: > "$FAKE_LINEAR_LOG"
out="$(run push COD-1)"
printf '%s\n' "$out" | grep -q 'in-progress .* state→In Progress comment-created'
test "$(mutations | tr '\n' ' ')" = "issueUpdate commentCreate "
jq -e 'select(.query|test("issueUpdate")) | .variables == {id:"iss-1", stateId:"ws-in-progress"}' "$FAKE_LINEAR_LOG" >/dev/null
test "$(jq -r '.issues[] | select(.id=="iss-1") | .state.name' "$FAKE_LINEAR_DB")" = "In Progress"
body="$(jq -r '.comments[] | select(.issueId=="iss-1" and (.body|startswith("<!-- coordkit"))) | .body' "$FAKE_LINEAR_DB")"
actor="$(jq -r 'select(.type=="claim") | .actor' "$LEDGER_FILE" | tail -n1)"
printf '%s\n' "$body" | grep -q 'Ledger status:\*\* `in-progress`'
printf '%s\n' "$body" | grep -qF "Worker:** \`${actor}\`"
printf '%s\n' "$body" | grep -q "this machine: \`$(hostname)\`"
printf '%s\n' "$body" | grep -q 'Branch:\*\* `feature/cod-1`'
printf '%s\n' "$body" | grep -q 'Last ledger event:\*\* `20[0-9-]*T[0-9:]*Z` · seq [0-9]* · note'
printf '%s\n' "$body" | grep -q '\*\*note\*\* .* wired the GraphQL client'
printf '%s\n' "$body" | grep -q '\*\*claim\*\* .* claimed by'
printf '%s\n' "$body" | grep -q 'Ledger task:\*\* `linear-cod-1` in repo `repo`'
# Symphony's workpad comment is untouched and ours is a separate comment
test "$(jq -r '[.comments[] | select(.issueId=="iss-1")] | length' "$FAKE_LINEAR_DB")" -eq 2
test "$(jq -r '.comments[] | select(.id=="cmt-symphony") | .body' "$FAKE_LINEAR_DB")" = $'## Codex Workpad\n- [ ] something'
# a second push with a claim still live never re-sends the state transition
: > "$FAKE_LINEAR_LOG"
expect 'comment unchanged' run push COD-1
test "$(mutations | wc -l)" -eq 0

# ── 5. block → blocked label (created on the team) + section; then done → Done ─
ledger block linear-cod-1 "waiting on API quota" >/dev/null
: > "$FAKE_LINEAR_LOG"
out="$(run push COD-1)"
printf '%s\n' "$out" | grep -q 'blocked .* +label:blocked comment-updated'
test "$(mutations | tr '\n' ' ')" = "issueLabelCreate issueAddLabel commentUpdate "
jq -e 'select(.query|test("issueLabelCreate")) | .variables == {name:"blocked", teamId:"team-cod"}' "$FAKE_LINEAR_LOG" >/dev/null
jq -e 'select(.query|test("commentUpdate")) | .variables.id == "cmt-3"' "$FAKE_LINEAR_LOG" >/dev/null
body="$(jq -r '.comments[] | select(.id=="cmt-3") | .body' "$FAKE_LINEAR_DB")"
printf '%s\n' "$body" | grep -q '### ⛔ Blocked'
printf '%s\n' "$body" | grep -q '> waiting on API quota'
test "$(jq -r '.issues[] | select(.id=="iss-1") | [.labels.nodes[].name] | join(",")' "$FAKE_LINEAR_DB")" = "blocked"
test "$(jq -r '[.comments[] | select(.issueId=="iss-1")] | length' "$FAKE_LINEAR_DB")" -eq 2   # still ONE coordkit comment
ledger done linear-cod-1 >/dev/null
: > "$FAKE_LINEAR_LOG"
out="$(run push COD-1)"
printf '%s\n' "$out" | grep -q 'done .* state→Done -label:blocked comment-updated'
test "$(mutations | tr '\n' ' ')" = "issueUpdate issueRemoveLabel commentUpdate "
jq -e 'select(.query|test("issueUpdate")) | .variables.stateId == "ws-done"' "$FAKE_LINEAR_LOG" >/dev/null
test "$(jq -r '.issues[] | select(.id=="iss-1") | .state.name' "$FAKE_LINEAR_DB")" = "Done"
test "$(jq -r '.issues[] | select(.id=="iss-1") | .labels.nodes | length' "$FAKE_LINEAR_DB")" -eq 0
body="$(jq -r '.comments[] | select(.id=="cmt-3") | .body' "$FAKE_LINEAR_DB")"
printf '%s\n' "$body" | grep -q '### ✅ Done'
# a Done issue is never demoted back to Done/In Progress by later pushes
: > "$FAKE_LINEAR_LOG"; run push COD-1 >/dev/null; test "$(mutations | wc -l)" -eq 0

# ── 6. custom done_state / claim_state mapping via coord.toml ───────────────
cat >> "$repo/.claude/coord/coord.toml" <<'EOF'
done_state = "In Review"
claim_state = "Started"
blocked_label = ""
EOF
jq -c '.issues += [{"id":"iss-4","identifier":"COD-4","number":4,"title":"Custom map","url":"https://linear.app/x/issue/COD-4","priority":0,"updatedAt":"2026-08-18T00:00:00Z","state":{"id":"ws-todo","name":"Todo","type":"unstarted"},"assignee":null,"team":{"id":"team-cod","key":"COD"},"labels":{"nodes":[]}}]' "$FAKE_LINEAR_DB" > "$FAKE_LINEAR_DB.tmp" && mv "$FAKE_LINEAR_DB.tmp" "$FAKE_LINEAR_DB"
run pull >/dev/null
ledger claim linear-cod-4 >/dev/null
: > "$FAKE_LINEAR_LOG"; expect 'state→Started' run push COD-4
jq -e 'select(.query|test("issueUpdate")) | .variables.stateId == "ws-started"' "$FAKE_LINEAR_LOG" >/dev/null
ledger block linear-cod-4 "no label please" >/dev/null
: > "$FAKE_LINEAR_LOG"; expect 'blocked .* comment-updated' run push COD-4
! mutations | grep -q Label                                  # blocked_label="" → comment only
ledger done linear-cod-4 >/dev/null
: > "$FAKE_LINEAR_LOG"; expect 'state→In Review' run push COD-4
jq -e 'select(.query|test("issueUpdate")) | .variables.stateId == "ws-in-review"' "$FAKE_LINEAR_LOG" >/dev/null

# ── 7. link an arbitrary ledger task, push --all picks it up ────────────────
ledger task "refactor the transports lib" >/dev/null
jq -c '.issues += [{"id":"iss-9","identifier":"COD-9","number":9,"title":"Linked","url":"https://linear.app/x/issue/COD-9","priority":0,"updatedAt":"2026-08-18T00:00:00Z","state":{"id":"ws-todo","name":"Todo","type":"unstarted"},"assignee":null,"team":{"id":"team-cod","key":"COD"},"labels":{"nodes":[]}}]' "$FAKE_LINEAR_DB" > "$FAKE_LINEAR_DB.tmp" && mv "$FAKE_LINEAR_DB.tmp" "$FAKE_LINEAR_DB"
expect "linked ledger task 'refactor-the-transports-lib' ↔ COD-9" run link refactor-the-transports-lib cod-9
test "$(jq -r '.links["refactor-the-transports-lib"]' "$STATE")" = "COD-9"
ledger claim refactor-the-transports-lib >/dev/null
: > "$FAKE_LINEAR_LOG"
out="$(run push --all)"
printf '%s\n' "$out" | grep -q 'COD-9 .*refactor-the-transports-lib in-progress .* state→Started comment-created'
printf '%s\n' "$out" | grep -q 'linear push: 5 ok, 0 failed'
body="$(jq -r '.comments[] | select(.issueId=="iss-9") | .body' "$FAKE_LINEAR_DB")"
printf '%s\n' "$body" | head -n1 | grep -qx '<!-- coordkit:ledger:v1 subject=refactor-the-transports-lib -->'
expect 'COD-9 .*refactor-the-transports-lib' run status
expect 'HTTP stubbed via COORDKIT_LINEAR_CURL' run status

# ── 8. a fresh machine (no state file) finds the existing marker comment ────
rm -rf "$repo/.claude/coord/linear"
: > "$FAKE_LINEAR_LOG"
ledger note "COD-2 progress from another box" >/dev/null
expect 'comment-updated' run push COD-2
test "$(mutations | tr '\n' ' ')" = "commentUpdate "
jq -e 'select(.query|test("commentUpdate")) | .variables.id == "cmt-2"' "$FAKE_LINEAR_LOG" >/dev/null
test "$(jq -r '[.comments[] | select(.issueId=="iss-2")] | length' "$FAKE_LINEAR_DB")" -eq 1

# ── 9. --dry-run prints mutations, sends none, writes nothing ───────────────
run pull >/dev/null
ledger claim linear-cod-2 >/dev/null
: > "$FAKE_LINEAR_LOG"
snap="$(cat "$FAKE_LINEAR_DB")"
out="$(run push COD-2 --dry-run)"
printf '%s\n' "$out" | grep -q 'DRY-RUN mutation'
printf '%s\n' "$out" | grep -q 'commentUpdate(id:\$id, input:{ body:\$body })'
printf '%s\n' "$out" | grep -q '"id":"cmt-2"'
! printf '%s\n' "$out" | grep -q 'issueUpdate'      # COD-2 is already In Progress → no transition
test "$(mutations | wc -l)" -eq 0
test "$(cat "$FAKE_LINEAR_DB")" = "$snap"
out="$(run pull --dry-run --state Done)"
printf '%s\n' "$out" | grep -q 'DRY-RUN ledger: task-as linear-cod-3'

# ── 10. transient failures are retried with backoff; exhaustion is non-fatal in sync ─
printf 2 > "$FAKE_LINEAR_FAIL"
out="$(run pull 2>&1)"
printf '%s\n' "$out" | grep -q 'retrying in 0.00s'
printf '%s\n' "$out" | grep -q 'issue(s) matched'
printf 9 > "$FAKE_LINEAR_FAIL"
rc=0
out="$(run pull 2>&1)" || rc=$?
test "$rc" -ne 0
printf '%s\n' "$out" | grep -q 'unreachable after 3 retries'
printf 0 > "$FAKE_LINEAR_FAIL"
# sync = pull + push --all, once without --loop
out="$(run sync 2>&1)"
printf '%s\n' "$out" | grep -q 'linear pull:'
printf '%s\n' "$out" | grep -q 'linear push:'
# --loop is SIGINT-safe: it stops cleanly instead of dying mid-round
( cd "$repo" && exec env COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PLUGIN_DATA="$tmp/data" COORDKIT_HOST=cli \
    COORDKIT_LINEAR_CURL="$FAKE" COORDKIT_LINEAR_BACKOFF_S=0 "$PLUGIN/bin/cobus" linear sync --loop 30 > "$tmp/loop.out" 2>&1 ) &
loop_pid=$!
for _ in $(seq 1 50); do grep -q 'sleeping 30s' "$tmp/loop.out" 2>/dev/null && break; sleep 0.2; done
grep -q 'sleeping 30s' "$tmp/loop.out"
kill -INT "$loop_pid" 2>/dev/null || true
loop_rc=0; wait "$loop_pid" || loop_rc=$?
test "$loop_rc" -eq 0
grep -q 'linear sync: stopped' "$tmp/loop.out"

# ── 11. package plumbing: dist wrapper + cobus + core delegation ─────────────
test -x "$PLUGIN/scripts/linear.sh"
grep -q 'exec bash "${script_dir}/core/scripts/linear.sh" "$@"' "$PLUGIN/scripts/linear.sh"
grep -q 'linear)   shift; exec bash "${ROOT}/scripts/linear.sh" "$@" ;;' "$PLUGIN/bin/cobus"
expect 'linear pull' "$PLUGIN/bin/cobus" --help
test -f "$PLUGIN/commands/linear.md"
jq -e '.commands.linear.surfaces.cli == "cobus linear"' "$PLUGIN/commands/catalog.json" >/dev/null
cmp -s "$PLUGIN/commands/catalog.json" "$PLUGIN/scripts/core/commands/catalog.json"
grep -q 'linear' "$PLUGIN/commands/README.md"
test -f "$ROOT/docs/LINEAR.md"

echo "linear-bridge: ok"
