#!/usr/bin/env bash
# shellcheck shell=bash
# guard.sh — prevent clobbering files a sibling coordkit instance touched.
# (Was coordguard's scripts/concurrency-guard.sh; merged into coordkit in 3.0.0.)
#
# The user routinely runs several coordkit instances in the same repo at once.
# This tracks a fingerprint (mtime + size) of each file THIS session has Read or
# written, and DENIES a Write/Edit when the file on disk has changed since we last
# saw it (or we never saw it) — the signature of another instance having edited it.
#
# ── OFF BY DEFAULT ───────────────────────────────────────────────────────────
# guard_check's very first action is ck_enforcement_mode() (scripts/common.sh).
# Unless that resolves to "guard" it returns 0 immediately, so the deny below is
# structurally unreachable in coordkit's default "warn" mode — the plugin keeps
# its historical never-blocks contract. `/guard on` flips the repo to guard mode.
#
# The OTHER phases (record/snapshot/absorb/cleanup) are deliberately NOT gated:
# they only maintain the fingerprint store, emit nothing, and can never deny. By
# keeping them warm, `/guard on` mid-session arms a guard that already knows what
# this session has read, instead of one that denies every file it has no record
# of. cleanup must always run for the same reason — it removes state these phases
# wrote regardless of the mode in force at SessionEnd.
#
# Usage — as a library (how hooks reach it; see scripts/coord.sh):
#   . guard.sh
#   guard_check "$hook_json"    # 0 = allow · 1 = DENIED (deny JSON on stdout)
#   guard_record   "$hook_json" # PostToolUse Read|Write|Edit|NotebookEdit
#   guard_snapshot "$hook_json" # PreToolUse  Bash
#   guard_absorb   "$hook_json" # PostToolUse Bash
#   guard_cleanup  "$hook_json" # SessionEnd
#   guard_driftreport "$hook_json" # UserPromptSubmit — ALWAYS ON (see below)
#
# Usage — as a CLI (hook JSON on stdin, same phase names):
#   guard.sh check|record|snapshot|absorb|cleanup|driftreport
#   guard.sh on | off | status        # read/write the enforcement mode
#
# ── guard_driftreport: read-set drift warning, not gated by enforcement mode ──
# Every other deny/warn phase above only matters in "guard" mode. This one is
# pure information and fires in "warn" mode too (coordkit's default): it tells
# the model which files it already Read/Write/Edit'd THIS session have since
# changed on disk — a sibling instance edited them, a `git pull` landed, an
# editor outside Claude touched them — so it stops silently reasoning from
# stale content until it happens to re-Read. Never denies, never mutates guard
# state (no guard_record call in here): a stored fingerprint only advances
# through the normal posttool-write -> guard_record path, so re-Reading a
# drifted file is what naturally stops it being mentioned next turn.
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
# Never hard-fails the tool pipeline: on any internal error it returns 0 (allow)
# so a bug here can't wedge the session. The deny path is a deliberate JSON
# permissionDecision, never an error exit.
set -uo pipefail

[ -n "${_CK_GUARD_SH:-}" ] && return 0 2>/dev/null
_CK_GUARD_SH=1

# common.sh supplies ck_enforcement_mode() (the gate) and resolve_root(). A
# missing common.sh means a broken install; without the gate we must NOT reach
# the deny path at all, so bail out defining nothing rather than fail into it.
# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh" || return 0 2>/dev/null

# --------------------------------------------------------------------------- #
# State layout
# --------------------------------------------------------------------------- #

# State root: prefer a per-user directory (XDG_RUNTIME_DIR is 0700 and per-user on
# Linux; $HOME/.cache is per-user too). World-writable /tmp is a last resort — there
# another local user can pre-create the tree and make our mkdir/writes fail silently,
# or plant fake fingerprints. Fall back rather than fail if nothing else is writable.
_GUARD_BASE=""
_guard_tree_name() {
  if [ -n "${COORDKIT_GUARD_TREE:-}" ]; then printf '%s' "$COORDKIT_GUARD_TREE"; return 0; fi
  if [ -n "${CLAUDE_GUARD_TREE:-}" ]; then printf '%s' "$CLAUDE_GUARD_TREE"; return 0; fi
  if [ -n "${CODEX_GUARD_TREE:-}" ]; then printf '%s' "$CODEX_GUARD_TREE"; return 0; fi
  if [ -n "${GEMINI_GUARD_TREE:-}" ]; then printf '%s' "$GEMINI_GUARD_TREE"; return 0; fi
  # Renaming this default only orphans an upgrading session's old state dir
  # (per-session, cache-resident, re-adopted on the next Read) — nothing durable
  # is keyed on the literal name.
  printf 'coordkit-guard'
}

