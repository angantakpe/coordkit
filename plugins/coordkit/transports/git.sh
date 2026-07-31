# shellcheck shell=bash
# transports/git.sh — mode=git (team async sharing: NO server, NO daemon).
#
# Replicates the coordination event log over a plain git remote. The whole design
# rests on ONE property: each actor only ever appends to its OWN segment files, so
# two clones writing concurrently touch DISJOINT paths and can never produce a
# structural merge conflict. `*.ndjson merge=union` is only a backstop for the
# pathological case where the same actor id is reused from two clones.
#
# CRITICAL INVARIANT: sync NEVER touches the user's checkout, index, or branch.
# Actors append to plain files under <coord>/log/ in the working tree (that path is
# gitignored on the user's branch — see scripts/init-git.sh), and replication happens
# entirely inside a PRIVATE, gitignored worktree at <coord>/.sync checked out to a
# dedicated branch (COORDKIT_SYNC_BRANCH, default "coordkit/log") of the same remote.
# Nothing here ever runs `git add`, commit, rebase or push against the user's branch.
#
# Layout under <coord>/ (coord = COORDKIT_COORD_DIR, else <repo>/.claude/coord):
#   log/<actor>/<epoch>-NNNN.ndjson   actor-partitioned local segments (gitignored)
#   .sync/                            private sync worktree on the log branch (gitignored)
#   .gitattributes                    `*.ndjson merge=union` (committed backstop)
#   .coord.lock                       lock file lib holds for appends — and that
#                                     __git_sync_copy holds around each copy pass
#   .coord.lock.sync                  `flock -n` guard making overlapping sync ticks
#                                     no-ops (a DIFFERENT lock from .coord.lock)
#
# readall = union of every local segment under <coord>/log, deduped (eid) + ordered
# (clock). Remote peers' segments are copied DOWN into <coord>/log by __git_sync, so
# reads never depend on git and stay identical across every mode.
#
# Implements: __git_append / __git_readall / __git_tail / __git_lockfile, plus the
# out-of-band __git_sync. Sourcing defines functions only — no git, no fs, no net.
#
# Env knobs:
#   COORDKIT_COORD_DIR     override the coord dir (default <repo>/.claude/coord)
#   COORDKIT_GIT_SEG_MAX   lines per segment before rotating to a new one (default 1000)
#   COORDKIT_SYNC_BRANCH   dedicated log branch to replicate on (default coordkit/log)
#   COORDKIT_SYNC_REMOTE   remote to sync against (default: coord.toml remote, else the
#                          repo's first configured remote, else "origin")

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
    # Guard the arithmetic: only bump when the newest filename actually matches the
    # <epoch>-NNNN.ndjson pattern. A foreign name (sed -n ...p prints nothing) leaves
    # num empty, so we fall back to n=1 instead of erroring on non-numeric input.
    local num
    num="$(basename "$seg" | sed -nE 's/^[0-9]+-0*([0-9]+)\.ndjson$/\1/p')"
    case "$num" in
      ''|*[!0-9]*) n=1 ;;
      *)           n=$(( num + 1 )) ;;
    esac
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

# Union of every local segment across all actors, deduped + ordered. (Remote peers'
# segments are copied into <coord>/log by __git_sync, so this local read is the full
# union.) `awk 1` (not `cat`) so a segment lacking a trailing newline can't splice
# its last line into the next file's first line.
__git_readall() {
  local base seg
  base="$(__git_basedir)"
  {
    if [ -d "$base/log" ]; then
      find "$base/log" -type f -name '*.ndjson' 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r seg; do awk 1 "$seg" 2>/dev/null; done
    fi
  } | __dedup_by_eid | __total_order
}

__git_tail() {
  local n="${1:-0}"
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  __git_readall | awk -v n="$n" 'NR > n'
}

# --------------------------------------------------------------------------- #
# Sync configuration + the private sync worktree.
# --------------------------------------------------------------------------- #

__git_sync_branch() { printf '%s' "${COORDKIT_SYNC_BRANCH:-coordkit/log}"; }

