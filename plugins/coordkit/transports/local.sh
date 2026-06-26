# shellcheck shell=bash
# transports/local.sh — mode=local (THE DEFAULT).
#
# Same-machine coordination, exactly as today: zero network, zero daemons, zero
# extra deps. Each actor appends only to its OWN per-actor segment file, so two
# concurrent writers never touch the same file. readall is the union of every
# actor's segments PLUS — for backward-compat — the legacy flat ledger.jsonl, all
# deduped (by eid) and totally ordered (by clock.p, clock.c, actor).
#
# Layout under <bus>/ (bus = COORDKIT_BUS_DIR, else <repo>/.claude-bus):
#   log/<actor>/seg.ndjson     per-actor append-only segment (created on demand)
#   ledger.jsonl               legacy flat ledger (read-only, folded in if present)
#   .ledger.lock               the flock file lib holds for appends (today's file)
#
# This MUST stay fast and MUST preserve current behaviour — hence the legacy
# ledger fold and the reuse of the existing .ledger.lock filename.
#
# Implements the adapter contract: __local_append / __local_readall / __local_tail
# / __local_lockfile. Sourcing defines functions only.

__local_basedir() {
  printf '%s' "${COORDKIT_BUS_DIR:-$(__logstore_repo_root)/.claude-bus}"
}

__local_lockfile() {
  printf '%s' "$(__local_basedir)/.ledger.lock"
}

# Append one line to the writing actor's own segment. No locking here — lib's
# __logstore_locked_append holds the flock around this call.
__local_append() {
  local line="$1" actor dir seg
  actor="$(__logstore_actor_of "$line")"
  dir="$(__local_basedir)/log/$actor"
  seg="$dir/seg.ndjson"
  mkdir -p "$dir" 2>/dev/null || return 1
  printf '%s\n' "$line" >> "$seg"
}

# Union of all per-actor segments + the legacy flat ledger, deduped + ordered.
# File list is LC_ALL=C-sorted so input order is deterministic (which makes the
# stable sort's tie-breaking deterministic too).
__local_readall() {
  local base seg
  base="$(__local_basedir)"
  {
    if [ -d "$base/log" ]; then
      find "$base/log" -type f -name '*.ndjson' 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r seg; do cat -- "$seg"; done
    fi
    # Legacy flat ledger, folded in last for backward-compat.
    [ -f "$base/ledger.jsonl" ] && cat -- "$base/ledger.jsonl"
  } | __dedup_by_eid | __total_order
}

# Events strictly after numeric cursor n in the deterministic total order.
__local_tail() {
  local n="${1:-0}"
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  __local_readall | awk -v n="$n" 'NR > n'
}