_guard_base() {
  [ -n "$_GUARD_BASE" ] && { printf '%s' "$_GUARD_BASE"; return; }
  local cands=() cand
  local tree
  tree="$(_guard_tree_name)"
  [ -n "${XDG_RUNTIME_DIR:-}" ] && cands+=("${XDG_RUNTIME_DIR}/${tree}")
  [ -n "${HOME:-}" ] && cands+=("${HOME}/.cache/${tree}")
  cands+=("${TMPDIR:-/tmp}/${tree}")
  for cand in "${cands[@]}"; do
    if mkdir -p "$cand" 2>/dev/null && [ -w "$cand" ]; then
      chmod 700 "$cand" 2>/dev/null
      _GUARD_BASE="$cand"; printf '%s' "$_GUARD_BASE"; return
    fi
  done
  _GUARD_BASE="${TMPDIR:-/tmp}/$tree"
  printf '%s' "$_GUARD_BASE"
}

# Session id out of the hook JSON. It is used to build filesystem paths (and the
# rm -rf target in cleanup), so it must be a single, non-empty path component.
# Anything else degrades to a fixed safe value rather than erroring.
_guard_sid() {
  local sid
  sid="$(printf '%s' "${1:-}" | jq -r '.session_id // "nosession"' 2>/dev/null)"
  case "$sid" in
    ""|.|..|*/*|*$'\n'*) sid="nosession" ;;
  esac
  printf '%s' "$sid"
}

_guard_statedir() { printf '%s/%s' "$(_guard_base)" "$(_guard_sid "${1:-}")"; }

# Composite fingerprint: high-resolution mtime + size, joined by ':'. The size
# catches a sibling write that lands in the same wall-clock second as our Read
# (whole-second mtime alone would miss it). Prefer GNU nanosecond mtime, fall back
# to whole-second (GNU then BSD); prefer GNU size, fall back to BSD size.
_guard_fingerprint() {
  local f="$1" mt="" sz=""
  mt="$(stat -c %.Y "$f" 2>/dev/null)"                  # GNU, nanosecond
  [ -z "$mt" ] && mt="$(stat -c %Y "$f" 2>/dev/null)"   # GNU, whole second
  [ -z "$mt" ] && mt="$(stat -f %m "$f" 2>/dev/null)"   # BSD, whole second
  sz="$(stat -c %s "$f" 2>/dev/null)"                   # GNU size
  [ -z "$sz" ] && sz="$(stat -f %z "$f" 2>/dev/null)"   # BSD size
  printf '%s:%s' "$mt" "$sz"
}

# Derive a filesystem-safe key for a path. Try the hashers that actually exist on
# this box (Linux ships sha1sum/md5sum; macOS ships shasum/md5), and as a last
# resort sanitize the path itself. If everything somehow yields nothing, callers
# fail OPEN rather than deny.
_guard_hashkey() {
  local f="$1" k=""
  k="$(printf '%s' "$f" | sha1sum 2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | shasum  2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | md5sum  2>/dev/null | cut -d' ' -f1)"; [ -n "$k" ] && { printf '%s' "$k"; return; }
  k="$(printf '%s' "$f" | md5     2>/dev/null)";                 [ -n "$k" ] && { printf '%s' "$k"; return; }
  # Sanitized-path fallback (truncated so an absurd path can't blow up the name).
  printf '%s' "$f" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-200
}

# The guarded file. NotebookEdit names its target `notebook_path`, not `file_path`.
_guard_file() {
  printf '%s' "${1:-}" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null
}

# --------------------------------------------------------------------------- #
# Best-effort attribution for the deny reason — WHO likely changed the file,
# not just THAT it changed. String-content enrichment only: nothing here
# alters guard_check's gate, its fingerprint comparison, or its return codes,
# and every lookup below fails silently (empty output) so a broken/missing
# signal degrades to today's plain generic reason rather than a broken one.
#
# Resolves the SAME .coordkit-bus/ bus.sh and ledger.sh would for this hook
# event (common.sh's resolve_root(), the one canonical rule). Doesn't call
# into bus.sh/ledger.sh's own agent_live()/owner_live(): both are defined
# INSIDE bus_main()/ledger_main(), the phase-dispatch functions those files
# only expose externally via *_run() — which runs the phase in a SUBSHELL
# (see each file's header), so a function it defines never survives back out
# to us, and calling bus_main/ledger_main directly risks one of their many
# internal `exit 0`s killing this hook process outright instead of returning.
# The TTL below is therefore a value copy, not a call — keep it equal to
# bus.sh's STALE_HARD / ledger.sh's LIVE_TTL (both 21600s = 6h) if either
# changes.
# --------------------------------------------------------------------------- #
_GUARD_LIVE_TTL=21600

# Same cwd → root resolution bus.sh/ledger.sh use for every hook phase.
_guard_repo_root() {  # <hook_json>
  local input="${1:-}" cwd
  cwd="$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)"
  [ -n "$cwd" ] || cwd="$PWD"
  resolve_root "$cwd"
}

# THIS session's raw session_id, matching how agents/<sid>.json and
# claims/<sha>.json store `.sid` — deliberately NOT _guard_sid() above, which
# sanitizes for use as an rm -rf path component; here it's only ever compared
# against JSON field values, read-only.
_guard_raw_sid() {
  printf '%s' "${1:-}" | jq -r '.session_id // "nosession"' 2>/dev/null
}

# Field separator for the sid/branch/task rows below. NOT tab: tab is one of
# bash's IFS *whitespace* characters, so `IFS=$'\t' read` silently COLLAPSES a
# run of them — an empty branch or task field would merge into its neighbor
# and shift every field after it. \x1f (ASCII unit separator) doesn't get that
# whitespace treatment, so empty fields survive `read` intact — the exact
# problem ledger.sh's own `US=$'\x1f'` projection separator documents and
# works around; same fix, applied here.
_GUARD_FS=$'\x1f'

# First LIVE agent (excluding $3) whose heartbeat's `files` list contains $2
# (a bus-root-relative path — bus.sh's `record` phase stores files that way,
# via `rel="${file#$root/}"`). Prints "sid8<FS>host<FS>branch<FS>task".
_guard_who_has_file() {  # <agents_dir> <relpath> <exclude_sid>
  local agents="$1" relpath="$2" exclude="$3" f s host last br task hit t
  [ -d "$agents" ] || return 0
  t="$(date +%s)"
  for f in "$agents"/*.json; do
    [ -e "$f" ] || continue
    IFS="$_GUARD_FS" read -r s host last br task hit <<< "$(jq -r --arg p "$relpath" '
        [ (.sid // ""), (.host // "unknown"), ((.last_seen // 0) | tostring), (.branch // "?"),
          (.task // ""), ((((.files // []) | index($p)) != null) | tostring) ]
        | join("")
      ' "$f" 2>/dev/null)"
    { [ -z "$s" ] || [ "$s" = "$exclude" ]; } && continue
    [ "$hit" = "true" ] || continue
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    [ $(( t - last )) -le "$_GUARD_LIVE_TTL" ] || continue
    printf '%s\x1f%s\x1f%s\x1f%s\n' "${s:0:8}" "$host" "$br" "$task"
    return 0
  done
  return 0
}

# The claims/<key>.json soft file-lock. bus.sh's hashkey() uses the SAME
# sha1sum→shasum→md5sum→md5→sanitized-path fallback chain, on the SAME raw
# tool_input.file_path string, as _guard_hashkey() above — confirmed by
# reading bus.sh directly, not assumed, so the caller's own $key is reused
# here rather than re-hashed. Prints "sid8<FS>branch<FS>age_seconds" on a
# hit (excluding $3), whether or not that session is still live — a claim is
# a weaker, history-only signal (see docs/BUS.md §1), so this is deliberately
# a lower-priority fallback behind _guard_who_has_file above, not another
# liveness check. Prints "sid8<FS>host<FS>branch<FS>age_seconds".
_guard_who_claimed() {  # <bus_dir> <key> <exclude_sid>
  local bus="$1" key="$2" exclude="$3" cf s ts host br t
  cf="${bus}/claims/${key}.json"
  [ -f "$cf" ] || return 0
  s="$(jq -r '.sid // empty' "$cf" 2>/dev/null)"
  { [ -z "$s" ] || [ "$s" = "$exclude" ]; } && return 0
  ts="$(jq -r '.ts // 0' "$cf" 2>/dev/null)"
  case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
  host="$(jq -r '.host // "unknown"' "${bus}/agents/${s}.json" 2>/dev/null)"
  br="$(jq -r '.branch // empty' "${bus}/agents/${s}.json" 2>/dev/null)"
  t="$(date +%s)"
  printf '%s\x1f%s\x1f%s\x1f%s\n' "${s:0:8}" "$host" "$br" "$(( t - ts ))"
  return 0
}

# Composes the attribution sentence to append to a deny reason, or "" if
# neither signal found anything. $3 (key) is optional — pass the caller's
# already-computed _guard_hashkey result to avoid re-hashing; empty computes
# it fresh.
_guard_attribution() {  # <hook_json> <abs_file> [key]
  local input="$1" file="$2" key="${3:-}" root busdir relpath mysid
  local sid8 host br task age hint
  root="$(_guard_repo_root "$input")"
  busdir="${root}/.coordkit-bus"
  [ -d "$busdir" ] || return 0
  relpath="${file#"$root"/}"
  mysid="$(_guard_raw_sid "$input")"
  IFS="$_GUARD_FS" read -r sid8 host br task <<< "$(_guard_who_has_file "${busdir}/agents" "$relpath" "$mysid")"
  if [ -n "$sid8" ]; then
    hint="$(ck_coordination_hint "$sid8")"
    printf ' Session %s (host: %s, branch: %s%s) is the likely source. %s' \
      "$sid8" "${host:-unknown}" "${br:-?}" "${task:+, working on: '${task}'}" "$hint"
    return 0
  fi

  [ -n "$key" ] || key="$(_guard_hashkey "$file")"
  IFS="$_GUARD_FS" read -r sid8 host br age <<< "$(_guard_who_claimed "$busdir" "$key" "$mysid")"
  if [ -n "$sid8" ]; then
    hint="$(ck_coordination_hint "$sid8")"
    printf ' Session %s'"'"'s file-lock claim on this file is the most recent (host: %s%s), ~%ss ago. %s' \
      "$sid8" "${host:-unknown}" "${br:+, branch: $br}" "${age:-?}" "$hint"
    return 0
  fi
  return 0
}

# --------------------------------------------------------------------------- #
# Phases
# --------------------------------------------------------------------------- #

# guard_check <hook_json>
#   0 = allow (nothing printed) · 1 = DENIED, deny JSON already on stdout.
guard_check() {
  # THE GATE — first action, before any state is touched. Everything below,
  # including the only permissionDecision:"deny" in coordkit, is unreachable
  # unless the resolved enforcement mode is exactly "guard".
  [ "$(ck_enforcement_mode)" = "guard" ] || return 0

  local input="${1:-}" file key rec statedir cur seen cur_sec reason
  file="$(_guard_file "$input")"
  [ -z "$file" ] && return 0          # no file path (or jq failed) — nothing to guard
  [ -f "$file" ] || return 0          # doesn't exist yet — can't be clobbered (new-file Write)
  key="$(_guard_hashkey "$file")"
  [ -z "$key" ] && return 0           # fail open — no usable key
  statedir="$(_guard_statedir "$input")"
  rec="${statedir}/${key}"
  cur="$(_guard_fingerprint "$file")"

  if [ -f "$rec" ]; then
    seen="$(head -n1 "$rec" 2>/dev/null)"
    if [ -n "$cur" ] && [ "$cur" = "$seen" ]; then
      return 0  # unchanged since we last saw it — safe
    fi
    # Backward tolerance: a record written by an older version of this script
    # holds a bare epoch (no ':'). Compare seconds-only against it.
    case "$seen" in
      *:*) : ;;                       # new-format record; full compare already failed
      *)
        cur_sec="${cur%%:*}"; cur_sec="${cur_sec%%.*}"
        [ -n "$cur_sec" ] && [ "$cur_sec" = "$seen" ] && return 0
        ;;
    esac
    reason="⚠️ Concurrency guard: \"${file}\" changed on disk since you last read it — another coordkit instance likely edited it.$(_guard_attribution "$input" "$file" "$key") (Changes made by this session's own Bash commands are normally auto-absorbed; if this was one, the file was already stale before that command ran.) Re-Read the file, reconcile your change with what's now there, then retry. (If you're certain you want to override, tell the user.)"
  else
    # File exists but this session never Read or wrote it.
    reason="⚠️ Concurrency guard: \"${file}\" exists on disk but this session hasn't Read it — it may belong to another coordkit instance running in this repo, or was created by a shell command (a hook can't tell which files a Bash call creates).$(_guard_attribution "$input" "$file" "$key") Read it first to see its current contents, then decide whether to edit/overwrite."
  fi

  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
    "$(printf '%s' "$reason" | jq -Rs .)"
  return 1
}

# guard_record <hook_json> — store the current fingerprint as "the version this
# session has seen". Always returns 0.
guard_record() {
  local input="${1:-}" file key statedir rec cur
  file="$(_guard_file "$input")"
  [ -z "$file" ] && return 0
  [ -f "$file" ] || return 0
  key="$(_guard_hashkey "$file")"
  [ -z "$key" ] && return 0            # fail open — no usable key
  statedir="$(_guard_statedir "$input")"
  mkdir -p "$statedir" 2>/dev/null || return 0
  touch "$statedir" 2>/dev/null        # keep tmp-reapers from ageing out an active session
  rec="${statedir}/${key}"
  cur="$(_guard_fingerprint "$file")"
  [ -n "$cur" ] && printf '%s\n%s' "$cur" "$file" > "$rec" 2>/dev/null
  return 0
}

# Pair the two halves of one Bash call by tool_use_id where the host provides it;
# otherwise share one slot (parallel Bash calls then degrade to the old
# deny-and-re-Read behavior at worst, never to a wrong allow of sibling edits).
# The name is a dotfile so guard_snapshot's record glob skips it.
_guard_snappath() {  # <statedir> <hook_json>
  local snapid
  snapid="$(printf '%s' "${2:-}" | jq -r '.tool_use_id // empty' 2>/dev/null | tr -c 'A-Za-z0-9' '_' | cut -c1-64)"
  snapid="${snapid%_}"
  [ -n "$snapid" ] || snapid="shared"
  printf '%s/.bashsnap.%s' "$1" "$snapid"
}

# guard_snapshot <hook_json> — record which tracked files are still clean right
# before a Bash call runs. Always returns 0.
guard_snapshot() {
  local input="${1:-}" statedir snap tmp rec path seen cur
  statedir="$(_guard_statedir "$input")"
  [ -d "$statedir" ] || return 0
  snap="$(_guard_snappath "$statedir" "$input")"
  tmp="${snap}.tmp.$$"
  : > "$tmp" 2>/dev/null || return 0
  for rec in "$statedir"/*; do
    [ -f "$rec" ] || continue
    path="$(sed -n '2p' "$rec" 2>/dev/null)"
    [ -n "$path" ] && [ -f "$path" ] || continue   # old-format or vanished — skip
    seen="$(head -n1 "$rec" 2>/dev/null)"
    cur="$(_guard_fingerprint "$path")"
    [ -n "$cur" ] && [ "$cur" = "$seen" ] && printf '%s\n' "${rec##*/}" >> "$tmp"
  done
  mv -f "$tmp" "$snap" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# guard_absorb <hook_json> — re-stamp files that changed during our own Bash