# Remote to replicate against: explicit env > coord.toml `remote` > the repo's first
# configured remote > "origin". May be a remote NAME or a URL (git fetch/push accept
# either).
__git_sync_remote() {
  local root="$1" r
  if [ -n "${COORDKIT_SYNC_REMOTE:-}" ]; then printf '%s' "$COORDKIT_SYNC_REMOTE"; return 0; fi
  r="$(__logstore_toml_get "$(__logstore_coordtoml)" remote 2>/dev/null)"
  if [ -n "$r" ]; then printf '%s' "$r"; return 0; fi
  r="$(git -C "$root" remote 2>/dev/null | head -n1)"
  printf '%s' "${r:-origin}"
}

# Drop an unparseable TRAILING line from a just-copied segment (defense in depth).
#
# With the append lock held (see __git_sync_copy) a torn line should be impossible,
# but a segment written by an OLDER coordkit, or by a process killed mid-write before
# this lock existed, can still end in a fragment. Committing that fragment would push
# it to the shared log branch, where it is permanently un-parseable for every clone.
# So: if the last line does not parse as JSON, drop it from THIS pass. The writer's
# complete line is still in the source segment and gets picked up on the next sync
# (the size comparison re-triggers, since the trimmed destination stays smaller).
# Only the LAST line is examined — an interior line is followed by a complete append
# and is therefore whole by construction.
__git_sync_trim_partial() {
  local f="$1" last trimmed
  [ -s "$f" ] || return 0
  last="$(tail -n1 "$f" 2>/dev/null)"
  [ -n "$last" ] || return 0
  printf '%s' "$last" | jq -e . >/dev/null 2>&1 && return 0
  printf 'coordkit[git]: dropping unparseable trailing line from %s for this sync pass\n' "$f" >&2
  trimmed="$f.trim"
  if sed '$d' "$f" > "$trimmed" 2>/dev/null; then
    mv -f "$trimmed" "$f" 2>/dev/null || rm -f "$trimmed" 2>/dev/null || true
  else
    rm -f "$trimmed" 2>/dev/null || true
  fi
  return 0
}

# The actual copy loop. NEVER call this directly — go through __git_sync_copy, which
# holds the append lock around it.
#
# Copy per-actor segments from <src> to <dst>, one file at a time, ONLY when the
# destination is missing or the source is strictly larger (segments are single-writer
# append-only, so "larger" == "has strictly more appended data"). Each file is written
# to a temp sibling, trimmed of any unparseable trailing line, and atomically renamed
# so a concurrent reader never sees a partial copy, and a locally-owned segment is
# never shrunk. Never deletes anything.
__git_sync_copy_unlocked() {
  local src="$1" dst="$2" f rel out ssz dsz tmp
  [ -d "$src" ] || return 0
  find "$src" -type f -name '*.ndjson' 2>/dev/null | while IFS= read -r f; do
    rel="${f#"$src"/}"
    out="$dst/$rel"
    if [ -f "$out" ]; then
      ssz="$(wc -c < "$f"   2>/dev/null || echo 0)"
      dsz="$(wc -c < "$out" 2>/dev/null || echo 0)"
      [ "${ssz:-0}" -gt "${dsz:-0}" ] || continue
    fi
    mkdir -p "$(dirname "$out")" 2>/dev/null || continue
    tmp="$out.tmp.$$"
    if cp -f "$f" "$tmp" 2>/dev/null; then
      __git_sync_trim_partial "$tmp"
      mv -f "$tmp" "$out" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
      rm -f "$tmp" 2>/dev/null || true
    fi
  done
  return 0
}

