#!/usr/bin/env bash
# tests/dispatch.sh — cross-machine task dispatch (`cobus dispatch`) in local
# mode with two simulated machines sharing one coordination log.
#
# Each simulated machine gets its own COORDKIT_DATA (=> its own stable actor id
# and clock) and its own COORDKIT_MACHINE / COORDKIT_CAPS; both point at the same
# COORDKIT_BUS_ROOT so the local logstore acts as the "shared" log.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-dispatch-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/repo" "$tmp/laptop" "$tmp/desktop" "$tmp/other"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
# q <pattern>: like grep -q, but drains stdin so the producer never gets SIGPIPE
# (this file runs with pipefail; an early-exiting grep -q would fail the pipe).
q() { grep -c "$@" >/dev/null; }

# machine <name> <caps> <cobus args...>
machine() {
  local name="$1" caps="$2"; shift 2
  COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_BUS_ROOT="$tmp/repo" COORDKIT_PROJECT_DIR="$tmp/repo" \
    COORDKIT_DATA="$tmp/$name" COORDKIT_MACHINE="$name" COORDKIT_CAPS="$caps" \
    COORDKIT_MODE=local \
    bash "$PLUGIN/bin/cobus" "$@"
}
laptop()  { machine laptop  "os=linux"        "$@"; }
desktop() { machine desktop "gpu=1,os=linux"  "$@"; }
other()   { machine other   "gpu=1,os=linux"  "$@"; }

state_of() { # <machine-fn> <id> -> state
  "$1" dispatch ls --all --json | jq -r --arg id "$2" '.[] | select(.id == $id) | .state'
}
holder_of() {
  "$1" dispatch ls --all --json | jq -r --arg id "$2" '.[] | select(.id == $id) | (.holder.machine // "-")'
}

# 1. whoami reflects env identity
laptop dispatch whoami | q '^machine: laptop$' || fail "whoami machine"
desktop dispatch whoami | q '"gpu":"1"' || fail "whoami caps"

# 2. dispatch creates the ledger task and an open dispatch
id="$(laptop dispatch "run heavy test suite" --needs gpu=1 --lease 3 --quiet)"
[ -n "$id" ] || fail "no dispatch id"
laptop board | q 'run-heavy-test-suite' || fail "ledger task not created"
[ "$(state_of laptop "$id")" = open ] || fail "expected open after dispatch"
laptop dispatch ls | q "$id" || fail "ls does not show dispatch"
laptop dispatch ls | q "gpu=1" || fail "ls does not show selector"

# 3. accept on a machine without the required caps is a no-op (both by id and --auto)
if laptop dispatch accept "$id" >/dev/null 2>&1; then fail "laptop (no gpu) accepted by id"; fi
if laptop dispatch accept --auto >/dev/null 2>&1; then fail "laptop (no gpu) accepted via --auto"; fi
[ "$(state_of laptop "$id")" = open ] || fail "still open after wrong-host accept"

# 4. accept --auto on a matching machine claims it (dispatch + ledger claim)
out="$(desktop dispatch accept --auto)"
printf '%s\n' "$out" | q "accepted ${id}" || fail "desktop accept --auto: $out"
[ "$(state_of desktop "$id")" = accepted ] || fail "expected accepted"
[ "$(holder_of desktop "$id")" = desktop ] || fail "holder should be desktop"
laptop dispatch ls --json | jq -e --arg id "$id" '.[] | select(.id == $id) | .lease_left != null' >/dev/null || fail "lease_left missing"

# 5. a second matching machine loses (already accepted → nothing to accept)
if other dispatch accept "$id" >/dev/null 2>&1; then fail "other accepted an already-accepted dispatch"; fi
if other dispatch accept --auto >/dev/null 2>&1; then fail "other --auto accepted something"; fi
[ "$(holder_of other "$id")" = desktop ] || fail "holder changed after losing accept"