# window. Only files that were clean at snapshot time are eligible. Always 0.
guard_absorb() {
  local input="${1:-}" statedir snap k rec path seen cur
  statedir="$(_guard_statedir "$input")"
  [ -d "$statedir" ] || return 0
  snap="$(_guard_snappath "$statedir" "$input")"
  [ -f "$snap" ] || return 0
  while IFS= read -r k; do
    case "$k" in ""|.*|*/*) continue ;; esac        # our own keys are plain hashes
    rec="${statedir}/${k}"
    [ -f "$rec" ] || continue
    path="$(sed -n '2p' "$rec" 2>/dev/null)"
    [ -n "$path" ] && [ -f "$path" ] || continue
    seen="$(head -n1 "$rec" 2>/dev/null)"
    cur="$(_guard_fingerprint "$path")"
    if [ -n "$cur" ] && [ "$cur" != "$seen" ]; then
      printf '%s\n%s' "$cur" "$path" > "$rec" 2>/dev/null
    fi
  done < "$snap"
  rm -f "$snap" 2>/dev/null
  return 0
}

# guard_cleanup <hook_json> — remove ONLY this session's statedir. Always 0.
guard_cleanup() {
  local input="${1:-}" sid base target
  sid="$(_guard_sid "$input")"
  # _guard_sid already normalized this to a single, non-empty path component;
  # re-check here so a hostile session_id (e.g. "../..") can never make us rm
  # outside the guard state tree.
  case "$sid" in
    ""|.|..|*/*|*$'\n'*) return 0 ;;
  esac
  base="$(_guard_base)"
  target="${base}/${sid}"
  # Belt-and-braces: the resolved path must be exactly base/<sid>, under base.
  [ "$target" = "${base}/${sid}" ] || return 0
  case "$target" in
    "${base}/"?*) ;;
    *) return 0 ;;
  esac
  [ -d "$target" ] && rm -rf "$target" 2>/dev/null
  return 0
}

