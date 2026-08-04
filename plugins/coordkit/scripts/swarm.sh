#!/usr/bin/env bash
# shellcheck shell=bash
# swarm.sh — `cobus swarm <N>`: spawn N worker loops draining ledger.sh's task
# queue (the SAME task/claim/next/done/block engine `/led` and `cobus` already
# drive by hand — see docs/LEDGER.md §2). Nothing in the ledger already RUNS
# work against the queue; a human calls `next` one task at a time. This is
# that, automated, with a hard ceiling and a conservative default.
#
# Each worker: `next --quiet` to auto-claim -> "execute" -> `done`/`block`,
# looping until the queue looks empty (a few consecutive idle polls) or it's
# signaled to stop. See docs/LEDGER.md's "Swarm mode" section for the full
# design rationale, including why the default is DRY RUN and why dry run does
# NOT call `done`.
#
# Usage: swarm.sh <N>
#   N   number of worker loops (1-8; hard ceiling below, not configurable)
#
# Env vars (opt-in real execution; see usage() below for the full contract):
#   COORDKIT_SWARM_EXEC=1     actually run COORDKIT_SWARM_CMD per task
#   COORDKIT_SWARM_CMD        shell command template; "{desc}" is replaced
#                             with the task's description (literal text
#                             substitution, then run via `bash -c`)
set -uo pipefail

# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh"

ROOT_PLUGIN="$(ck_plugin_root)"
LEDGER="${ROOT_PLUGIN}/scripts/ledger.sh"
BUS="${ROOT_PLUGIN}/scripts/bus.sh"

MAX_N=8          # hard safety ceiling — deliberately not configurable, see usage()
IDLE_MAX=5        # consecutive empty polls before a worker gives up and exits
POLL_MIN=2        # seconds
POLL_MAX=5        # seconds

usage() {
  cat <<'EOF'
cobus swarm — spawn N worker loops draining the ledger task queue

Usage: cobus swarm <N>

  N   number of worker loops to spawn. Must be 1-8 — a hard safety ceiling
      against a fat-fingered `cobus swarm 500` forking hundreds of processes.
      Not configurable away in this pass; ask for a bigger swarm loudly if you
      genuinely need one.

Each worker repeatedly calls the ledger's `next` to auto-claim the first open,
deps-satisfied task, "executes" it, then reports the outcome back to the
ledger — until the queue looks drained (a handful of consecutive empty polls)
or it's interrupted (Ctrl-C stops every worker). No hot-looping: an empty poll
sleeps a randomized 2-5s before retrying.

Execution mode (env vars):
  (default)                DRY RUN. Claims a task (so dependency ordering and
                            work-stealing are exercised for real), prints what
                            WOULD run, and leaves it claimed rather than
                            marking it done — see docs/LEDGER.md's "Swarm
                            mode" section for why. The claim self-expires
                            (ledger.sh's lease TTL) if nothing completes it for
                            real.
  COORDKIT_SWARM_EXEC=1    really run COORDKIT_SWARM_CMD for each claimed
                            task, then mark it done (exit 0) or block it
                            (nonzero exit) in the ledger.
  COORDKIT_SWARM_CMD       shell command to run per task; the literal text
                            "{desc}" is replaced with the task's description
                            before the whole string is handed to `bash -c`.
                            Required when COORDKIT_SWARM_EXEC=1. Task
                            descriptions come from the SAME trust boundary as
                            whoever can run `cobus swarm` here (same machine,
                            or an explicitly `cobus trust`-ed repo in git
                            mode) — but a description is still spliced into a
                            shell command line verbatim, so a description
                            containing shell metacharacters WILL be
                            interpreted by the shell. Don't point
                            COORDKIT_SWARM_CMD at anything you wouldn't run
                            with an arbitrary task description as input.

YOU are responsible for whatever permission mode COORDKIT_SWARM_CMD runs
under — swarm never adds a "skip permissions" flag itself, and never will by
default.

Example (opt-in real execution, normal prompted permissions):
  COORDKIT_SWARM_EXEC=1 \
  COORDKIT_SWARM_CMD='claude -p "{desc}"' \
  cobus swarm 3
EOF
}

case "${1:-}" in
  ""|-h|--help|help) usage; exit 0 ;;
