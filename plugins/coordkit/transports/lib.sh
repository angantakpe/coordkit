# shellcheck shell=bash
# transports/lib.sh — the LogStore dispatcher + shared helpers for coordkit.
#
# ONE tiny interface, pluggable adapters. The ledger scripts source this file and
# only ever call the four public functions below; which adapter actually services
# them is chosen at call time from config (env COORDKIT_MODE, else `mode` in
# coord.toml, else "local"). Because projections are always recomputed from the
# union of events, the READ path is identical across every mode.
#
# Public LogStore interface (the only thing callers should use):
#   logstore_append <event_json_line>   atomically append one event (flock); route
#                                        to the active adapter.
#   logstore_readall                     emit ALL events (the UNION across every
#                                        actor), newline-delimited, deterministically
#                                        ordered + deduped, to stdout.
#   logstore_tail <cursor>               emit events after <cursor> (a numeric count
#                                        into the deterministic total order) — for
#                                        incremental context injection.
#   logstore_mode                        echo the active mode.
#
# Adapter contract (each transports/<mode>.sh implements):
#   __<mode>_append <line>     append one line (NO locking — lib does the flock)
#   __<mode>_readall           emit this mode's full union, deduped + ordered
#   __<mode>_tail <n>          emit events after numeric cursor n
#   __<mode>_lockfile          path to the flock file lib should hold for appends
#
# SOURCING IS SIDE-EFFECT-FREE: sourcing this file only DEFINES functions (and, at
# the very bottom, sources the adapter files, which themselves only define more
# functions). It performs no I/O, creates no directories, reads no config, prints
# nothing. All filesystem/network work is deferred to when a logstore_* function is
# actually called. (The eager adapter-source at the bottom is required so that, e.g.,
# bin/sync.sh can `. lib.sh` and immediately find __git_sync.)
#
# Adapter files are resolved under ${CLAUDE_PLUGIN_ROOT}/transports/ (falling back
# to this file's own directory when the env var isn't injected).

# --------------------------------------------------------------------------- #
# Path / root resolution (all in-memory; no fs mutation)
# --------------------------------------------------------------------------- #

# Directory that holds the adapter files. Prefer the plugin runtime's env var,
# fall back to this file's own location (lib.sh lives in transports/).
__logstore_transports_dir() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "${CLAUDE_PLUGIN_ROOT}/transports" ]; then
    printf '%s' "${CLAUDE_PLUGIN_ROOT}/transports"
    return 0
  fi
  # BASH_SOURCE[0] inside a function = the file where the function is defined.
  ( cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd )
}

# Resolve the repo root the same way bin/sync.sh does, so every transport agrees
# on where the coordination state lives.
__logstore_repo_root() {
  if [ -n "${CLAUDE_BUS_ROOT:-}" ];    then printf '%s' "$CLAUDE_BUS_ROOT";    return 0; fi
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then printf '%s' "$CLAUDE_PROJECT_DIR"; return 0; fi
  local top dir
  top="$(git rev-parse --show-toplevel 2>/dev/null)"
  if [ -n "$top" ]; then printf '%s' "$top"; return 0; fi
  dir="$PWD"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -d "$dir/.claude-bus" ] && { printf '%s' "$dir"; return 0; }
    dir="$(dirname "$dir")"
  done
  printf '%s' "$PWD"
}

# Where coord.toml lives (the committed, secret-free pointer template once installed).
__logstore_coordtoml() {
  printf '%s' "${COORDKIT_COORD_TOML:-$(__logstore_repo_root)/.claude/coord/coord.toml}"
}

# --------------------------------------------------------------------------- #
# Tiny TOML reader — top-level `key = "value"` only (no deps, no toml lib).
# Stops at the first [table] header, strips quotes/inline-comment/whitespace.
# Sufficient for the flat coord.toml pointer (mode, room_id, remote, ...).
# --------------------------------------------------------------------------- #
__logstore_toml_get() {
  local file="$1" key="$2"
  [ -f "$file" ] || return 1
  sed -n '/^[[:space:]]*\[/q; p' "$file" \
    | grep -E "^[[:space:]]*${key}[[:space:]]*=" \
    | head -n1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/[[:space:]]*#.*$//; s/^\"//; s/\"[[:space:]]*\$//; s/^'//; s/'[[:space:]]*\$//; s/[[:space:]]*\$//"
}

# --------------------------------------------------------------------------- #
# Mode resolution + dispatch
# --------------------------------------------------------------------------- #

# logstore_mode — env COORDKIT_MODE > coord.toml `mode` > "local". Unknown values
# are clamped to "local" so a typo can never silently break the read/write path.
logstore_mode() {
  local m=""
  if [ -n "${COORDKIT_MODE:-}" ]; then
    m="$COORDKIT_MODE"
  else
    m="$(__logstore_toml_get "$(__logstore_coordtoml)" mode 2>/dev/null)"
  fi
  case "$m" in
    local|git|relay) printf '%s\n' "$m" ;;
    "")              printf 'local\n' ;;
    *)               printf 'local\n' ;;
  esac
}