# Copy segments under the SAME lock appends take (<coord>/.coord.lock, the file
# __git_lockfile names and __logstore_locked_append flocks).
#
# WHY: `printf '%s\n' "$line" >> "$seg"` is NOT atomic once the line outgrows the
# stdio buffer — it becomes several write(2) calls. Reading such a segment with a
# plain `cp` while a writer is mid-line yields a TORN line. In the local→sync
# direction that fragment would be committed and pushed to the shared coordkit/log
# branch, corrupting the log for every clone that ever pulls it (a truncated line
# fails `fromjson` and is preserved forever as an opaque "raw:" event by
# __dedup_by_eid). In the sync→local direction the atomic `mv` could equally well
# clobber an append that landed after the source snapshot was taken.
#
# Two DISTINCT locks are still in play and that is deliberate:
#   .coord.lock.sync — held for the WHOLE __git_sync run, `flock -n`, so overlapping
#                      timer ticks become no-ops rather than racing each other.
#   .coord.lock      — held ONLY for the duration of one copy pass, so appends stall
#                      for a file-copy rather than for a network fetch/rebase/push.
# The nesting order is always sync-lock → append-lock and nothing anywhere takes them
# the other way round, so the pair cannot deadlock.
__git_sync_copy() {
  local src="$1" dst="$2" lock rc
  [ -d "$src" ] || return 0
  lock="$(__git_lockfile)"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    # -w 5 mirrors __logstore_locked_append: a wedged holder degrades this pass to a
    # skip (retried on the next tick) instead of hanging the sync forever.
    ( flock -w 5 9 || exit 1; __git_sync_copy_unlocked "$src" "$dst" ) 9>"$lock"
  else
    # No flock(1) (e.g. stock macOS) → same bounded mkdir mutex lib.sh falls back to,
    # on the same lock path, so writer and syncer still serialise against each other.
    __logstore_mkdir_lock "${lock}.d" || return 1
    __git_sync_copy_unlocked "$src" "$dst"; rc=$?
    rmdir "${lock}.d" 2>/dev/null || true
    return "$rc"
  fi
}

# Ensure the private sync worktree exists at <sync> on branch <branch>, tracking the
# same remote, WITHOUT ever touching the user's checkout/index/branch. Recovers a
# previous killed run by aborting any in-progress rebase THERE (safe — private branch).
# True while the sync worktree has an in-progress (or corrupt/partial) rebase.
__git_sync_rebasing() {
  local sync="$1" d
  d="$(git -C "$sync" rev-parse --git-path rebase-merge 2>/dev/null)"; [ -n "$d" ] && [ -d "$d" ] && return 0
  d="$(git -C "$sync" rev-parse --git-path rebase-apply 2>/dev/null)"; [ -n "$d" ] && [ -d "$d" ] && return 0
  return 1
}

__git_sync_worktree() {
  local root="$1" sync="$2" branch="$3" remote="$4" empty_tree empty_commit

  if git -C "$sync" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if __git_sync_rebasing "$sync"; then
      # A previous run was killed mid-rebase; abort it HERE (safe — private branch).
      git -C "$sync" rebase --abort >/dev/null 2>&1 || true
    fi
    # Healthy (no rebase, or it aborted cleanly)? Reuse the worktree.
    __git_sync_rebasing "$sync" || return 0
    # Still wedged (a corrupt/partial rebase that --abort can't clear): tear the
    # private worktree down and recreate it fresh from the remote below.
    git -C "$root" worktree remove --force "$sync" >/dev/null 2>&1 || true
  fi

  # Clear any stale/partial dir at our own path, and prune its dangling admin entry.
  [ -e "$sync" ] && { rm -rf "$sync" 2>/dev/null || return 1; }
  git -C "$root" worktree prune >/dev/null 2>&1 || true
  mkdir -p "$(dirname "$sync")" 2>/dev/null || return 1

  if git -C "$root" fetch --quiet "$remote" "+refs/heads/${branch}:refs/coordkit/sync-fetch" 2>/dev/null; then
    # Remote branch exists → check it out (as local <branch>) in the private worktree.
    git -C "$root" worktree add --quiet -B "$branch" "$sync" refs/coordkit/sync-fetch 2>/dev/null || return 1
  else
    # Remote branch absent → create an ORPHAN branch on an empty root commit, without
    # materialising the user's tree into the worktree.
    empty_tree="$(git -C "$root" hash-object -w -t tree /dev/null 2>/dev/null)" || return 1
    empty_commit="$(git -C "$root" commit-tree -m 'coordkit: coordination log' "$empty_tree" 2>/dev/null </dev/null)" || return 1
    git -C "$root" update-ref "refs/heads/${branch}" "$empty_commit" 2>/dev/null || return 1
    git -C "$root" worktree add --quiet "$sync" "$branch" 2>/dev/null || return 1
  fi
  return 0
}

