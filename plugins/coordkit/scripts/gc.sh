#!/usr/bin/env bash
# gc.sh — garbage-collect a repo's .coordkit-bus/ coordination state.
#
# bus.sh already prunes hard-stale agents and their orphaned claims at
# SessionStart, and auto-trims activity.log at 600 lines. This is the manual,
# heavier-handed pass: it also reaps orphaned cursors and drained inbox dirs,
# trims the log to an arbitrary size, and can remove the bus outright when a
# project is abandoned.
#
# It also migrates the pre-4.0.0 bus directory name: coordkit used to write
# state to <repo>/.claude-bus/ and moved to <repo>/.coordkit-bus/ at 4.0.0 (the
# host/adapter reframe — .claude-bus was Claude-specific, .coordkit-bus isn't).
# The code-level rename doesn't touch state already on disk, so a repo that ran
# pre-4.0.0 coordkit is left with a stale .claude-bus/ next to the new
# .coordkit-bus/. See migrate_legacy_dir() below for exactly what happens.
#
# DRY RUN IS THE DEFAULT — nothing is deleted or moved unless --apply is passed.
#
# Usage: cobus gc [--apply] [--keep N] [--nuke --yes-i-am-sure] [repo]
set -uo pipefail

STALE_HARD=21600   # 6h — same threshold bus.sh uses to call an agent dead
KEEP=350           # activity.log lines retained by a trim
TRIM_AT=600        # trim only once the log exceeds this (matches the auto-trim)

APPLY=0; NUKE=0; SURE=0; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)         APPLY=1 ;;
    --dry-run)       APPLY=0 ;;
    --nuke)          NUKE=1 ;;
    --yes-i-am-sure) SURE=1 ;;
    --keep)          shift; KEEP="${1:-350}" ;;
    -h|--help)
      cat <<'EOF'
cobus gc — garbage-collect this repo's .coordkit-bus/ state

Usage: cobus gc [--apply] [--keep N] [--nuke --yes-i-am-sure] [repo]

  (default)          DRY RUN — report what would be removed, delete nothing
  --apply            actually delete
  --keep N           lines of activity.log to retain when trimming (default 350)
  --nuke             remove the ENTIRE .coordkit-bus/ directory; destructive, and
                     refused unless --yes-i-am-sure is also passed
  repo               repo root (default: $COORDKIT_BUS_ROOT, then host aliases,
                     else the git
                     toplevel, else the current directory)

Reaped: agent heartbeats older than 6h, claims with no live owner, cursors with
no live agent, empty inbox dirs, and an oversized activity.log. Also migrates
a legacy .claude-bus/ (coordkit's pre-4.0.0 state dir name) if one is found —
renamed into .coordkit-bus/ if that's empty/absent, otherwise just reported
for you to reconcile or remove by hand.
EOF
      exit 0 ;;
    -*) echo "gc: unknown option: $1" >&2; exit 2 ;;
    *)  REPO="$1" ;;
  esac
  shift
done

case "$KEEP" in ''|*[!0-9]*) echo "gc: --keep must be a number" >&2; exit 2 ;; esac

# Root resolution comes from the shared library, so gc collects exactly the bus
# bus.sh writes.
# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh"

root="$(resolve_root "${REPO:-$PWD}")"
bus="${root}/.coordkit-bus"
legacy="${root}/.claude-bus"
agents="${bus}/agents"; claims="${bus}/claims"; cursors="${bus}/cursors"
inbox="${bus}/inbox"; log="${bus}/activity.log"

mode="DRY RUN (pass --apply to delete)"; [ "$APPLY" = 1 ] && mode="APPLY"

# ── legacy .claude-bus/ -> .coordkit-bus/ migration (pre-4.0.0 dir name) ────
# Two cases:
#   1. .coordkit-bus/ doesn't exist yet: this session never ran post-4.0.0
#      coordkit here, so .claude-bus/ is the ONLY copy of the state — a plain
#      rename is safe and loses nothing (ledger.jsonl, claims, cursors, all of
#      it move as-is).
#   2. .coordkit-bus/ already exists: both dirs have independently-seeded
#      state (this happens if 4.0.0 coordkit ran here at least once before gc
#      did). Merging two ledger.jsonl logs risks colliding seq numbers, so gc
#      does NOT attempt that — it just reports the legacy dir's contents so
#      you can look at .claude-bus/ledger.jsonl yourself before deciding to
#      remove it (nothing in it survives a `--nuke`-equivalent decision here
#      automatically; that stays a manual call).
if [ -d "$legacy" ]; then
  if [ ! -e "$bus" ]; then
    echo "gc: found legacy bus dir ${legacy}, no ${bus} yet — ${mode}"
    if [ "$APPLY" = 1 ]; then
      mv "$legacy" "$bus" && echo "gc: migrated ${legacy} -> ${bus}" \
        || echo "gc: failed to migrate ${legacy} -> ${bus}" >&2
    else
      echo "gc: would rename ${legacy} -> ${bus}. Add --apply to do it."
    fi
  else
    lines="$(wc -l < "${legacy}/ledger.jsonl" 2>/dev/null || echo 0)"
    case "${lines:-}" in ''|*[!0-9]*) lines=0 ;; esac
    echo "gc: legacy bus dir ${legacy} AND current ${bus} both exist."
    echo "gc: legacy ledger.jsonl has ${lines} line(s) — not auto-merged (seq"
    echo "gc: numbers could collide). Review ${legacy}/ledger.jsonl by hand,"
    echo "gc: then 'rm -rf ${legacy}' yourself once you're sure. gc leaves it."
  fi
