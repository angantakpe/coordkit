#!/usr/bin/env bash
# concurrency-guard.sh — prevent clobbering files a sibling Claude instance touched.
#
# The user routinely runs several Claude Code instances in the same repo at once.
# This hook tracks a fingerprint (mtime + size) of each file THIS session has Read
# or written, and blocks a Write/Edit when the file on disk has changed since we
# last saw it (or we never saw it) — the signature of another instance having
# edited it.
#
# Usage (wired from hooks/hooks.json):
#   PreToolUse  Write|Edit  -> concurrency-guard.sh check
#   PostToolUse Read         -> concurrency-guard.sh record
#   PostToolUse Write|Edit   -> concurrency-guard.sh record
#   PreToolUse  Bash         -> concurrency-guard.sh snapshot
#   PostToolUse Bash         -> concurrency-guard.sh absorb
#   SessionEnd               -> concurrency-guard.sh cleanup
#
# BASH BRACKETING — a hook can't know which files an arbitrary shell command
# touched (sed -i, formatters, git checkout, …), so files this session modified
# via the Bash tool used to go stale and trip a false-positive deny on the next
# Write/Edit. Every Bash call is therefore bracketed: `snapshot` (PreToolUse)
# lists the tracked files that still match their record at that instant, and
# `absorb` (PostToolUse) re-stamps any of THOSE that changed while the command
# ran — a change inside this session's own Bash window is attributed to it. A
# file that was ALREADY stale before the Bash call (a sibling edited it earlier)
# is deliberately NOT absorbed and still denies. Remaining edges, all of which
# fail toward a deny + re-Read (safe over silent):
#   - a sibling writing DURING our Bash window is mis-attributed to us — a
#     narrow race, the same exposure a fingerprint taken at Read time always had;
#   - files this session never Read/wrote — including files our own Bash
#     *created* — are untracked, so the "never saw it" deny applies; Read the
#     file once to adopt it.
#
# Record file format (one per tracked file, named by hashkey of the path):
#   line 1: fingerprint (mtime:size) this session last saw
#   line 2: the file's absolute path (lets snapshot/absorb re-stat it)
# Records written by coordguard <=1.1.0 hold only line 1 (possibly a bare
# epoch); `check` tolerates them, `snapshot`/`absorb` just skip them.
#
# Reads the hook JSON on stdin. Never hard-fails the tool pipeline: on any internal
# error it exits 0 (allow) so a bug here can't wedge the session. The deny path is
# a deliberate JSON permissionDecision, never an error exit.
set -uo pipefail

phase="${1:-check}"
input="$(cat)"

sid="$(printf '%s' "$input" | jq -r '.session_id // "nosession"' 2>/dev/null)"
[ -z "$sid" ] && sid="nosession"

base="${TMPDIR:-/tmp}/claude-concurrency"
statedir="${base}/${sid}"

# Composite fingerprint: high-resolution mtime + size, joined by ':'. The size
# catches a sibling write that lands in the same wall-clock second as our Read
# (whole-second mtime alone would miss it). Prefer GNU nanosecond mtime, fall back
# to whole-second (GNU then BSD); prefer GNU size, fall back to BSD size.
fingerprint() {
  local f="$1" mt="" sz=""
  mt="$(stat -c %.Y "$f" 2>/dev/null)"          # GNU, nanosecond
  [ -z "$mt" ] && mt="$(stat -c %Y "$f" 2>/dev/null)"   # GNU, whole second
  [ -z "$mt" ] && mt="$(stat -f %m "$f" 2>/dev/null)"   # BSD, whole second
  sz="$(stat -c %s "$f" 2>/dev/null)"           # GNU size
  [ -z "$sz" ] && sz="$(stat -f %z "$f" 2>/dev/null)"   # BSD size
  printf '%s:%s' "$mt" "$sz"
}

