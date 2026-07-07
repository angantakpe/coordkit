#!/usr/bin/env bash
# sync.sh — debounced, non-blocking git-transport sync for coordkit.
#
# Drives the git transport's __git_sync OUT of the hook path: meant to be run on
# a timer (cron / systemd timer / a `loop`), NEVER inside a Claude hook, so the
# (potentially slow, network-bound) git replication of the coordination log never
# sits in the critical path of a tool call. (Replication touches ONLY the coord log
# via a private worktree — never the user's checkout, and never the local-only
# .claude-bus activity firehose, per the transports README privacy rule.)
#
# Behaviour:
#   - If the git transport lib isn't installed, exit 0 quietly (nothing to sync).
#   - Debounced: skips if a sync ran within COORDKIT_SYNC_DEBOUNCE seconds.
#   - Non-blocking: a flock -n guard means overlapping timer ticks never pile up
#     or wait on each other.
#   - Bounded: __git_sync runs under `timeout` (when available) so a hung git can
#     never wedge the timer.
#   - Observable: diagnostics (a timestamped status line + captured stderr) are
#     appended to <repo>/.claude-bus/sync.log (rotated above ~200KB). Nothing is
#     ever printed to stdout (this may run in a hook-adjacent context) and the
#     script ALWAYS exits 0.
#
# Env knobs:
#   CLAUDE_PLUGIN_ROOT      plugin root (auto-resolved from $0 if unset)
#   CLAUDE_BUS_ROOT         pin the repo whose coordination log to sync
#   COORDKIT_SYNC_DEBOUNCE  min seconds between real syncs   (default 10)
#   COORDKIT_SYNC_TIMEOUT   max seconds a single sync may run (default 30)
set -uo pipefail

# Resolve this script's real path (via readlink -f, with a fallback) so a symlinked
# entrypoint still finds the plugin root relative to the actual file, not the link.
__self="$0"
if command -v readlink >/dev/null 2>&1; then
  __r="$(readlink -f "$0" 2>/dev/null)" && [ -n "$__r" ] && __self="$__r"
fi

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$__self")/.." && pwd)}"
LIB="${ROOT}/transports/lib.sh"

# No git transport installed → nothing to sync; succeed silently.
[ -f "$LIB" ] || exit 0

DEBOUNCE="${COORDKIT_SYNC_DEBOUNCE:-10}"
SYNC_TIMEOUT="${COORDKIT_SYNC_TIMEOUT:-30}"

# Resolve the repo root the SAME way lib.sh's __logstore_repo_root does — including
# the CLAUDE_PROJECT_DIR tier — so our debounce/lock markers guard exactly the repo
# the transport will replicate (a mismatch would let the lock/debounce guard a
# different repo than the one synced).
resolve_root() {
  local cwd="$PWD" top dir
  if [ -n "${CLAUDE_BUS_ROOT:-}" ];    then printf '%s' "$CLAUDE_BUS_ROOT";    return; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return; fi
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
if ! mkdir -p "$state" 2>/dev/null; then
  # Fallback must stay scoped per-user AND per-repo — a bare ${TMPDIR:-/tmp} would make
  # the lock/stamp GLOBAL across every repo and user on the box, so a sync for one repo
  # could debounce/lock out an unrelated one.
  hash="$(printf '%s' "$repo" | cksum 2>/dev/null | awk '{print $1"-"$2}')"
  [ -n "$hash" ] || hash="unknown"
  state="${TMPDIR:-/tmp}/coordkit-$(id -u 2>/dev/null || echo 0)/${hash}"
  mkdir -p "$state" 2>/dev/null || state="${TMPDIR:-/tmp}"
fi
stamp="${state}/.sync.stamp"
lockf="${state}/.sync.lock"
logf="${state}/sync.log"

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

# Rotate the diagnostics log if it has grown past ~200KB (truncate; it is best-effort
# observability, not an archive).
if [ -f "$logf" ]; then
  lsz="$(wc -c < "$logf" 2>/dev/null || echo 0)"
  [ "${lsz:-0}" -gt 204800 ] && : > "$logf" 2>/dev/null
fi
ts="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date 2>/dev/null || echo '?')"

# Bound the sync so a stuck git can never hang the timer. Re-source the lib inside the
# timeout'd shell so __git_sync (and any helpers it relies on) exist. Capture STDERR
# (stdout is discarded — nothing must reach the caller's stdout) so failures are
# recorded instead of vanishing into /dev/null.
if command -v timeout >/dev/null 2>&1; then
  err="$(timeout "${SYNC_TIMEOUT}s" bash -c '. "$1" 2>/dev/null && __git_sync "${@:2}"' coordkit-sync "$LIB" "$@" 2>&1 >/dev/null)"
  rc=$?
else
  err="$(__git_sync "$@" 2>&1 >/dev/null)"
  rc=$?
fi

# Append a timestamped status line (+ any captured stderr) to the diagnostics log.
# Never touch stdout; never fail the script on a logging error.
{
  if [ "$rc" -eq 0 ]; then
    printf '%s sync ok\n' "$ts"
  elif [ "$rc" -eq 124 ]; then
    printf '%s sync TIMED OUT after %ss\n' "$ts" "$SYNC_TIMEOUT"
  else
    printf '%s sync FAILED (rc=%s)\n' "$ts" "$rc"
  fi
  [ -n "$err" ] && printf '%s\n' "$err" | sed 's/^/    /'
} >> "$logf" 2>/dev/null || true

exit 0