# _guard_drift_who <root> <mysid> <abs_path> — best-effort attribution: is a
# LIVE sibling session (not this one) the likely author of the drift? Scans
# bus.sh's own heartbeats (<root>/.coordkit-bus/agents/<sid>.json —
# {sid,last_seen,files[],task}, see bus.sh's heartbeat()) for one whose `files`
# list — paths it has Write/Edit/NotebookEdit'd, relative to root, NOT
# read-only Reads — contains this path. Prints "sid8" or "sid8 (task)" on a
# hit, nothing on a miss; guard.sh doesn't source bus.sh (its heartbeat/
# agent_live helpers are private to bus_main()), so this re-reads the same
# on-disk heartbeat file directly rather than duplicating bus.sh's logic.
# 21600 mirrors bus.sh's STALE_HARD / ledger.sh's LIVE_TTL — the same
# "is this session still around" cutoff used everywhere else in coordkit.
# Read-only: never touches the bus. Always returns 0.
_guard_drift_who() {
  local root="$1" mysid="$2" path="$3" agents_dir rel af osid last age hit task t
  agents_dir="${root}/.coordkit-bus/agents"
  [ -d "$agents_dir" ] || return 0
  rel="${path#"$root"/}"
  t="$(date +%s)"
  for af in "$agents_dir"/*.json; do
    [ -f "$af" ] || continue
    osid="$(jq -r '.sid // empty' "$af" 2>/dev/null)"
    [ -n "$osid" ] && [ "$osid" != "$mysid" ] || continue
    last="$(jq -r '.last_seen // 0' "$af" 2>/dev/null)"
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    age=$(( t - last ))
    [ "$age" -le 21600 ] || continue
    hit="$(jq -r --arg f "$rel" '(.files // []) | any(. == $f)' "$af" 2>/dev/null)"
    [ "$hit" = "true" ] || continue
    task="$(jq -r '.task // empty' "$af" 2>/dev/null)"
    if [ -n "$task" ]; then printf '%s (%s)' "${osid:0:8}" "$task"; else printf '%s' "${osid:0:8}"; fi
    return 0
  done
  return 0
}

# guard_driftreport <hook_json> — see the header note above. ALWAYS runs,
# regardless of ck_enforcement_mode(); prints hook-output JSON only when at
# least one tracked file has drifted, nothing otherwise. Always returns 0.
guard_driftreport() {
  local input="${1:-}" statedir rec path seen cur
  local -a drifted=()
  statedir="$(_guard_statedir "$input")"
  [ -d "$statedir" ] || return 0   # fresh session (or nothing Read/written yet) — nothing to report

  for rec in "$statedir"/*; do
    [ -f "$rec" ] || continue
    path="$(sed -n '2p' "$rec" 2>/dev/null)"
    [ -n "$path" ] || continue      # old-format record (no path line) — nothing to compare
    seen="$(head -n1 "$rec" 2>/dev/null)"
    cur="$(_guard_fingerprint "$path")"
    [ -n "$cur" ] && [ "$cur" = "$seen" ] && continue   # unchanged since we last saw it (also true if the file vanished AND we somehow stored an empty fingerprint, which guard_record never does)
    drifted+=("$path")
  done
  [ "${#drifted[@]}" -gt 0 ] || return 0

  local cwd root mysid
  cwd="$(printf '%s' "$input" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)"
  [ -n "$cwd" ] || cwd="$PWD"
  root="$(resolve_root "$cwd")"
  mysid="$(_guard_sid "$input")"

  # Cap the list so the report stays small; attribution is only computed for
  # the shown subset, not the full (possibly larger) drifted set.
  local cap=6 shown=0 total="${#drifted[@]}" list="" entry who base p
  for p in "${drifted[@]}"; do
    [ "$shown" -lt "$cap" ] || break
    base="${p##*/}"
    who="$(_guard_drift_who "$root" "$mysid" "$p")"
    if [ -n "$who" ]; then entry="${base} (by ${who})"; else entry="$base"; fi
    [ -n "$list" ] && list+=", "
    list+="$entry"
    shown=$(( shown + 1 ))
  done
  [ "$total" -gt "$cap" ] && list+=", +$(( total - cap )) more"

  local msg="⚠️ ${total} file(s) you've read changed on disk since: ${list} — re-Read before trusting their contents."
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":%s}}\n' \
    "$(printf '%s' "$msg" | jq -Rs .)"
  return 0
}