# 5b. explicit race: two accepted events for the same open epoch — lowest (ts,eid) wins on read
id2="$(laptop dispatch "race me" --lease 60 --quiet)"
desktop dispatch accept "$id2" >/dev/null || fail "desktop accept id2"
# forge a competing accept from `other` with the SAME emission clock but a higher eid, appended after
seg="$tmp/repo/.coordkit-bus/log"
ts_acc="$(cat "$seg"/*/seg.ndjson | jq -r --arg id "$id2" 'select(.type=="dispatch.accepted" and .subject==$id) | .dispatch.ts' | head -n1)"
p_acc="$(cat "$seg"/*/seg.ndjson | jq -r --arg id "$id2" 'select(.type=="dispatch.accepted" and .subject==$id) | .clock.p' | head -n1)"
[ -n "$ts_acc" ] && [ -n "$p_acc" ] || fail "no accepted ts for id2"
mkdir -p "$seg/site-forged"
jq -nc --arg id "$id2" --argjson ts "$ts_acc" --argjson p "$p_acc" '{schema_version:"2.0", eid:"zzzz:forged-sorts-after-any-real-eid", id:"forged", actor:"site-forged",
  clock:{p:$p, c:1}, ts:$ts, type:"dispatch.accepted", subject:$id, body:"{}",
  dispatch:{id:$id, task:"race-me", by:{machine:"other", actor:"site-forged"}, lease_until:($ts+60), epoch:1, ts:$ts}, refs:[], tags:["dispatch"], lease:null}' \
  >> "$seg/site-forged/seg.ndjson"
[ "$(holder_of laptop "$id2")" = desktop ] || fail "race: lowest (ts,eid) accept should win, got $(holder_of laptop "$id2")"
# and the reverse: a forged accept with a LOWER eid at the same clock wins
jq -nc --arg id "$id2" --argjson ts "$ts_acc" --argjson p "$p_acc" '{schema_version:"2.0", eid:"0000:forged-sorts-before-any-real-eid", id:"forged2", actor:"site-forged",
  clock:{p:$p, c:2}, ts:$ts, type:"dispatch.accepted", subject:$id, body:"{}",
  dispatch:{id:$id, task:"race-me", by:{machine:"other", actor:"site-forged"}, lease_until:($ts+60), epoch:1, ts:$ts}, refs:[], tags:["dispatch"], lease:null}' \
  >> "$seg/site-forged/seg.ndjson"
[ "$(holder_of laptop "$id2")" = other ] || fail "race: lower eid at same clock should win"
# a stale accept for an OLD epoch (after a release) is ignored even if it sorts first
id2b="$(laptop dispatch "epoch me" --lease 60 --quiet)"
desktop dispatch accept "$id2b" >/dev/null || fail "accept id2b"
desktop dispatch release "$id2b" >/dev/null || fail "release id2b"
jq -nc --arg id "$id2b" --argjson ts "$(date +%s)" '{schema_version:"2.0", eid:"zzzz:stale-epoch", id:"stale", actor:"site-forged",
  clock:{p:($ts*1000+999), c:3}, ts:$ts, type:"dispatch.accepted", subject:$id, body:"{}",
  dispatch:{id:$id, task:"epoch-me", by:{machine:"other", actor:"site-forged"}, lease_until:($ts+60), epoch:1, ts:$ts}, refs:[], tags:["dispatch"], lease:null}' \
  >> "$seg/site-forged/seg.ndjson"
[ "$(state_of laptop "$id2b")" = released ] || fail "stale-epoch accept must be ignored, got $(state_of laptop "$id2b")"
desktop dispatch done "$id2b" >/dev/null || fail "done id2b (anyone may complete)"

# 6. renew extends; reap after the (3s) lease lapses flips it back to open
desktop dispatch renew "$id" --lease 3 | q "renewed ${id}" || fail "renew"
sleep 4
laptop dispatch ls | q "LAPSED" || fail "ls should show LAPSED lease"
laptop dispatch reap | q "$id" || fail "reap did not expire $id"
[ "$(state_of laptop "$id")" = expired ] || fail "expected expired after reap"
laptop dispatch ls --open | q "$id" || fail "expired dispatch should be listed as open/acceptable"

