# shellcheck shell=bash
# transports/relay.sh — mode=relay (OPTIONAL, and intentionally a DEGRADED STUB).
#
# The relay is a fan-out CACHE, NOT the source of truth. Real-time delivery is a
# nicety layered on top of a durable store; it is never allowed to own data.
#
# Contract (what a full implementation does, and what this stub guarantees today):
#   1. DURABLE FOLD FIRST. Every event is appended to a durable backing adapter
#      (COORDKIT_RELAY_BACKING = local | git, default local) BEFORE anything else.
#      This is the "fold the broadcast locally" rule: even if the relay is down,
#      unreachable, or never configured, the event is already safely persisted.
#   2. BEST-EFFORT FAN-OUT. Then POST the line to relay_url so other live readers
#      see it immediately. This is the only part that is a stub: the POST is a
#      thin curl with no ret/ack/replay protocol yet, and its failure is NON-fatal
#      because durability was already met in step 1.
#   3. GRACEFUL DEGRADATION. If the durable fold itself fails, __relay_append
#      returns non-zero and lib.sh falls back git→local automatically (the re-append
#      is idempotent — dedup is by eid), so nothing is ever lost. relay → git →
#      local is a no-op cutover: the read path is identical in every mode.
#
# READS NEVER COME FROM THE RELAY. readall/tail delegate to the durable backing,
# because the cache is not authoritative.
#
# Implements: __relay_append / __relay_readall / __relay_tail / __relay_lockfile.
# Sourcing defines functions only — no network, no fs, no config reads.
#
# NOT YET IMPLEMENTED beyond the local fold + fallback: subscription/streaming,
# ack/replay, cursor reconciliation against the relay, auth. Tokens/secrets for the
# relay live in the OS keychain or env (e.g. COORDKIT_RELAY_TOKEN), NEVER in coord.toml.

# Durable store the relay folds into and reads from.
__relay_backing() {
  local b="${COORDKIT_RELAY_BACKING:-local}"
  case "$b" in git|local) printf '%s' "$b" ;; *) printf 'local' ;; esac
}

# lib.sh special-cases relay and does not wrap it in __logstore_locked_append, so
# this is provided only for interface symmetry: point at the backing's lock.
__relay_lockfile() {
  case "$(__relay_backing)" in
    git) __git_lockfile ;;
    *)   __local_lockfile ;;
  esac
}

# Resolve relay_url from env, else coord.toml. (room_id likewise, used as a channel.)
__relay_url() {
  if [ -n "${COORDKIT_RELAY_URL:-}" ]; then printf '%s' "$COORDKIT_RELAY_URL"; return 0; fi
  __logstore_toml_get "$(__logstore_coordtoml)" relay_url 2>/dev/null
}
__relay_room() {
  if [ -n "${COORDKIT_ROOM_ID:-}" ]; then printf '%s' "$COORDKIT_ROOM_ID"; return 0; fi
  __logstore_toml_get "$(__logstore_coordtoml)" room_id 2>/dev/null
}

# Best-effort fan-out POST. STUB: fire-and-forget, never fatal, never blocks long.
# Always returns 0 — POST failure must not affect durability (already persisted).
__relay_post() {
  local line="$1" url room
  url="$(__relay_url)"
  [ -n "$url" ] || return 0          # no relay configured → pure local/git behaviour
  command -v curl >/dev/null 2>&1 || return 0
  room="$(__relay_room)"
  curl -fsS --max-time 2 \
    -H 'Content-Type: application/x-ndjson' \
    ${room:+-H "X-Coord-Room: $room"} \
    ${COORDKIT_RELAY_TOKEN:+-H "Authorization: Bearer $COORDKIT_RELAY_TOKEN"} \
    --data-binary "$line"$'\n' \
    "$url" >/dev/null 2>&1 || true   # cache miss is acceptable; never propagate failure
  return 0
}

# Append: durable fold FIRST (authoritative), then best-effort fan-out.
# Returns non-zero ONLY if the durable fold failed, signalling lib.sh to fall back.
__relay_append() {
  local line="$1" backing
  backing="$(__relay_backing)"
  __logstore_locked_append "$backing" "$line" || return 1
  __relay_post "$line"
  return 0
}

# Reads delegate to the durable backing — the relay cache is not source of truth.
__relay_readall() {
  case "$(__relay_backing)" in
    git) __git_readall ;;
    *)   __local_readall ;;
  esac
}

__relay_tail() {
  local n="${1:-0}"
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  case "$(__relay_backing)" in
    git) __git_tail "$n" ;;
    *)   __local_tail "$n" ;;
  esac
}