# --------------------------------------------------------------------------- #
# Enforcement-mode CLI (/guard on|off|status)
# --------------------------------------------------------------------------- #

_guard_toml_path() {
  ck_coord_toml "$PWD"
}

# Write [enforcement].mode into the repo's coord.toml, creating the file or the
# table as needed and preserving everything else. The [enforcement] TABLE always
# lands AFTER any existing flat keys, so transports/lib.sh's top-level parser —
# which stops at the first '[' — keeps reading git-mode config exactly as before.
# The table is named for the axis (not `[mode]`) because coord.toml already has a
# bare top-level `mode` key for the transport, and TOML forbids a key and a table
# sharing a name.
_guard_mode_write() {  # $1 = guard|warn ; prints the path written
  local val="$1" toml dir tmp
  toml="$(_guard_toml_path)"; dir="$(dirname "$toml")"
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="${toml}.tmp.$$"

  if [ ! -f "$toml" ]; then
    {
      printf '# coord.toml — coordkit'"'"'s committed, SECRET-FREE coordination pointer.\n'
      printf '# >>> NEVER put tokens, API keys, or any secret in this file. <<<\n'
      printf '\n[enforcement]\n'
      # shellcheck disable=SC2016  # the backticks are literal TOML comment text
      printf '# Enforcement axis (separate from the top-level transport `mode` key):\n'
      printf '#   "warn"  — awareness only; coordkit never blocks a tool call (default).\n'
      printf '#   "guard" — additionally DENY a Write/Edit to a file that changed on\n'
      printf '#             disk since this session last read it.\n'
      printf 'mode = "%s"\n' "$val"
    } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  elif grep -qE '^[[:space:]]*\[[[:space:]]*enforcement[[:space:]]*\]' "$toml" 2>/dev/null; then
    awk -v val="$val" '
      { t = $0; sub(/^[ \t]+/, "", t)
        if (t ~ /^\[/) {
          if (intbl && !done) { print "mode = \"" val "\""; done = 1 }
          h = t; sub(/^\[[ \t]*/, "", h); sub(/[ \t]*\].*$/, "", h)
          intbl = (h == "enforcement"); print; next
        }
        if (intbl && t ~ /^mode[ \t]*=/) {
          if (!done) { print "mode = \"" val "\""; done = 1 }
          next
        }
        print
      }
      END { if (intbl && !done) print "mode = \"" val "\"" }
    ' "$toml" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  else
    cp "$toml" "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
    {
      printf '\n[enforcement]\n'
      printf '# "warn" (default) — never blocks · "guard" — hard anti-clobber deny.\n'
      printf 'mode = "%s"\n' "$val"
    } >> "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  fi

  [ -s "$tmp" ] || { rm -f "$tmp" 2>/dev/null; return 1; }
  mv -f "$tmp" "$toml" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  printf '%s' "$toml"
}

guard_mode_status() {
  local toml f v mode origin
  mode="$(ck_enforcement_mode)"; origin="$(ck_enforcement_origin)"
  toml="$(_guard_toml_path)"; f="$(ck_data_dir)/config"
  if [ "$mode" = "guard" ]; then
    printf '🛡  coordkit enforcement mode: GUARD  (from: %s)\n' "$origin"
    printf '    A Write/Edit to a file that changed on disk since this session last\n'
    printf '    read it is DENIED until you re-Read and reconcile it.\n'
  else
    printf '🛰  coordkit enforcement mode: warn  (from: %s)\n' "$origin"
    printf '    Awareness only — coordkit never blocks a tool call. This is the default.\n'
  fi
  printf '\n  precedence (first match wins):\n'
  v="$(printf '%s' "${COORDKIT_ENFORCEMENT:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    guard|warn) printf '    1. env COORDKIT_ENFORCEMENT = %s\n' "$v" ;;
    "")         printf '    1. env COORDKIT_ENFORCEMENT — unset\n' ;;
    *)          printf '    1. env COORDKIT_ENFORCEMENT = %s — not guard|warn; ignored\n' "$v" ;;
  esac
  v="$(ck_toml_table_get "$toml" enforcement mode 2>/dev/null)"
  if [ -n "$v" ]; then printf '    2. %s → [enforcement].mode = %s\n' "$toml" "$v"
  else printf '    2. %s → no [enforcement].mode\n' "$toml"; fi
  if [ -f "$f" ] && grep -qE '^[[:space:]]*enforcement[[:space:]]*=' "$f" 2>/dev/null; then
    printf '    3. %s → enforcement= present\n' "$f"
  else printf '    3. %s → absent\n' "$f"; fi
  printf '    4. built-in default = warn\n'
  return 0
}