esac

n="$1"
case "$n" in
  ''|*[!0-9]*) echo "cobus swarm: N must be a positive integer (got: '${n}')" >&2; exit 2 ;;
esac
if [ "$n" -lt 1 ]; then
  echo "cobus swarm: N must be at least 1" >&2
  exit 2
fi
if [ "$n" -gt "$MAX_N" ]; then
  echo "cobus swarm: refusing N=${n} — hard ceiling is ${MAX_N} worker(s) (not configurable in this pass)." >&2
  exit 2
fi

[ -f "$LEDGER" ] || { echo "cobus swarm: ledger script not found at $LEDGER" >&2; exit 127; }
[ -f "$BUS" ]    || { echo "cobus swarm: bus script not found at $BUS" >&2; exit 127; }

EXEC="${COORDKIT_SWARM_EXEC:-0}"
CMD_TEMPLATE="${COORDKIT_SWARM_CMD:-}"
case "$EXEC" in
  0|1) ;;
  *) echo "cobus swarm: COORDKIT_SWARM_EXEC must be 0 or 1 (got: '${EXEC}')" >&2; exit 2 ;;
esac
if [ "$EXEC" = 1 ] && [ -z "$CMD_TEMPLATE" ]; then
  echo "cobus swarm: COORDKIT_SWARM_EXEC=1 requires COORDKIT_SWARM_CMD to be set (see --help)." >&2
  exit 2
fi

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-swarm.XXXXXX")" || { echo "cobus swarm: mktemp -d failed" >&2; exit 1; }
cleanup() { rm -rf "$WORKDIR" 2>/dev/null; }
trap cleanup EXIT

