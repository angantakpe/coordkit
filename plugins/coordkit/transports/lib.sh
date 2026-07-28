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
#   logstore_since <watermark>           emit events STRICTLY AFTER <watermark> in the
#                                        deterministic total order — for incremental
#                                        context injection. <watermark> is a total-order
#                                        key "p:c:actor" (see logstore_watermark). This
#                                        is the correct incremental cursor: a late event
#                                        that sorts before the watermark is simply "in
#                                        the past" and excluded, never a source of
#                                        shifted-position drops or duplicates.
#   logstore_watermark                   echo the total-order key ("p:c:actor") of the
#                                        LAST event, i.e. the watermark to pass to a
#                                        subsequent logstore_since.
#   logstore_tail <cursor>               LEGACY, prefer logstore_since. Emit events after
#                                        <cursor> (a numeric COUNT into the total order).
#                                        Positional and therefore lossy: because the total
#                                        order is recomputed on every call, a late-arriving
#                                        event that sorts earlier shifts positions, so the
#                                        count-based boundary can skip a real event or
#                                        re-emit one. Kept only for back-compat.
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

# Path to scripts/common.sh — same resolution shape as __logstore_transports_dir:
# prefer the plugin runtime's env var, fall back to this file's own location
# (lib.sh lives in transports/, so common.sh is ../scripts/common.sh).
__logstore_common() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh" ]; then
    printf '%s' "${CLAUDE_PLUGIN_ROOT}/scripts/common.sh"
    return 0
  fi
  printf '%s/../scripts/common.sh' "$( cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd )"
}
# Defines resolve_root()/branch_of()/ck_* — no I/O, so this keeps sourcing lib.sh
# side-effect-free (see the header note).
# shellcheck source=../scripts/common.sh
. "$(__logstore_common)" 2>/dev/null || true

# Resolve the repo root through the ONE canonical resolve_root() in
# scripts/common.sh, so the ledger's own state and the transport's segment state
# can never split across two different trees. Precedence:
#
#   CLAUDE_BUS_ROOT > git toplevel > nearest ancestor with .claude-bus/ >
#   CLAUDE_PROJECT_DIR > cwd
#
# The transport has no cwd argument to thread through — it always resolves
# relative to the process's own $PWD, which is what the ledger passes down too.
__logstore_repo_root() {
  resolve_root "$PWD"
}

# Where coord.toml lives (the committed, secret-free pointer template once installed).
__logstore_coordtoml() {
  printf '%s' "${COORDKIT_COORD_TOML:-$(__logstore_repo_root)/.claude/coord/coord.toml}"
}