guard_mode_cli() {  # $1 = on|off|status
  local written
  case "${1:-status}" in
    on)
      if written="$(_guard_mode_write guard)"; then
        printf '🛡  guard mode ON for this repo — wrote [enforcement] mode = "guard" to %s\n' "$written"
        printf '    Writes/Edits to files changed on disk by another instance are now DENIED\n'
        printf '    until you re-Read them. Turn it back off with /guard off.\n'
      else
        printf '⚠ could not write the enforcement mode to %s — leaving it unchanged.\n' "$(_guard_toml_path)"
      fi ;;
    off)
      if written="$(_guard_mode_write warn)"; then
        printf '🛰  guard mode OFF for this repo — wrote [enforcement] mode = "warn" to %s\n' "$written"
        printf '    Back to coordkit'"'"'s default: awareness and warnings, never a block.\n'
      else
        printf '⚠ could not write the enforcement mode to %s — leaving it unchanged.\n' "$(_guard_toml_path)"
      fi ;;
    *) guard_mode_status ;;
  esac
  return 0
}

# --------------------------------------------------------------------------- #
# Direct-execution CLI. Sourcing this file runs nothing.
# --------------------------------------------------------------------------- #
_guard_cli() {
  local phase="${1:-check}" input
  case "$phase" in
    on|off|status) guard_mode_cli "$phase"; return 0 ;;
  esac
  input="$(cat)"
  case "$phase" in
    check)       guard_check       "$input" ;;
    record)      guard_record      "$input" ;;
    snapshot)    guard_snapshot    "$input" ;;
    absorb)      guard_absorb      "$input" ;;
    cleanup)     guard_cleanup     "$input" ;;
    driftreport) guard_driftreport "$input" ;;
    *)           : ;;
  esac
  # Always exit 0, including on a deny: the deny is carried by the JSON on
  # stdout, never by an exit status.
  return 0
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  _guard_cli "$@"
  exit 0
fi
