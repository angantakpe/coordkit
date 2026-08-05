#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-relay-test.XXXXXX)"
port="$(python3 - <<'PY'
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()
PY
)"
server_pid=""
server_data="$tmp/server"

stop_server() {
  if [ -n "$server_pid" ] && kill -0 "$server_pid" 2>/dev/null; then
    kill -TERM "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  server_pid=""
}
cleanup() { stop_server; rm -rf "$tmp"; }
trap cleanup EXIT

start_server() {
  COORDKIT_RELAY_TOKENS='{"test-token":["test-room"]}' COORDKIT_RELAY_DATA="$server_data" \
    COORDKIT_RELAY_PORT="$port" node "$ROOT/apps/relay/server.mjs" >"$tmp/server.log" 2>&1 &
  server_pid=$!
  for _ in $(seq 1 50); do
    curl -fsS "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  cat "$tmp/server.log" >&2
  return 1
}

client() { # <bus-dir> <shell-body> [arg]
  local bus="$1" body="$2" arg="${3:-}"
  mkdir -p "$bus"
  COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_MODE=relay \
    COORDKIT_RELAY_URL="http://127.0.0.1:${port}/v1/events" \
    COORDKIT_RELAY_ALLOW_INSECURE_HTTP=1 \
    COORDKIT_ROOM_ID=test-room COORDKIT_RELAY_TOKEN=test-token \
    COORDKIT_BUS_DIR="$bus" bash -c ". \"\$COORDKIT_PLUGIN_ROOT/transports/lib.sh\"; $body" _ "$arg"
}

# Bearer credentials must never be sent to arbitrary plaintext HTTP. Loopback
# HTTP is available only through an explicit development opt-in.
COORDKIT_PLUGIN_ROOT="$PLUGIN" bash -c '
  . "$COORDKIT_PLUGIN_ROOT/transports/lib.sh"
  ! __relay_url_allowed http://relay.example/v1/events
  COORDKIT_RELAY_ALLOW_INSECURE_HTTP=1
  ! __relay_url_allowed http://relay.example/v1/events
  __relay_url_allowed http://127.0.0.1:8787/v1/events
  __relay_url_allowed https://relay.example/v1/events
'

start_server
event_one='{"schema_version":"2.0","eid":"sha256:relay-one","id":"relay-one","actor":"site-a","clock":{"p":1,"c":1},"type":"note","subject":"one","body":"from-a"}'
client "$tmp/a" 'logstore_append "$1"' "$event_one"
client "$tmp/a" 'logstore_append "$1"' "$event_one"
received="$(client "$tmp/b" 'logstore_readall')"
test "$(printf '%s\n' "$received" | grep -c 'sha256:relay-one')" -eq 1

conflict='{"schema_version":"2.0","eid":"sha256:relay-one","id":"relay-one","actor":"site-a","clock":{"p":1,"c":1},"type":"note","subject":"one","body":"conflicting-content"}'
if curl -fsS -H 'Authorization: Bearer test-token' -H 'X-Coord-Room: test-room' \
  -H 'Content-Type: application/x-ndjson' --data-binary "$conflict" \
  "http://127.0.0.1:${port}/v1/events" >/dev/null 2>&1; then
  echo "relay accepted conflicting content for an existing eid" >&2
  exit 1
fi

if curl -fsS -H 'Authorization: Bearer wrong' -H 'X-Coord-Room: test-room' \
  "http://127.0.0.1:${port}/v1/events?since=0" >/dev/null 2>&1; then
  echo "relay accepted an invalid token" >&2
  exit 1
fi
if curl -fsS -H 'Authorization: Bearer test-token' -H 'X-Coord-Room: other-room' \
  "http://127.0.0.1:${port}/v1/events?since=0" >/dev/null 2>&1; then
  echo "relay accepted a token outside its room grant" >&2
  exit 1
fi

stop_server
event_two='{"schema_version":"2.0","eid":"sha256:relay-offline","id":"relay-offline","actor":"site-a","clock":{"p":2,"c":1},"type":"note","subject":"offline","body":"queued"}'
client "$tmp/a" 'logstore_append "$1"' "$event_two"
test "$(client "$tmp/a" '__relay_status' | awk '/pending_outbox:/ {print $2}')" -eq 1

start_server
client "$tmp/a" '__relay_sync' >/dev/null
test "$(client "$tmp/a" '__relay_status' | awk '/pending_outbox:/ {print $2}')" -eq 0
replayed="$(client "$tmp/c" 'logstore_readall')"
printf '%s\n' "$replayed" | grep -q 'sha256:relay-one'
printf '%s\n' "$replayed" | grep -q 'sha256:relay-offline'
test "$(client "$tmp/c" '__relay_status' | awk '/cursor:/ {print $2}')" -eq 2

# Two requests arriving together during the first persisted-room load must
# share one initialization promise. Otherwise each can allocate cursor 2 and
# one in-memory state silently wins over the other.
stop_server
start_server
race_one='{"schema_version":"2.0","eid":"sha256:relay-race-one","id":"relay-race-one","actor":"site-r1","clock":{"p":4,"c":1},"type":"note","subject":"race-one","body":"parallel-a"}'
race_two='{"schema_version":"2.0","eid":"sha256:relay-race-two","id":"relay-race-two","actor":"site-r2","clock":{"p":4,"c":2},"type":"note","subject":"race-two","body":"parallel-b"}'
curl -fsS -H 'Authorization: Bearer test-token' -H 'X-Coord-Room: test-room' \
  -H 'Content-Type: application/x-ndjson' --data-binary "$race_one" \
  "http://127.0.0.1:${port}/v1/events" >"$tmp/race-one.ack" &
race_pid_one=$!
curl -fsS -H 'Authorization: Bearer test-token' -H 'X-Coord-Room: test-room' \
  -H 'Content-Type: application/x-ndjson' --data-binary "$race_two" \
  "http://127.0.0.1:${port}/v1/events" >"$tmp/race-two.ack" &
race_pid_two=$!
wait "$race_pid_one"
wait "$race_pid_two"
test "$(jq -s '[.[].cursor] | unique | length' "$tmp/race-one.ack" "$tmp/race-two.ack")" -eq 2
race_replay="$(curl -fsS -H 'Authorization: Bearer test-token' -H 'X-Coord-Room: test-room' \
  "http://127.0.0.1:${port}/v1/events?since=0")"
printf '%s\n' "$race_replay" | grep -q 'sha256:relay-race-one'
printf '%s\n' "$race_replay" | grep -q 'sha256:relay-race-two'

# A restored/replaced server may restart its cursor below a client's saved
# value. The client must rewind and replay instead of missing all new events.
stop_server
server_data="$tmp/server-replacement"
start_server
event_three='{"schema_version":"2.0","eid":"sha256:relay-after-restore","id":"relay-after-restore","actor":"site-d","clock":{"p":3,"c":1},"type":"note","subject":"restore","body":"new-server"}'
client "$tmp/d" 'logstore_append "$1"' "$event_three"
restored="$(client "$tmp/c" 'logstore_readall')"
printf '%s\n' "$restored" | grep -q 'sha256:relay-after-restore'
test "$(client "$tmp/c" '__relay_status' | awk '/cursor:/ {print $2}')" -eq 1

echo "relay e2e: ok"