# --------------------------------------------------------------------------- #
# Tiny TOML reader — top-level `key = "value"` only (no deps, no toml lib).
# Stops at the first [table] header. Handles quoting BEFORE comments so a quoted
# value containing '#' (e.g. a relay URL with a fragment) is preserved: for a
# quoted value we take everything up to the closing quote and ignore any trailing
# comment; only for an UNQUOTED value do we treat a whitespace-preceded '#' as the
# start of an inline comment. Sufficient for the flat coord.toml pointer
# (mode, room_id, remote, relay_url, ...).
# --------------------------------------------------------------------------- #
__logstore_toml_get() {
  local file="$1" key="$2" raw
  [ -f "$file" ] || return 1
  raw="$(sed -n '/^[[:space:]]*\[/q; p' "$file" \
    | grep -E "^[[:space:]]*${key}[[:space:]]*=" \
    | head -n1 \
    | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//")"
  case "$raw" in
    '"'*)  raw="${raw#\"}"; raw="${raw%%\"*}" ;;                       # double-quoted
    "'"*)  raw="${raw#\'}"; raw="${raw%%\'*}" ;;                       # single-quoted
    *)     raw="$(printf '%s' "$raw" | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]*$//')" ;;
  esac
  printf '%s' "$raw"
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
# COORDKIT_ACTOR then "local". Sanitised to a filesystem-safe token; the pure-dot
# tokens "" / "." / ".." are rejected to "_invalid" so a crafted actor can never
# resolve the log dir to the partition root or escape it (e.g. base/log/..).
__logstore_actor_of() {
  local line="$1" a
  a="$(printf '%s' "$line" | jq -r 'if type=="object" then (.actor // empty) else empty end' 2>/dev/null)"
  [ -n "$a" ] || a="${COORDKIT_ACTOR:-local}"
  a="$(printf '%s' "$a" | tr -c 'A-Za-z0-9._-' '_')"
  case "$a" in
    ''|.|..) a="_invalid" ;;
  esac
  printf '%s' "$a"
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
# Watermark helpers — the correct incremental cursor over the total order.
#
# A watermark is the total-order key of the last-seen event, encoded "p:c:actor"
# (p and c are integers so the first two ':' are unambiguous field separators; the
# actor — which may itself contain ':' — is the remainder). __watermark_of reads a
# total-ordered stream and echoes the key of its LAST line. __filter_since keeps only
# lines whose key is strictly greater than a given watermark, comparing (p,c) numeric
# then actor lexicographically — the SAME order as __total_order. An empty or
# unparseable watermark means "no cursor yet" and passes everything through (safe: it
# can only over-deliver, never drop). Input is assumed already deduped + ordered.
# --------------------------------------------------------------------------- #
__watermark_of() {
  jq -Rrn '
    [inputs] | map(select(. != "")) | (last // "")
    | if . == "" then ""
      else . as $raw
        | ($raw | (try fromjson catch null)) as $p
        | (if ($p | type) == "object" then $p else {} end) as $o
        | "\($o.clock.p // 0):\($o.clock.c // 0):\($o.actor // "")"
      end
  '
}

__filter_since() {
  local wm="${1:-}"
  jq -Rrn --arg wm "$wm" '
    ($wm | if . == "" then null
           else (capture("^(?<p>[0-9]+):(?<c>[0-9]+):(?<a>.*)$") // null) end) as $w
    | ($w | if . == null then null else {p: (.p|tonumber), c: (.c|tonumber), a: .a} end) as $w
    | [inputs] | map(select(. != ""))
    | map(. as $raw
          | ($raw | (try fromjson catch null)) as $p
          | (if ($p | type) == "object" then $p else {} end) as $o
          | { raw: $raw, p: ($o.clock.p // 0), c: ($o.clock.c // 0), a: ($o.actor // "") })
    | map(select(
        $w == null
        or (.p > $w.p)
        or (.p == $w.p and .c > $w.c)
        or (.p == $w.p and .c == $w.c and .a > $w.a)
      ))
    | .[].raw
  '
}

# --------------------------------------------------------------------------- #
# Locked append — lib owns the lock so the local/git adapters inherit atomicity for
# free (each only exposes __<mode>_lockfile and a lock-free __<mode>_append). NOTE:
# the relay adapter is special-cased in logstore_append and drives its own backing
# through this same helper, so it too is covered — but it is not wrapped a second time.
#
# flock(1) is preferred, with two robustness fixes:
#   * `-w 5` bounds the wait so a wedged holder can't stall every Claude hook forever
#     (append then returns non-zero, which propagates to the caller).
#   * When flock(1) is missing (e.g. stock macOS), fall back to a bounded mkdir-based
#     mutex so appends are still serialised instead of silently interleaving/dropping.
# The append's own exit status is propagated so a caller can see a true failure.
# --------------------------------------------------------------------------- #
__logstore_mkdir_lock() {
  local lockdir="$1" i=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ge 50 ] && return 1          # ~5s bound at 0.1s/iter
    sleep 0.1 2>/dev/null || sleep 1
  done
  return 0
}

__logstore_locked_append() {
  local mode="$1" line="$2" lock rc
  lock="$("__${mode}_lockfile")"
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 5 9 || exit 1; "__${mode}_append" "$line" ) 9>"$lock"
  else
    __logstore_mkdir_lock "${lock}.d" || return 1
    "__${mode}_append" "$line"; rc=$?
    rmdir "${lock}.d" 2>/dev/null || true
    return "$rc"
  fi
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
      # Relay manages its own durability (fold into its configured backing) + a
      # best-effort fan-out. If durability can't be met it returns non-zero and we
      # fall back so nothing is ever lost. CRUCIAL: retry the CONFIGURED backing
      # FIRST, because relay-mode READS come from that backing — spilling to a
      # different store would persist the event but hide it from relay readers. Only
      # after the backing is exhausted do we spill to the other stores as a last
      # resort. The re-append is idempotent: dedup is by eid.
      if __relay_append "$line"; then return 0; fi
      local backing; backing="$(__relay_backing)"
      printf 'coordkit[relay]: append could not be made durable; retrying backing=%s then spilling\n' "$backing" >&2
      __logstore_locked_append "$backing" "$line" && return 0
      if [ "$backing" != git ] && __logstore_have __git_append; then
        __logstore_locked_append git "$line" && return 0
      fi
      if [ "$backing" != local ]; then
        __logstore_locked_append local "$line" && return 0
      fi
      return 1
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

# logstore_since <watermark> — the correct incremental cursor. Emits every event
# STRICTLY AFTER <watermark> in the deterministic total order, filtering the same
# union readall produces (so it is mode-agnostic — the read path is identical in
# every mode). An empty watermark returns the full union. See __filter_since /
# logstore_watermark and the interface note above logstore_tail for why this is
# loss-free where the positional tail is not.
logstore_since() {
  local wm="${1:-}"
  logstore_readall | __filter_since "$wm"
}

# logstore_watermark — echo the total-order key ("p:c:actor") of the LAST event in
# the union, i.e. the watermark a consumer records to resume via logstore_since.
# Empty output means "no events yet".
logstore_watermark() {
  logstore_readall | __watermark_of
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
