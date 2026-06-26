# shellcheck shell=bash
# transports/git.sh — mode=git (team async sharing: NO server, NO daemon).
#
# Replicates the coordination event log over a plain git remote. The whole design
# rests on ONE property: each actor only ever appends to its OWN segment files, so
# two clones writing concurrently touch DISJOINT paths and can never produce a
# structural merge conflict. `*.ndjson merge=union` (installed from
# templates/gitattributes as .claude/coord/.gitattributes) is only a backstop for
# the pathological case where the same actor id is reused from two clones.
#
# Layout under <coord>/ (coord = COORDKIT_COORD_DIR, else <repo>/.claude/coord):
#   log/<actor>/<epoch>-NNNN.ndjson   actor-partitioned, rotated committed segments
#   .gitattributes                    `*.ndjson merge=union` (installed from template)
#   .coord.lock                       flock file lib holds for appends
#
# readall = union of every committed segment, deduped (eid) + ordered (clock).
#
# Implements: __git_append / __git_readall / __git_tail / __git_lockfile, plus the
# out-of-band __git_sync. Sourcing defines functions only — no git, no fs, no net.
#
# Env knobs:
#   COORDKIT_COORD_DIR     override the coord dir (default <repo>/.claude/coord)
#   COORDKIT_GIT_SEG_MAX   lines per segment before rotating to a new one (default 1000)

__git_basedir() {
  printf '%s' "${COORDKIT_COORD_DIR:-$(__logstore_repo_root)/.claude/coord}"
}

__git_lockfile() {
  printf '%s' "$(__git_basedir)/.coord.lock"
}

# Pick the segment this actor should append to: the newest existing segment if it
# still has room, otherwise a fresh <epoch>-NNNN.ndjson (NNNN = prior + 1). Only
# THIS actor writes under its own dir, so this is contention-free across actors.
__git_current_segment() {
  local actor="$1" dir seg max epoch n
  dir="$(__git_basedir)/log/$actor"
  mkdir -p "$dir" 2>/dev/null || return 1
  max="${COORDKIT_GIT_SEG_MAX:-1000}"
  seg="$(find "$dir" -maxdepth 1 -type f -name '*.ndjson' 2>/dev/null | LC_ALL=C sort | tail -n1)"
  if [ -n "$seg" ] && [ "$(wc -l < "$seg" 2>/dev/null || echo 0)" -lt "$max" ]; then
    printf '%s' "$seg"
    return 0
  fi
  epoch="$(date +%s)"
  n=1
  if [ -n "$seg" ]; then
    n=$(( $(basename "$seg" | sed -E 's/^[0-9]+-0*([0-9]+)\.ndjson$/\1/') + 1 ))
  fi
  printf '%s/%s-%04d.ndjson' "$dir" "$epoch" "$n"
}

# Append one line to this actor's current segment. No locking — lib holds the flock.
__git_append() {
  local line="$1" actor seg
  actor="$(__logstore_actor_of "$line")"
  seg="$(__git_current_segment "$actor")" || return 1
  mkdir -p "$(dirname "$seg")" 2>/dev/null || return 1
  printf '%s\n' "$line" >> "$seg"
}

# Union of every committed segment across all actors, deduped + ordered.
__git_readall() {
  local base seg
  base="$(__git_basedir)"
  {
    if [ -d "$base/log" ]; then
      find "$base/log" -type f -name '*.ndjson' 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r seg; do cat -- "$seg"; done
    fi
  } | __dedup_by_eid | __total_order
}

__git_tail() {
  local n="${1:-0}"
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  __git_readall | awk -v n="$n" 'NR > n'
}

# --------------------------------------------------------------------------- #
# __git_sync — replicate the committed log with the remote.
#
# !!! NEVER call this inline from a Claude hook. !!!
# It does network git (pull --rebase + push) and can be slow or block; running it
# in a PostToolUse/PreToolUse hook would put the network on the critical path of
# every tool call. It is meant to be driven by a DEBOUNCED, out-of-hook timer ONLY
# (see bin/sync.sh — cron / systemd timer / a background `loop`). A `flock -n`
# guard makes overlapping ticks no-ops instead of piling up.
#
# Steps: stage+commit pending segments → pull --rebase --autostash → push.
# Conflict-free by construction (disjoint per-actor files); merge=union backstops.
# Returns non-zero (without throwing) on any git failure so the caller can log it.
# --------------------------------------------------------------------------- #
__git_sync() {
  local coord root lock
  coord="$(__git_basedir)"
  root="$(git -C "$coord" rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'coordkit[git]: %s is not inside a git repo; nothing to sync\n' "$coord" >&2
    return 1
  }
  lock="$(__git_lockfile).sync"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  (
    flock -n 9 || { printf 'coordkit[git]: a sync is already running; skipping\n' >&2; exit 0; }

    git -C "$root" add -- "$coord/log" >/dev/null 2>&1 || true
    if ! git -C "$root" diff --cached --quiet -- "$coord/log" 2>/dev/null; then
      git -C "$root" commit -q -m "coordkit: sync coordination log" -- "$coord/log" 2>/dev/null || true
    fi

    if ! git -C "$root" pull --rebase --autostash -q 2>/dev/null; then
      printf 'coordkit[git]: pull --rebase failed (left local commits intact)\n' >&2
      exit 1
    fi
    if ! git -C "$root" push -q 2>/dev/null; then
      printf 'coordkit[git]: push failed (will retry on next tick)\n' >&2
      exit 1
    fi
  ) 9>"$lock"
}