# Resolve the active mode into COORDKIT_RESOLVED_MODE for the dispatch helpers.
__logstore_resolve_mode() {
  COORDKIT_RESOLVED_MODE="$(logstore_mode)"
}

__logstore_have() { declare -F "$1" >/dev/null 2>&1; }

# Shared actor extraction — the segment partition is derived from the event's OWN
# `actor` field so two writers never target the same file. Falls back to
# COORDKIT_ACTOR then "local". Sanitised to a filesystem-safe token.
__logstore_actor_of() {
  local line="$1" a
  a="$(printf '%s' "$line" | jq -r 'if type=="object" then (.actor // empty) else empty end' 2>/dev/null)"
  [ -n "$a" ] || a="${COORDKIT_ACTOR:-local}"
  printf '%s' "$a" | tr -c 'A-Za-z0-9._-' '_'
}

# --------------------------------------------------------------------------- #
# Shared dedup + total-order helpers (used by every adapter's readall)
#
# Dedup key  = .eid  (content-addressed), or a stable per-line fallback
#              ("raw:" + base64(line)) for legacy / eid-less lines so distinct
#              legacy events are never collapsed together.
# Total order = sort by (clock.p, clock.c, actor); jq's sort_by is stable, so ties
#              keep deterministic input order. Missing fields default to (0,0,"").
# Both are single jq processes — pure, deterministic, and fast. Lines that don't
# parse as JSON objects are kept verbatim (dedup by content, ordered at the front).
# --------------------------------------------------------------------------- #

__dedup_by_eid() {
  jq -Rrn '
    [inputs]
    | map(select(. != ""))
    | reduce .[] as $raw ({seen: {}, out: []};
        ($raw | (try fromjson catch null)) as $p
        | (if ($p | type) == "object" then $p else {} end) as $o
        | (($o.eid) // ("raw:" + ($raw | @base64))) as $key
        | if (.seen[$key] // false)
          then .
          else .seen[$key] = true | .out += [$raw]
          end)
    | .out[]
  '
}

__total_order() {
  jq -Rrn '
    [inputs]
    | map(select(. != ""))
    | map(. as $raw
          | ($raw | (try fromjson catch null)) as $p
          | (if ($p | type) == "object" then $p else {} end) as $o
          | { raw: $raw,
              p: ($o.clock.p // 0),
              c: ($o.clock.c // 0),
              a: ($o.actor // "") })
    | sort_by([.p, .c, .a])
    | .[].raw
  '
}

# --------------------------------------------------------------------------- #
# Locked append — lib owns the flock so every adapter inherits atomicity for free.
# Each adapter only has to expose __<mode>_lockfile and a lock-free __<mode>_append.
# --------------------------------------------------------------------------- #
__logstore_locked_append() {
  local mode="$1" line="$2" lock
  lock="$("__${mode}_lockfile")"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  ( flock 9 || exit 1; "__${mode}_append" "$line" ) 9>"$lock"
}

# --------------------------------------------------------------------------- #
# Public LogStore interface
# --------------------------------------------------------------------------- #

logstore_append() {
  local line="${1:-}"
  [ -n "$line" ] || return 0
  line="${line%$'\n'}"          # never store a trailing newline; we add exactly one
  __logstore_resolve_mode

  case "$COORDKIT_RESOLVED_MODE" in
    relay)
      # Relay manages its own durability (local fold) + best-effort fan-out. If it
      # cannot guarantee durability it returns non-zero, and we fall back git→local
      # so nothing is ever lost. The re-append is idempotent: dedup is by eid.
      if __relay_append "$line"; then return 0; fi
      printf 'coordkit[relay]: append could not be made durable; falling back git→local\n' >&2
      if __logstore_have __git_append; then
        __logstore_locked_append git "$line" && return 0
      fi
      __logstore_locked_append local "$line"
      ;;
    git)
      __logstore_locked_append git "$line"
      ;;
    *)
      __logstore_locked_append local "$line"
      ;;
  esac
}

logstore_readall() {
  __logstore_resolve_mode
  "__${COORDKIT_RESOLVED_MODE}_readall"
}

logstore_tail() {
  local n="${1:-0}"
  case "$n" in (*[!0-9]*|'') n=0 ;; esac
  __logstore_resolve_mode
  "__${COORDKIT_RESOLVED_MODE}_tail" "$n"
}

# --------------------------------------------------------------------------- #
# Eager adapter bootstrap (function definitions only — see header note).
# Required so sourcing lib.sh makes every adapter (incl. __git_sync) available
# immediately, e.g. for bin/sync.sh's `type __git_sync` probe.
# --------------------------------------------------------------------------- #
__logstore_bootstrap() {
  local d
  d="$(__logstore_transports_dir)"
  # shellcheck source=/dev/null
  [ -f "$d/local.sh" ] && . "$d/local.sh"
  # shellcheck source=/dev/null
  [ -f "$d/git.sh" ]   && . "$d/git.sh"
  # shellcheck source=/dev/null
  [ -f "$d/relay.sh" ] && . "$d/relay.sh"
  return 0
}
__logstore_bootstrap
