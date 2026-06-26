#!/usr/bin/env bash
# sync.sh — debounced, non-blocking git-transport sync for coordkit.
#
# Drives the git transport's __git_sync OUT of the hook path: meant to be run on
# a timer (cron / systemd timer / a `loop`), NEVER inside a Claude hook, so the
# (potentially slow, network-bound) git replication of .claude-bus never sits in
# the critical path of a tool call.
#
# Behaviour:
#   - If the git transport lib isn't installed, exit 0 quietly (nothing to sync).
#   - Debounced: skips if a sync ran within COORDKIT_SYNC_DEBOUNCE seconds.
#   - Non-blocking: a flock -n guard means overlapping timer ticks never pile up
#     or wait on each other.
#   - Bounded: __git_sync runs under `timeout` (when available) so a hung git can
#     never wedge the timer.
#
# Env knobs:
#   CLAUDE_PLUGIN_ROOT      plugin root (auto-resolved from $0 if unset)
#   CLAUDE_BUS_ROOT         pin the repo whose .claude-bus to sync
#   COORDKIT_SYNC_DEBOUNCE  min seconds between real syncs   (default 10)
#   COORDKIT_SYNC_TIMEOUT   max seconds a single sync may run (default 30)
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
LIB="${ROOT}/transports/lib.sh"

# No git transport installed → nothing to sync; succeed silently.
[ -f "$LIB" ] || exit 0

DEBOUNCE="${COORDKIT_SYNC_DEBOUNCE:-10}"
SYNC_TIMEOUT="${COORDKIT_SYNC_TIMEOUT:-30}"

# Resolve the repo root the same way the transports do, so our debounce/lock
# markers land alongside the .claude-bus the transport will replicate.
resolve_root() {
  local cwd="$PWD" top dir
  if [ -n "${CLAUDE_BUS_ROOT:-}" ]; then printf '%s' "$CLAUDE_BUS_ROOT"; return; fi
  top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then printf '%s' "$top"; return; fi
  dir="$cwd"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -d "$dir/.claude-bus" ] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done
  printf '%s' "$cwd"
}

repo="$(resolve_root)"
state="${repo}/.claude-bus"
mkdir -p "$state" 2>/dev/null || state="${TMPDIR:-/tmp}"
stamp="${state}/.sync.stamp"
lockf="${state}/.sync.lock"

# Debounce: bail if we synced recently.
if [ -f "$stamp" ]; then
  last="$(stat -c %Y "$stamp" 2>/dev/null || stat -f %m "$stamp" 2>/dev/null || echo 0)"
  [ -z "$last" ] && last=0
  [ $(( $(date +%s) - last )) -lt "$DEBOUNCE" ] && exit 0
fi

# Non-blocking lock so two timer ticks never stack up. If another sync holds it,
# just leave — we are debounced anyway.
exec 9>"$lockf" 2>/dev/null || exit 0
flock -n 9 2>/dev/null || exit 0

# Refresh the debounce stamp up-front so concurrent ticks back off immediately,
# even if the sync below takes a while.
: > "$stamp" 2>/dev/null

# Verify the transport actually exposes __git_sync before doing anything.
# shellcheck source=/dev/null
. "$LIB" 2>/dev/null || exit 0
type __git_sync >/dev/null 2>&1 || exit 0

# Bound the sync so a stuck git can never hang the timer. Re-source the lib
# inside the timeout'd shell so __git_sync (and any helpers it relies on) exist.
if command -v timeout >/dev/null 2>&1; then
  timeout "${SYNC_TIMEOUT}s" bash -c '. "$1" 2>/dev/null && __git_sync "${@:2}"' coordkit-sync "$LIB" "$@" 2>/dev/null || exit 0
else
  __git_sync "$@" 2>/dev/null || exit 0
fi

exit 0