# 7. another matching machine can now accept it, then done completes the ledger task
other dispatch accept --auto | q "accepted ${id}" || fail "other accept after expiry"
[ "$(holder_of other "$id")" = other ] || fail "holder should be other after re-accept"
if desktop dispatch done "$id" >/dev/null 2>&1; then :; fi   # done is allowed from anyone (requester/holder)
[ "$(state_of laptop "$id")" = done ] || fail "expected done"
laptop board | grep 'run-heavy-test-suite' | q 'done' || fail "ledger task not marked done"
laptop dispatch ls | q "$id" && fail "done dispatch should be hidden from default ls"
laptop dispatch ls --all | q "$id" || fail "done dispatch should show in --all"

# 8. release puts it back to released (re-acceptable); release by a non-holder is refused
id3="$(laptop dispatch "release me" --to desktop --lease 60 --quiet)"
if other dispatch accept "$id3" >/dev/null 2>&1; then fail "other accepted a desktop-targeted dispatch"; fi
desktop dispatch accept "$id3" >/dev/null || fail "desktop accept id3"
if other dispatch release "$id3" >/dev/null 2>&1; then fail "non-holder released"; fi
desktop dispatch release "$id3" --reason "changed my mind" | q "released ${id3}" || fail "release"
[ "$(state_of laptop "$id3")" = released ] || fail "expected released"
desktop dispatch accept "$id3" >/dev/null || fail "re-accept after release"

# 9. worker --exec runs a stub with the env vars set, renews, and completes on exit 0
id4="$(laptop dispatch "worker job" --needs gpu=1 --lease 6 --quiet)"
desktop dispatch worker --once --interval 1 --exec 'printf "%s|%s|%s\n" "$COORDKIT_DISPATCH_ID" "$COORDKIT_TASK_ID" "$COORDKIT_TASK_TITLE" > '"$tmp"'/worker.out; sleep 3' >"$tmp/worker.log" 2>&1
[ -f "$tmp/worker.out" ] || { cat "$tmp/worker.log"; fail "worker did not run --exec"; }
q -x "${id4}|worker-job|worker job" "$tmp/worker.out" || fail "worker env vars: $(cat "$tmp/worker.out")"
[ "$(state_of laptop "$id4")" = done ] || { cat "$tmp/worker.log"; fail "worker should mark done on exit 0"; }
laptop dispatch ls --all --json | jq -e --arg id "$id4" '.[] | select(.id == $id) | .holder.machine == "desktop"' >/dev/null || fail "worker holder"
q 'type":"dispatch.renewed"' "$seg"/*/seg.ndjson || fail "worker did not renew while the child ran"

# 10. worker --exec failing → released with the exit code as reason
id5="$(laptop dispatch "failing job" --needs gpu=1 --lease 60 --quiet)"
desktop dispatch worker --once --interval 1 --exec 'exit 7' >"$tmp/worker2.log" 2>&1
[ "$(state_of laptop "$id5")" = released ] || { cat "$tmp/worker2.log"; fail "worker should release on non-zero exit"; }
laptop dispatch ls --all --json | jq -e --arg id "$id5" '.[] | select(.id == $id) | .reason | test("exited 7")' >/dev/null || fail "release reason"

# 11. presence contract: a heartbeat with matching caps is reported as a live matching peer
jq -nc --argjson ts "$(date +%s)" '{schema_version:"2.0", eid:"sha256:hb0000000000000000000000000000001", id:"hb1", actor:"site-hb",
  clock:{p:($ts*1000), c:1}, ts:$ts, type:"heartbeat", subject:"gpubox/site-hb", body:"", machine:"gpubox", caps:{gpu:"1"}, task:null, ttl_s:90,
  refs:[], tags:["presence"], lease:null}' >> "$seg/site-forged/seg.ndjson"
laptop dispatch peers | q 'gpubox/site-hb' || fail "peers should list heartbeat"
laptop dispatch "needs a gpu" --needs gpu=1 | q '1/1 live peer(s) match' || fail "dispatch should report matching live peer"
laptop dispatch "needs a tpu" --needs tpu=1 | q 'none match' || fail "dispatch should warn when no peer matches"

echo "dispatch tests passed"
