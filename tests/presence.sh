#!/usr/bin/env bash
# tests/presence.sh — machine presence (heartbeat/peers) + realtime watch.
#
#   1. heartbeat emit -> peers shows the machine as alive, with task/caps/branch
#   2. after ttl elapses -> peers shows it as stale
#   3. heartbeats are OUT-OF-BAND for the ledger digest (no seq, never injected)
#   4. watch (local mode) prints an event another actor appended while running,
#      and exits 0 on SIGTERM
#   5. relay mode: heartbeat from machine A is visible to peers on machine B,
#      and a watch on B is woken by the server long-poll (skipped when node or
#      curl are unavailable)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-presence-test.XXXXXX)"
server_pid=""; watch_pid=""
cleanup() {
  [ -n "$watch_pid" ] && kill "$watch_pid" 2>/dev/null || true
  [ -n "$server_pid" ] && kill -TERM "$server_pid" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'status=$?; printf "presence: failed at line %s (exit %s)\n" "$LINENO" "$status" >&2; exit "$status"' ERR

# ── local mode ───────────────────────────────────────────────────────────────
repo="$tmp/repo"; mkdir -p "$repo"; git -C "$repo" init -q
mkdir -p "$repo/.claude/coord"
cat > "$repo/.claude/coord/coord.toml" <<'EOF'
[machine]
caps = "docker,os=linux"
[machine.caps]
region = "ca-east"
EOF
export COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PROJECT_DIR="$repo" COORDKIT_BUS_ROOT="$repo"
export COORDKIT_PLUGIN_DATA="$tmp/data-a" COORDKIT_MACHINE=laptop
export COORDKIT_PRESENCE_DETECT_TASK=0
cobus() { "$PLUGIN/bin/cobus" "$@"; }

# 1. emit + peers alive
line="$(cd "$repo" && COORDKIT_CAPS="ram=32g" cobus heartbeat --json --task COD-844 --cap gpu --cap ram=64g)"
printf '%s\n' "$line" | jq -e '
  .type == "heartbeat" and .schema_version == "2.0" and (.eid | length) > 7
  and .machine == "laptop" and .subject == ("laptop/" + .actor)
  and .host == "cli" and (.actor | startswith("site-"))
  and .task == "COD-844" and .ttl_s == 90 and (.ts | type) == "number"
  and .caps == {docker:true, os:"linux", region:"ca-east", ram:"64g", gpu:true}
  and (has("seq") | not) and .lease == null
  and .presence.machine == "laptop" and .presence.branch == .branch
  and (.presence.repo.root | length) > 0 and (.presence.pid | type) == "number"
' >/dev/null
peers_json="$(cd "$repo" && cobus peers --json)"
printf '%s\n' "$peers_json" | jq -e '
  length == 1 and .[0].machine == "laptop" and .[0].state == "alive"
  and .[0].task == "COD-844" and .[0].caps.gpu == true and .[0].age_s <= 5
' >/dev/null
peers_text="$(cd "$repo" && cobus peers)"
printf '%s\n' "$peers_text" | grep -q 'alive'
printf '%s\n' "$peers_text" | grep -q 'laptop'
printf '%s\n' "$peers_text" | grep -q 'COD-844'

# a second heartbeat is a NEW event (ts in eid), never deduped away
line2="$(cd "$repo" && sleep 1 && cobus heartbeat --json --task COD-844 --cap gpu --cap ram=64g)"
test "$(printf '%s\n' "$line" | jq -r .eid)" != "$(printf '%s\n' "$line2" | jq -r .eid)"
test "$(cd "$repo" && COORDKIT_MODE=local bash -c '. "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"; logstore_readall' | grep -c '"type":"heartbeat"')" -eq 2

# 2. stale after ttl
(cd "$repo" && cobus heartbeat --ttl 1 >/dev/null)
sleep 2
test "$(cd "$repo" && cobus peers --json | jq -r '.[0].state')" = stale
printf '%s\n' "$(cd "$repo" && cobus peers)" | grep -q 'stale'
# machine name precedence: env wins over toml, toml wins over hostname
printf '[machine]\nname = "toml-box"\n' > "$repo/.claude/coord/coord.toml"
test "$(cd "$repo" && COORDKIT_MACHINE= cobus heartbeat --json | jq -r .machine)" = toml-box
test "$(cd "$repo" && cobus heartbeat --json | jq -r .machine)" = laptop

# 3. heartbeats stay out of the ledger digest / board (no numeric seq)
(cd "$repo" && cobus note "digest smoke note" >/dev/null)
digest="$(cd "$repo" && cobus digest)"
printf '%s\n' "$digest" | grep -q 'digest smoke note'
! printf '%s\n' "$digest" | grep -q 'heartbeat'
# same holds when the ledger reads through the logstore union
digest_ls="$(cd "$repo" && COORDKIT_USE_LOGSTORE=1 cobus digest)"
! printf '%s\n' "$digest_ls" | grep -q 'heartbeat'
(cd "$repo" && COORDKIT_USE_LOGSTORE=1 cobus task "watch me" >/dev/null)
board="$(cd "$repo" && COORDKIT_USE_LOGSTORE=1 cobus board)"
printf '%s\n' "$board" | grep -q 'watch-me'
! printf '%s\n' "$board" | grep -q 'heartbeat'

# watch --once backfills by duration and honours --filter / --json
once="$(cd "$repo" && cobus watch --once --since 10m --filter note --json)"
test "$(printf '%s\n' "$once" | grep -c '"type":"note"')" -eq 1
! printf '%s\n' "$once" | grep -q '"type":"heartbeat"'
once_all="$(cd "$repo" && cobus watch --once --since all --no-color 2>/dev/null)"
printf '%s\n' "$once_all" | grep -q 'heartbeat/laptop/'
printf '%s\n' "$once_all" | grep -q 'note/general'

# 4. live watch (local): another actor appends -> line appears; SIGTERM -> exit 0
out="$tmp/watch.out"
(cd "$repo" && COORDKIT_WATCH_INTERVAL=1 exec "$PLUGIN/bin/cobus" watch --json > "$out" 2>"$tmp/watch.err") &
watch_pid=$!
sleep 2
other='{"schema_version":"2.0","eid":"sha256:presence-watch-other","id":"pw1","actor":"site-other","clock":{"p":9999999999999,"c":1},"ts":9999999999,"sid":"desk","sid8":"desk","host":"cli","type":"note","subject":"from-desktop","body":"hello from another machine","refs":[],"tags":[],"lease":null}'
(cd "$repo" && COORDKIT_MODE=local bash -c '. "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"; logstore_append "$1"' _ "$other")
for _ in $(seq 1 30); do
  grep -q 'presence-watch-other' "$out" 2>/dev/null && break
  sleep 0.5
done
grep -q 'presence-watch-other' "$out"
test "$(grep -c 'presence-watch-other' "$out")" -eq 1
kill -TERM "$watch_pid"
rc=0; wait "$watch_pid" || rc=$?
watch_pid=""
test "$rc" -eq 0

# fleet appends the machines summary line (additive)
fleet="$(cd "$repo" && cobus fleet)"
printf '%s\n' "$fleet" | grep -q 'machines (shared log)'

# ── relay mode (optional: needs node + curl) ─────────────────────────────────
if command -v node >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  port="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
  COORDKIT_RELAY_TOKENS='{"test-token":["test-room"]}' COORDKIT_RELAY_DATA="$tmp/server" \
    COORDKIT_RELAY_PORT="$port" node "$PLUGIN/apps/relay/server.mjs" >"$tmp/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && break
    sleep 0.1
  done
  curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null
  relay_env=( COORDKIT_MODE=relay "COORDKIT_RELAY_URL=http://127.0.0.1:${port}/v1/events"
    COORDKIT_RELAY_ALLOW_INSECURE_HTTP=1 COORDKIT_ROOM_ID=test-room COORDKIT_RELAY_TOKEN=test-token )
  A="$tmp/mach-a"; B="$tmp/mach-b"; mkdir -p "$A" "$B"
  # machine B watches (long-poll) BEFORE machine A heartbeats
  bout="$tmp/watch-b.out"
  (cd "$B" && exec env "${relay_env[@]}" COORDKIT_BUS_ROOT="$B" COORDKIT_PROJECT_DIR="$B" COORDKIT_BUS_DIR="$B/.coordkit-bus" \
      COORDKIT_PLUGIN_DATA="$tmp/data-b" COORDKIT_MACHINE=desktop COORDKIT_WATCH_LONGPOLL_MS=5000 \
      "$PLUGIN/bin/cobus" watch --json --filter heartbeat > "$bout" 2>"$tmp/watch-b.err") &
  watch_pid=$!
  sleep 2
  hb="$(cd "$A" && env "${relay_env[@]}" COORDKIT_BUS_ROOT="$A" COORDKIT_PROJECT_DIR="$A" COORDKIT_BUS_DIR="$A/.coordkit-bus" \
      COORDKIT_PLUGIN_DATA="$tmp/data-a2" COORDKIT_MACHINE=cloudbox "$PLUGIN/bin/cobus" heartbeat --json --cap arch=arm64)"
  eid="$(printf '%s\n' "$hb" | jq -r .eid)"
  for _ in $(seq 1 40); do
    grep -q "$eid" "$bout" 2>/dev/null && break
    sleep 0.5
  done
  grep -q "$eid" "$bout" || { echo "--- watch-b.err"; cat "$tmp/watch-b.err"; echo "--- bout"; cat "$bout"; echo "--- server"; cat "$tmp/server.log"; echo "--- hb"; echo "$hb"; false; }
  kill -TERM "$watch_pid"; wait "$watch_pid" || true; watch_pid=""
  # peers on B sees cloudbox alive via relay replay
  peers_b="$(cd "$B" && env "${relay_env[@]}" COORDKIT_BUS_ROOT="$B" COORDKIT_PROJECT_DIR="$B" COORDKIT_BUS_DIR="$B/.coordkit-bus" \
      COORDKIT_PLUGIN_DATA="$tmp/data-b" COORDKIT_MACHINE=desktop "$PLUGIN/bin/cobus" peers --json)"
  printf '%s\n' "$peers_b" | jq -e 'map(select(.machine == "cloudbox" and .state == "alive" and .caps.arch == "arm64")) | length == 1' >/dev/null
  # __relay_wait_for_events: returns 1 (timeout) when nothing new, 0 after a post
  (cd "$B" && env "${relay_env[@]}" COORDKIT_BUS_DIR="$B/.coordkit-bus" bash -c '
    . "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"; __relay_sync
    if __relay_wait_for_events 500; then exit 1; fi
    curl -fsS -H "Authorization: Bearer test-token" -H "X-Coord-Room: test-room" -H "Content-Type: application/x-ndjson" \
      --data-binary "{\"eid\":\"sha256:presence-wake\",\"actor\":\"site-x\",\"clock\":{\"p\":1,\"c\":1},\"type\":\"note\",\"subject\":\"w\"}" \
      "$COORDKIT_RELAY_URL" >/dev/null
    __relay_wait_for_events 500')
  echo "presence: relay ok"
else
  echo "presence: relay case skipped (node/curl missing)"
fi

echo "presence: ok"