# --------------------------------------------------------------------------- #
# __git_sync — replicate the coordination log with the remote via the PRIVATE
# worktree. Never mutates the user's checkout, index, or branch.
#
# !!! NEVER call this inline from a Claude hook. !!!
# It does network git (fetch + push) and can be slow or block; running it in a
# PostToolUse/PreToolUse hook would put the network on the critical path of every
# tool call. Drive it from a DEBOUNCED, out-of-hook timer ONLY (see bin/sync.sh —
# cron / systemd timer / a background `loop`). A `flock -n` guard makes overlapping
# ticks no-ops instead of piling up.
#
# Steps (all against the dedicated log branch inside <coord>/.sync):
#   1. copy grown local segments  <coord>/log     → <coord>/.sync/log
#   2. commit them on the private branch (worktree's own index — not the user's)
#   3. fetch + rebase onto the remote log branch  (safe: the branch is private)
#   4. push the private branch (creating it on the first sync)
#   5. copy peers' segments back  <coord>/.sync/log → <coord>/log  (so readall sees them)
#
# Conflict-free by construction (disjoint per-actor files); merge=union backstops the
# same-actor-id-from-two-clones case. Returns non-zero (without throwing) on any git
# failure so the caller can log it.
# --------------------------------------------------------------------------- #
__git_sync() {
  local coord root lock branch remote sync
  coord="$(__git_basedir)"
  root="$(git -C "$coord" rev-parse --show-toplevel 2>/dev/null)" || {
    printf 'coordkit[git]: %s is not inside a git repo; nothing to sync\n' "$coord" >&2
    return 1
  }
  branch="$(__git_sync_branch)"
  remote="$(__git_sync_remote "$root")"
  sync="$coord/.sync"
  lock="$(__git_lockfile).sync"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  (
    flock -n 9 || { printf 'coordkit[git]: a sync is already running; skipping\n' >&2; exit 0; }

    __git_sync_worktree "$root" "$sync" "$branch" "$remote" || {
      printf 'coordkit[git]: could not prepare private sync worktree at %s\n' "$sync" >&2
      exit 1
    }

    # merge=union backstop, active on the private branch where rebases happen; plus a
    # .gitignore so a transient copy temp file (*.tmp.PID) can never be committed.
    [ -f "$sync/.gitattributes" ] || printf '*.ndjson merge=union\n' > "$sync/.gitattributes" 2>/dev/null || true
    [ -f "$sync/.gitignore" ]     || printf '*.tmp.*\n'            > "$sync/.gitignore"     2>/dev/null || true

    # 1) copy grown local segments up into the private worktree (under the APPEND
    #    lock — see __git_sync_copy — so a writer mid-line can't be committed torn).
    #    If the append lock can't be taken, commit nothing this pass and retry on the
    #    next tick rather than publishing a possibly-torn snapshot.
    __git_sync_copy "$coord/log" "$sync/log" || {
      printf 'coordkit[git]: could not take the append lock; skipping this sync tick\n' >&2
      exit 1
    }

    # 2) commit on the private branch — the worktree has its OWN index, so this never
    #    stages anything in the user's index or on the user's branch.
    git -C "$sync" add -A -- . >/dev/null 2>&1 || true
    if ! git -C "$sync" diff --cached --quiet 2>/dev/null; then
      git -C "$sync" commit -q -m "coordkit: sync coordination log" 2>/dev/null || true
    fi

    # 3) fetch the remote log branch (if any) and rebase our commits on top of it.
    if git -C "$sync" fetch --quiet "$remote" "refs/heads/${branch}" 2>/dev/null; then
      if ! git -C "$sync" rebase --quiet FETCH_HEAD 2>/dev/null; then
        git -C "$sync" rebase --abort >/dev/null 2>&1 || true
        printf 'coordkit[git]: rebase onto %s/%s failed (left private branch intact)\n' "$remote" "$branch" >&2
        exit 1
      fi
    fi

    # 4) push the private branch (creates it on the remote on the first sync).
    if ! git -C "$sync" push --quiet "$remote" "HEAD:refs/heads/${branch}" 2>/dev/null; then
      printf 'coordkit[git]: push to %s/%s failed (will retry on next tick)\n' "$remote" "$branch" >&2
      exit 1
    fi

    # 5) copy peers' segments back down so local readall reflects the whole union
    #    (also under the append lock, so the atomic rename can't land on top of a
    #    concurrent local append).
    __git_sync_copy "$sync/log" "$coord/log" || {
      printf 'coordkit[git]: peers copied down partially; retrying on next tick\n' >&2
      exit 1
    }
  ) 9>"$lock"
}
