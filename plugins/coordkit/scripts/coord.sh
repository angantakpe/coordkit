#!/usr/bin/env bash
# shellcheck shell=bash
# coord.sh — THE hook dispatcher. Every coordkit hook is one call to this file.
#
# Before 3.0.0 the coordkit and coordguard plugins registered six overlapping
# hook commands between them, each re-execing a whole bash script and re-parsing
# the hook JSON. This sources bus.sh / ledger.sh / guard.sh as libraries once and
# runs the phases for an event in order, in-process.
#
# Subcommands (argv[1]) and the phases each one runs, in order:
#
#   session-start    SessionStart                          bus start  → ledger start
#                                                          → statusline drift note
#   prompt-submit    UserPromptSubmit                      bus task   → ledger prompt
#   pretool-write    PreToolUse  Write|Edit|NotebookEdit   guard check → bus check
#   pretool-bash     PreToolUse  Bash                      guard snapshot
#   pretool-task     PreToolUse  Task                      bus subagent-start
#   posttool-write   PostToolUse Write|Edit|NotebookEdit|Read
#                                                          bus record → guard record
#   posttool-bash    PostToolUse Bash                      bus record → guard absorb
#   posttool-task    PostToolUse Task                      bus subagent-stop
#   session-end      SessionEnd                            bus stop   → guard cleanup
#
# The hook JSON is read from stdin ONCE and replayed to each phase.
#
# ── Never blocks by default ──────────────────────────────────────────────────
# guard_check is the only phase that can deny a tool call, and its first action
# is the ck_enforcement_mode() gate: unless the resolved mode is "guard" it
# returns 0 without looking at anything. In coordkit's default "warn" mode this
# dispatcher is behaviourally identical to the 2.x bus+ledger hooks.
#
# When guard_check DOES deny, it has already written the deny JSON to stdout and
# we stop there — a denied call gets no redundant soft warning from bus check.
#
# ── One hook, one JSON object ────────────────────────────────────────────────
# SessionStart and UserPromptSubmit each run TWO context-producing phases that
# used to be TWO separate hook commands with two separate stdouts. A single hook
# command may only emit ONE JSON object, so their additionalContext payloads are
# merged by ck_emit_context below rather than concatenated (two objects back to
# back would fail to parse and silently drop the shared context entirely).
#
# Defensive throughout: always exits 0 so a bug here can never wedge a session.
set -uo pipefail

CK_ROOT="${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}"

# A missing library means a broken install — exit 0 (allow) rather than run on
# with half the coordination layer loaded.
# shellcheck source=./common.sh
. "${CK_ROOT}/scripts/common.sh" 2>/dev/null || exit 0
# shellcheck source=./bus.sh
. "${CK_ROOT}/scripts/bus.sh"    2>/dev/null || exit 0
# shellcheck source=./ledger.sh
. "${CK_ROOT}/scripts/ledger.sh" 2>/dev/null || exit 0
# shellcheck source=./guard.sh
. "${CK_ROOT}/scripts/guard.sh"  2>/dev/null || exit 0
# shellcheck source=./statusline-setup.sh
. "${CK_ROOT}/scripts/statusline-setup.sh" 2>/dev/null || exit 0

# Merge the additionalContext of any number of hook-output JSON blobs into the
# single object this hook is allowed to emit. Blobs that are empty, unparseable,
# or carry no additionalContext contribute nothing; if nothing survives we print
# nothing at all, which is what "no context to add" has always looked like.
#
# Also emits an NDJSON {"type":"message",...} line with the same text so the
# digest shows up as a normal, readable line in the user's terminal — the
# hookSpecificOutput JSON alone only reaches the model (as invisible
# context), never the user, which is why the ledger/bus digest used to be
# effectively invisible unless you went digging in raw hook output.
#
# The visible line is prefixed "[coordkit]" so it's distinguishable at a
# glance from other plugins' hook messages (e.g. claude-mem's semantic-match
# digest) that land in the same NDJSON {"type":"message"} shape on the same
# stdout stream — without a tag there's no way to tell provenance apart from
# reading the body text.
ck_emit_context() {  # <hookEventName> [json_blob ...]
  local ev="$1" ctx="" blob part
  shift
  for blob in "$@"; do
    [ -n "$blob" ] || continue
    part="$(printf '%s' "$blob" | jq -r 'select(type=="object")
                                         | .hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
    [ -n "$part" ] || continue
    [ -n "$ctx" ] && ctx+=$'\n'
    ctx+="$part"
  done
  [ -n "$ctx" ] || return 0
  printf '{"type":"message","message":%s}\n' "$(printf '[coordkit] %s' "$ctx" | jq -Rs .)"
  printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s}}\n' \
    "$(printf '%s' "$ev" | jq -Rs .)" "$(printf '[coordkit]\n%s' "$ctx" | jq -Rs .)"
}

event="${1:-}"
input="$(cat)"

case "$event" in
  session-start)
    # statusline_drift_note is read-only and usually silent: it speaks up only
    # when the installed statusline wrapper can no longer find bus.sh, i.e. the
    # badge is already showing its not-found warning.
    ck_emit_context SessionStart \
      "$(bus_run    start <<<"$input")" \
      "$(ledger_run start <<<"$input")" \
      "$(statusline_drift_note)"
    ;;

  prompt-submit)
    ck_emit_context UserPromptSubmit \
      "$(bus_run    task   <<<"$input")" \
      "$(ledger_run prompt <<<"$input")"
    ;;

  pretool-write)
    # guard_check prints its own deny JSON and returns 1. Stop there: the call is
    # already denied, a soft "someone else touched this" warning adds nothing.
    guard_check "$input" || exit 0
    bus_run check <<<"$input"
    ;;

  pretool-bash)
    guard_snapshot "$input"
    ;;

  pretool-task)
    bus_run subagent-start <<<"$input"
    ;;

  posttool-write)
    bus_run record <<<"$input"
    guard_record "$input"
    ;;

  posttool-bash)
    bus_run record <<<"$input"
    guard_absorb "$input"
    ;;

  posttool-task)
    bus_run subagent-stop <<<"$input"
    ;;

  session-end)
    bus_run stop <<<"$input"
    guard_cleanup "$input"
    ;;

  *)
    # Unknown event: do nothing, successfully.
    ;;
esac

exit 0