# ---- cleanup: SessionEnd, no file_path — handle before the file guard ----------
if [ "$phase" = "cleanup" ]; then
  # Remove ONLY this session's statedir. Refuse anything that isn't a single,
  # non-empty path component so a hostile session_id (e.g. "../..") can't make us
  # rm outside the claude-concurrency tree.
  case "$sid" in
    ""|.|..|*/*|*$'\n'*) exit 0 ;;
  esac
  target="${base}/${sid}"
  # Belt-and-braces: the resolved path must be exactly base/<sid>, under base.
  [ "$target" = "${base}/${sid}" ] || exit 0
  case "$target" in
    "${base}/"?*) ;;
    *) exit 0 ;;
  esac
  [ -d "$target" ] && rm -rf "$target" 2>/dev/null
  exit 0
fi

# ---- snapshot / absorb: Bash bracketing, no file_path ---------------------------
if [ "$phase" = "snapshot" ] || [ "$phase" = "absorb" ]; then
  [ -d "$statedir" ] || exit 0
  # Pair the two halves of one Bash call by tool_use_id where the host provides
  # it; otherwise share one slot (parallel Bash calls then degrade to the old
  # deny-and-re-Read behavior at worst, never to a wrong allow of sibling edits).
  snapid="$(printf '%s' "$input" | jq -r '.tool_use_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9' '_' | cut -c1-64)"
  snapid="${snapid%_}"
  [ -n "$snapid" ] || snapid="shared"
  snap="${statedir}/.bashsnap.${snapid}"     # dotfile: the record glob below skips it

  if [ "$phase" = "snapshot" ]; then
    tmp="${snap}.tmp.$$"
    : > "$tmp" 2>/dev/null || exit 0
    for rec in "$statedir"/*; do
      [ -f "$rec" ] || continue
      path="$(sed -n '2p' "$rec" 2>/dev/null)"
      [ -n "$path" ] && [ -f "$path" ] || continue   # old-format or vanished — skip
      seen="$(head -n1 "$rec" 2>/dev/null)"
      cur="$(fingerprint "$path")"
      [ -n "$cur" ] && [ "$cur" = "$seen" ] && printf '%s\n' "${rec##*/}" >> "$tmp"
    done
    mv -f "$tmp" "$snap" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    exit 0
  fi

  # absorb — only files that were clean at snapshot time are eligible.
  [ -f "$snap" ] || exit 0
  while IFS= read -r k; do
    case "$k" in ""|.*|*/*) continue ;; esac         # our own keys are plain hashes
    rec="${statedir}/${k}"
    [ -f "$rec" ] || continue
    path="$(sed -n '2p' "$rec" 2>/dev/null)"
    [ -n "$path" ] && [ -f "$path" ] || continue
    seen="$(head -n1 "$rec" 2>/dev/null)"
    cur="$(fingerprint "$path")"
    if [ -n "$cur" ] && [ "$cur" != "$seen" ]; then
      printf '%s\n%s' "$cur" "$path" > "$rec" 2>/dev/null
    fi
  done < "$snap"
  rm -f "$snap" 2>/dev/null
  exit 0
fi

# ---- everything else is file-scoped -------------------------------------------
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"

# No file path (or jq failed) -> nothing to guard.
[ -z "$file" ] && exit 0

# Derive a filesystem-safe key for this path. Try the hashers that actually exist
# on this box (Linux ships sha1sum/md5sum; macOS ships shasum/md5), and as a last
# resort sanitize the path itself. If everything somehow yields nothing, callers
# fail OPEN rather than deny.
hashkey() {
  local f="$1" k=""
  k="$(printf '%s' "$f" | sha1sum 2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | shasum  2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | md5sum  2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | md5     2>/dev/null)";                 [ -n "$k" ] && { printf '%s' "$k"; return; }
  # Sanitized-path fallback (truncated so an absurd path can't blow up the name).
  printf '%s' "$f" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-200
}

key="$(hashkey "$file")"
rec="${statedir}/${key}"

case "$phase" in
  record)
    # Store the current fingerprint as "the version this session has seen".
    [ -f "$file" ] || exit 0
    [ -z "$key" ] && exit 0            # fail open — no usable key
    mkdir -p "$statedir" 2>/dev/null || exit 0
    touch "$statedir" 2>/dev/null      # keep tmp-reapers from ageing out an active session
    cur="$(fingerprint "$file")"
    [ -n "$cur" ] && printf '%s\n%s' "$cur" "$file" > "$rec" 2>/dev/null
    exit 0
    ;;

  check)
    # A file that doesn't exist yet can't be clobbered — allow (new-file Write).
    [ -f "$file" ] || exit 0
    [ -z "$key" ] && exit 0            # fail open — no usable key
    cur="$(fingerprint "$file")"

    if [ -f "$rec" ]; then
      seen="$(head -n1 "$rec" 2>/dev/null)"
      if [ -n "$cur" ] && [ "$cur" = "$seen" ]; then
        exit 0  # unchanged since we last saw it — safe
      fi
      # Backward tolerance: a record written by an older version of this script
      # holds a bare epoch (no ':'). Compare seconds-only against it.
      case "$seen" in
        *:*) : ;;                      # new-format record; full compare already failed
        *)
          cur_sec="${cur%%:*}"; cur_sec="${cur_sec%%.*}"
          [ -n "$cur_sec" ] && [ "$cur_sec" = "$seen" ] && exit 0
          ;;
      esac
      reason="⚠️ Concurrency guard: \"${file}\" changed on disk since you last read it — another Claude instance likely edited it. (Changes made by this session's own Bash commands are normally auto-absorbed; if this was one, the file was already stale before that command ran.) Re-Read the file, reconcile your change with what's now there, then retry. (If you're certain you want to override, tell the user.)"
    else
      # File exists but this session never Read or wrote it.
      reason="⚠️ Concurrency guard: \"${file}\" exists on disk but this session hasn't Read it — it may belong to another Claude instance running in this repo, or was created by a shell command (a hook can't tell which files a Bash call creates). Read it first to see its current contents, then decide whether to edit/overwrite."
    fi

    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
      "$(printf '%s' "$reason" | jq -Rs .)"
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