# One worker loop. Runs as a backgrounded FUNCTION CALL (not a subprocess), so
# it inherits every variable above by ordinary shell scoping — nothing needs
# exporting except the per-worker session id it mints for itself.
worker() {
  local id="$1" idle=0 line subj desc cmd rc
  local donefile="${WORKDIR}/w${id}.done" blockfile="${WORKDIR}/w${id}.blocked" dryfile="${WORKDIR}/w${id}.dry"
  : > "$donefile"; : > "$blockfile"; : > "$dryfile"

  # A distinct, stable identity for this worker's whole run. `next`'s
  # work-stealing check (ledger.sh's owner_live()) requires a live bus
  # heartbeat for the claiming sid, which a bare-shell actor like this one
  # would otherwise never have — see bus.sh's `heartbeat` phase. One call is
  # enough: the bus's liveness window (6h) far outlasts any reasonable swarm
  # run, so there's nothing to refresh on a per-poll basis.
  export COORDKIT_SESSION_ID="swarm${id}-$$"
  bash "$BUS" heartbeat >/dev/null 2>&1

  # Stagger the first poll by worker id (whole seconds only — `sleep 0.N` isn't
  # portable to BSD/macOS sleep(1)). `next` has no coordination beyond the log
  # itself: two callers can both read "open" before either's claim lands and
  # both append one (observed reliably in testing when N workers all cold-start
  # in the same instant against a queue with >=N open tasks). Last claim wins
  # per the ledger's own convergence rule, so it self-corrects — but staggering
  # cold starts avoids paying for it on every single run. Not a hard guarantee;
  # see docs/LEDGER.md's "Swarm mode" section for the residual risk.
  [ "$id" -gt 1 ] && sleep "$(( id - 1 ))"

  while :; do
    if line="$(bash "$LEDGER" next --quiet 2>/dev/null)"; then
      idle=0
      subj="${line%%$'\t'*}"
      desc="${line#*$'\t'}"
      if [ -z "$subj" ]; then
        printf '[worker %d] next --quiet returned an unparseable line, skipping: %s\n' "$id" "$line" >&2
        continue
      fi
      if [ "$EXEC" = 1 ]; then
        cmd="${CMD_TEMPLATE//\{desc\}/$desc}"
        printf '[worker %d] executing %s: %s\n' "$id" "$subj" "$cmd"
        bash -c "$cmd"
        rc=$?
        if [ "$rc" -eq 0 ]; then
          bash "$LEDGER" "done" "$subj" >/dev/null 2>&1
          printf '%s\n' "$subj" >> "$donefile"
          printf '[worker %d] done: %s\n' "$id" "$subj"
        else
          bash "$LEDGER" block "$subj" "swarm worker ${id}: command exited ${rc}" >/dev/null 2>&1
          printf '%s\n' "$subj" >> "$blockfile"
          printf '[worker %d] BLOCKED %s (command exited %d)\n' "$id" "$subj" "$rc"
        fi
      else
        printf '%s\n' "$subj" >> "$dryfile"
        printf '[worker %d] DRY RUN — claimed %s: %s\n' "$id" "$subj" "$desc"
        if [ -n "$CMD_TEMPLATE" ]; then
          printf '[worker %d]   would run: %s\n' "$id" "${CMD_TEMPLATE//\{desc\}/$desc}"
        else
          printf '[worker %d]   (COORDKIT_SWARM_CMD not set — nothing configured to run)\n' "$id"
        fi
        printf '[worker %d]   left claimed, not marked done — self-expires if nothing completes it for real\n' "$id"
      fi
    else
      idle=$(( idle + 1 ))
      if [ "$idle" -ge "$IDLE_MAX" ]; then
        printf '[worker %d] idle %d/%d polls — queue looks drained, exiting\n' "$id" "$idle" "$IDLE_MAX"
        break
      fi
      sleep "$(( (RANDOM % (POLL_MAX - POLL_MIN + 1)) + POLL_MIN ))"
    fi
  done
}

mode_desc="DRY RUN (set COORDKIT_SWARM_EXEC=1 + COORDKIT_SWARM_CMD to really execute)"
[ "$EXEC" = 1 ] && mode_desc="EXEC — COORDKIT_SWARM_CMD='${CMD_TEMPLATE}'"
echo "cobus swarm: spawning ${n} worker(s) — ${mode_desc}"

pids=()
for i in $(seq 1 "$n"); do
  worker "$i" &
  pids+=("$!")
done

stopping=0
on_signal() {
  [ "$stopping" = 1 ] && return
  stopping=1
  echo
  echo "cobus swarm: caught signal — stopping ${#pids[@]} worker(s)..."
  kill "${pids[@]}" 2>/dev/null
}
trap on_signal INT TERM

for pid in "${pids[@]}"; do
  wait "$pid" 2>/dev/null
done
trap - INT TERM

sum_lines() {  # sum of `wc -l` across every file given, tolerating missing/empty ones
  local f n=0 c
  for f in "$@"; do
    [ -f "$f" ] || continue
    c="$(wc -l < "$f" 2>/dev/null)"
    case "$c" in ''|*[!0-9]*) c=0 ;; esac
    n=$(( n + c ))
  done
  printf '%s' "$n"
}

total_done="$(sum_lines "${WORKDIR}"/w*.done)"
total_blocked="$(sum_lines "${WORKDIR}"/w*.blocked)"
total_dry="$(sum_lines "${WORKDIR}"/w*.dry)"

echo "cobus swarm: finished — ${n} worker(s) exited"
if [ "$EXEC" = 1 ]; then
  echo "cobus swarm:   ${total_done} done, ${total_blocked} blocked"
else
  echo "cobus swarm:   ${total_dry} task(s) previewed (dry run — none marked done; see docs/LEDGER.md)"
fi
exit 0
