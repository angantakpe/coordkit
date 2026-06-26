#!/usr/bin/env bash
# concurrency-guard.sh — prevent clobbering files a sibling Claude instance touched.
#
# The user routinely runs several Claude Code instances in the same repo at once.
# This hook tracks the mtime of each file THIS session has Read or written, and
# blocks a Write/Edit when the file on disk has changed since we last saw it
# (or we never saw it) — the signature of another instance having edited it.
#
# Usage (wired from settings.json):
#   PreToolUse  Write|Edit  -> concurrency-guard.sh check
#   PostToolUse Read         -> concurrency-guard.sh record
#   PostToolUse Write|Edit   -> concurrency-guard.sh record
#
# Reads the hook JSON on stdin. Never hard-fails the tool pipeline: on any internal
# error it exits 0 (allow) so a bug here can't wedge the session.
set -uo pipefail

phase="${1:-check}"
input="$(cat)"

file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
sid="$(printf '%s' "$input"  | jq -r '.session_id // "nosession"' 2>/dev/null)"

# No file path (or jq failed) -> nothing to guard.
[ -z "$file" ] && exit 0

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

statedir="${TMPDIR:-/tmp}/claude-concurrency/${sid}"
key="$(printf '%s' "$file" | sha1sum | cut -d' ' -f1)"
rec="${statedir}/${key}"

case "$phase" in
  record)
    # Store the current mtime as "the version this session has seen".
    [ -f "$file" ] || exit 0
    mkdir -p "$statedir" 2>/dev/null || exit 0
    cur="$(mtime "$file")"
    [ -n "$cur" ] && printf '%s' "$cur" > "$rec" 2>/dev/null
    exit 0
    ;;

  check)
    # A file that doesn't exist yet can't be clobbered — allow (new-file Write).
    [ -f "$file" ] || exit 0
    cur="$(mtime "$file")"

    if [ -f "$rec" ]; then
      seen="$(cat "$rec" 2>/dev/null)"
      if [ -n "$cur" ] && [ "$cur" = "$seen" ]; then
        exit 0  # unchanged since we last saw it — safe
      fi
      reason="⚠️ Concurrency guard: \"${file}\" changed on disk since you last read it — another Claude instance running in this repo may have edited it. Re-Read the file, reconcile your change with what's now there, then retry. (If you're certain you want to override, tell the user.)"
    else
      # File exists but this session never Read or wrote it.
      reason="⚠️ Concurrency guard: \"${file}\" exists on disk but this session hasn't Read it — it may belong to another Claude instance running in this repo. Read it first to see its current contents, then decide whether to edit/overwrite."
    fi

    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
      "$(printf '%s' "$reason" | jq -Rs .)"
    exit 0
    ;;

  *)
    exit 0
    ;;
esac