fi

if [ ! -d "$bus" ]; then
  echo "gc: no bus at ${bus} — nothing to collect."
  exit 0
fi

now="$(date +%s)"
echo "gc: ${bus}"
echo "gc: mode: ${mode}"

# ── --nuke: whole-bus removal, double-gated ─────────────────────────────────
if [ "$NUKE" = 1 ]; then
  if [ "$SURE" != 1 ]; then
    cat >&2 <<EOF

  ⚠️  --nuke DESTROYS the entire coordination bus at:
        ${bus}
      That discards the shared ledger (ledger.jsonl), the task board, every
      claim, and all activity history for this repo — irreversibly, and for
      every Claude instance using it, including ones live right now.

      Re-run with BOTH flags if that is genuinely what you want:
        cobus gc --nuke --yes-i-am-sure --apply

EOF
    exit 2
  fi
  if [ "$APPLY" != 1 ]; then
    echo "gc: would remove the entire bus directory (${bus}). Add --apply to do it."
    exit 0
  fi
  rm -rf "$bus" && echo "gc: removed ${bus}" || { echo "gc: failed to remove ${bus}" >&2; exit 1; }
  exit 0
fi

# An agent is live if its heartbeat file exists and is within STALE_HARD.
agent_live() {
  local f="${agents}/$1.json" last
  [ -f "$f" ] || return 1
  last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"
  case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -le "$STALE_HARD" ]
}

dead_agents=0 dead_claims=0 dead_cursors=0 empty_inboxes=0

# ── dead agent heartbeats ───────────────────────────────────────────────────
for f in "$agents"/*.json; do
  [ -e "$f" ] || continue
  last="$(jq -r '.last_seen // 0' "$f" 2>/dev/null)"
  case "${last:-}" in ''|*[!0-9]*) last=0 ;; esac
  [ $(( now - last )) -gt "$STALE_HARD" ] || continue
  dead_agents=$(( dead_agents + 1 ))
  [ "$APPLY" = 1 ] && rm -f "$f" 2>/dev/null
done

# ── claims with no live owner (runs after the agent sweep, as prune_dead does)
for f in "$claims"/*.json; do
  [ -e "$f" ] || continue
  owner="$(jq -r '.sid // ""' "$f" 2>/dev/null)"
  { [ -z "$owner" ] || ! agent_live "$owner"; } || continue
  dead_claims=$(( dead_claims + 1 ))
  [ "$APPLY" = 1 ] && rm -f "$f" 2>/dev/null
done

# ── cursors belonging to sessions that are gone ─────────────────────────────
for f in "$cursors"/*.json; do
  [ -e "$f" ] || continue
  csid="$(basename "$f" .json)"
  agent_live "$csid" && continue
  dead_cursors=$(( dead_cursors + 1 ))
  [ "$APPLY" = 1 ] && rm -f "$f" 2>/dev/null
done

# ── inbox dirs left behind by drain_inbox (only if genuinely empty) ─────────
for d in "$inbox"/*/; do
  [ -d "$d" ] || continue
  [ -z "$(ls -A "$d" 2>/dev/null)" ] || continue
  empty_inboxes=$(( empty_inboxes + 1 ))
  [ "$APPLY" = 1 ] && rmdir "$d" 2>/dev/null
done

# ── activity.log ────────────────────────────────────────────────────────────
lines=0; trimmed=0
if [ -f "$log" ]; then
  lines="$(wc -l < "$log" 2>/dev/null || echo 0)"
  case "${lines:-}" in ''|*[!0-9]*) lines=0 ;; esac
  if [ "$lines" -gt "$TRIM_AT" ] && [ "$lines" -gt "$KEEP" ]; then
    trimmed=$(( lines - KEEP ))
    if [ "$APPLY" = 1 ]; then
      tail -n "$KEEP" "$log" > "${log}.gc.tmp" 2>/dev/null \
        && mv "${log}.gc.tmp" "$log" 2>/dev/null \
        || { rm -f "${log}.gc.tmp" 2>/dev/null; trimmed=0; }
    fi
  fi
fi

verb="would remove"; [ "$APPLY" = 1 ] && verb="removed"
tverb="would trim";  [ "$APPLY" = 1 ] && tverb="trimmed"
echo "gc: ${verb} ${dead_agents} dead agent record(s)"
echo "gc: ${verb} ${dead_claims} orphaned claim(s)"
echo "gc: ${verb} ${dead_cursors} orphaned cursor(s)"
echo "gc: ${verb} ${empty_inboxes} empty inbox dir(s)"
if [ "$trimmed" -gt 0 ]; then
  echo "gc: ${tverb} activity.log ${lines} -> ${KEEP} lines (${trimmed} dropped)"
else
  echo "gc: activity.log at ${lines} line(s) — no trim needed"
fi
[ "$APPLY" = 1 ] || echo "gc: nothing was deleted. Re-run with --apply."
exit 0
