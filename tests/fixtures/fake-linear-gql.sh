#!/usr/bin/env bash
# fake-linear-gql.sh — offline stand-in for the Linear GraphQL endpoint, used by
# tests/linear-bridge.sh through COORDKIT_LINEAR_CURL. Reads one GraphQL request
# ({query,variables}) on stdin, prints a response body, never touches the network.
#
#   FAKE_LINEAR_DB    JSON file: {issues:[...], comments:[...], labels:[...]}
#                     (mutated in place by mutations)
#   FAKE_LINEAR_LOG   JSONL append log of every request received
#   FAKE_LINEAR_FAIL  file holding a counter; while > 0 each call decrements it
#                     and exits 1 (simulates a transport failure → retry path)
set -uo pipefail
req="$(cat)"
db="${FAKE_LINEAR_DB:?}"
printf '%s\n' "$req" >> "${FAKE_LINEAR_LOG:-/dev/null}"

if [ -n "${FAKE_LINEAR_FAIL:-}" ] && [ -f "$FAKE_LINEAR_FAIL" ]; then
  n="$(cat "$FAKE_LINEAR_FAIL")"
  if [ "${n:-0}" -gt 0 ]; then printf '%s' $(( n - 1 )) > "$FAKE_LINEAR_FAIL"; exit 1; fi
fi

q="$(printf '%s' "$req" | jq -r .query)"
vars="$(printf '%s' "$req" | jq -c '.variables // {}')"
_db_set() { jq -c "$@" "$db" > "${db}.tmp" && mv -f "${db}.tmp" "$db"; }

case "$q" in
  *"issues(first:1, filter:{ team:{ key:{ eq:\$key } }, number:{ eq:\$n } })"*)
    jq -c --argjson v "$vars" '{data:{issues:{nodes:[.issues[] | select(.team.key==$v.key and .number==$v.n)]}}}' "$db" ;;
  *"issues(first:50"*)
    jq -c --argjson v "$vars" '
      ($v.filter // {}) as $f
      | {data:{issues:{
          nodes:[ .issues[]
                  | select(($f.team.key.eq // .team.key) == .team.key)
                  | select(if $f.state.name.in then (.state.name as $s | $f.state.name.in | index($s) != null) else true end)
                  | select(if $f.assignee.isMe.eq then (.assignee.isMe // false) else true end)
                  | select(if $f.labels.name.eq then ([.labels.nodes[].name] | index($f.labels.name.eq) != null) else true end) ],
          pageInfo:{hasNextPage:false, endCursor:null}}}}' "$db" ;;
  *"workflowStates("*)
    jq -nc --argjson v "$vars" '{data:{workflowStates:{nodes:[{id:("ws-" + ($v.name|ascii_downcase|gsub(" ";"-"))), name:$v.name, type:"x"}]}}}' ;;
  *"issueLabels("*)
    jq -c --argjson v "$vars" '{data:{issueLabels:{nodes:[.labels[] | select(.name==$v.name)]}}}' "$db" ;;
  *"issue(id:\$id) { comments"*)
    jq -c --argjson v "$vars" '{data:{issue:{comments:{nodes:[.comments[] | select(.issueId==$v.id) | {id,body}]}}}}' "$db" ;;
  *"issueLabelCreate("*)
    _db_set --argjson v "$vars" '.labels += [{id:("lbl-" + $v.name), name:$v.name, team:{id:$v.teamId}}]'
    jq -nc --argjson v "$vars" '{data:{issueLabelCreate:{success:true, issueLabel:{id:("lbl-" + $v.name)}}}}' ;;
  *"issueAddLabel("*)
    _db_set --argjson v "$vars" '([.labels[] | select(.id==$v.labelId) | .name][0] // "?") as $n | (.issues[] | select(.id==$v.id) | .labels.nodes) += [{id:$v.labelId, name:$n}]'
    printf '{"data":{"issueAddLabel":{"success":true}}}' ;;
  *"issueRemoveLabel("*)
    _db_set --argjson v "$vars" '(.issues[] | select(.id==$v.id) | .labels.nodes) |= map(select(.id != $v.labelId))'
    printf '{"data":{"issueRemoveLabel":{"success":true}}}' ;;
  *"issueUpdate("*)
    _db_set --argjson v "$vars" '(.issues[] | select(.id==$v.id) | .state) = {id:$v.stateId, name:($v.stateId|ltrimstr("ws-")|split("-")|map((.[0:1]|ascii_upcase) + .[1:])|join(" ")), type:(if ($v.stateId|test("done")) then "completed" elif ($v.stateId|test("progress")) then "started" else "unstarted" end)}'
    printf '{"data":{"issueUpdate":{"success":true}}}' ;;
  *"commentCreate("*)
    n="$(jq '.comments|length' "$db")"
    _db_set --argjson v "$vars" --arg id "cmt-$(( n + 1 ))" '.comments += [{id:$id, issueId:$v.issueId, body:$v.body}]'
    jq -nc --arg id "cmt-$(( n + 1 ))" '{data:{commentCreate:{success:true, comment:{id:$id}}}}' ;;
  *"commentUpdate("*)
    _db_set --argjson v "$vars" '(.comments[] | select(.id==$v.id) | .body) = $v.body'
    jq -nc --argjson v "$vars" '{data:{commentUpdate:{success:true, comment:{id:$v.id}}}}' ;;
  *)
    printf '{"errors":[{"message":"fake-linear: unhandled query"}]}' ;;
esac
