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
#                                                          → guard drift report
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
# Context is emitted exactly once, as hookSpecificOutput.additionalContext.
# A former visible {"type":"message"} copy duplicated the same model-visible
# text on hosts that consume both NDJSON shapes. The dashboard remains the
# human-facing full view.

ck_hash_text() {
  local value="$1" out=""
  out="$(printf '%s' "$value" | sha256sum 2>/dev/null | cut -d' ' -f1)"; [ -n "$out" ] && { printf '%s' "$out"; return; }
  out="$(printf '%s' "$value" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"; [ -n "$out" ] && { printf '%s' "$out"; return; }
  out="$(printf '%s' "$value" | md5sum 2>/dev/null | cut -d' ' -f1)"; [ -n "$out" ] && { printf '%s' "$out"; return; }
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-160
}

ck_context_cfg_value() { # <repo-root> <key>
  local repo="$1" key="$2" cfg
  cfg="$(ck_coord_toml "$repo")"
  [ -f "$cfg" ] || return 1
  awk -v want="$key" '
    /^[[:space:]]*\[/ {
      section=$0; sub(/^[[:space:]]*\[/,"",section); sub(/\].*$/,"",section)
      gsub(/[[:space:]]/,"",section); next
    }
    section == "context" {
      line=$0; sub(/[[:space:]]*#.*/,"",line)
      split(line,p,"="); k=p[1]; gsub(/[[:space:]]/,"",k)
      if (k == want) {
        sub(/^[^=]*=[[:space:]]*/,"",line); gsub(/^[[:space:]\"]+|[[:space:]\"]+$/,"",line)
        print line; exit
      }
    }
  ' "$cfg" 2>/dev/null
}

ck_context_mode() { # <repo-root>
  local repo="$1" value="${COORDKIT_CONTEXT_MODE:-}"
  case "$value" in quiet|compact|debug) printf '%s' "$value"; return ;; esac
  value="$(ck_context_cfg_value "$repo" mode 2>/dev/null || true)"
  case "$value" in quiet|compact|debug) printf '%s' "$value" ;; *) printf 'compact' ;; esac
}

ck_context_int() { # <repo-root> <env-name> <toml-key> <default> <minimum>
  local repo="$1" env_name="$2" key="$3" fallback="$4" minimum="$5" value
  value="${!env_name:-}"
  case "$value" in ''|*[!0-9]*) ;; *) [ "$value" -ge "$minimum" ] && { printf '%s' "$value"; return; } ;; esac
  value="$(ck_context_cfg_value "$repo" "$key" 2>/dev/null || true)"
  case "$value" in ''|*[!0-9]*) ;; *) [ "$value" -ge "$minimum" ] && { printf '%s' "$value"; return; } ;; esac
  printf '%s' "$fallback"
}

ck_context_metric() { # <root> <event> <bytes> <tokens> <suppressed> <reason> <max-bytes>
  local repo="$1" ev="$2" bytes="$3" tokens="$4" suppressed="$5" reason="$6" max_bytes="$7"
  local dir="${repo}/.coordkit-bus/metrics" file row size=0
  case "$max_bytes" in ''|*[!0-9]*) max_bytes=262144 ;; esac
  [ "$max_bytes" -lt 256 ] && max_bytes=256
  mkdir -p "$dir" 2>/dev/null || return 0
  file="${dir}/context.ndjson"
  row="$(jq -nc --argjson ts "$(date +%s)" --arg event "$ev" --arg host "$(ck_host)" \
    --argjson bytes "$bytes" --argjson tokens "$tokens" --argjson suppressed "$suppressed" --arg reason "$reason" \
    '{ts:$ts,event:$event,host:$host,bytes:$bytes,estimated_tokens:$tokens,suppressed:$suppressed,reason:$reason}' 2>/dev/null)" || return 0
  ( flock 9
    [ -f "$file" ] && size="$(wc -c < "$file" 2>/dev/null || printf '0')"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ $(( size + ${#row} + 1 )) -gt "$max_bytes" ] && [ -s "$file" ]; then
      mv -f "$file" "${file}.1" 2>/dev/null || true
    fi
    printf '%s\n' "$row" >> "$file" 2>/dev/null
  ) 9>"${file}.lock" 2>/dev/null
  return 0
}

ck_emit_context() {  # <hookEventName> [json_blob ...]
  local ev="$1" ctx="" blob part input_cwd input_sid repo mode ttl budget metrics_max_bytes bytes_per_token
  local candidates=0 suppressed=0 part_suppressed=0 reason="emitted" critical=0 bytes=0 tokens=0
  shift
  input_cwd="$(printf '%s' "${input:-}" | jq -r '.cwd // .workspace.current_dir // empty' 2>/dev/null)"
  [ -n "$input_cwd" ] || input_cwd="$(ck_project_dir)"
  repo="$(resolve_root "$input_cwd")"
  mode="$(ck_context_mode "$repo")"
  ttl="$(ck_context_int "$repo" COORDKIT_CONTEXT_REPEAT_TTL_SECONDS repeat_ttl_seconds 900 0)"
  metrics_max_bytes="$(ck_context_int "$repo" COORDKIT_CONTEXT_METRICS_MAX_BYTES metrics_max_bytes 262144 256)"
  bytes_per_token="$(ck_context_int "$repo" COORDKIT_CONTEXT_BYTES_PER_TOKEN bytes_per_token 4 1)"
  for blob in "$@"; do
    [ -n "$blob" ] || continue
    part="$(printf '%s' "$blob" | jq -r 'select(type=="object")
                                         | .hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
    [ -n "$part" ] || continue
    candidates=$(( candidates + 1 ))
    part_suppressed="$(printf '%s' "$blob" | jq -r '.coordkitMetrics.suppressed // 0' 2>/dev/null)"
    case "$part_suppressed" in ''|*[!0-9]*) part_suppressed=0 ;; esac
    suppressed=$(( suppressed + part_suppressed ))
    if [ "$mode" = "quiet" ]; then
      case "${part,,}" in *ck\ inbox*|*ck\ collision:*|*collision\ risk*|*deny*|*denied*) ;;
        *) suppressed=$(( suppressed + 1 )); continue ;;
      esac
    fi
    [ -n "$ctx" ] && ctx+=$'\n'
    ctx+="$part"
  done

  if [ -z "$ctx" ]; then
    ck_context_metric "$repo" "$ev" 0 0 "$suppressed" empty "$metrics_max_bytes"
    return 0
  fi

  case "${ctx,,}" in *ck\ collision:*|*collision\ risk*|*deny*|*denied*) critical=1 ;; esac

  case "$ev" in
    SessionStart)      budget="$(ck_context_int "$repo" COORDKIT_CONTEXT_SESSION_START_TOKENS session_start_tokens 600 32)" ;;
    UserPromptSubmit)  budget="$(ck_context_int "$repo" COORDKIT_CONTEXT_PROMPT_TOKENS prompt_tokens 250 32)" ;;
    *)                 budget="$(ck_context_int "$repo" COORDKIT_CONTEXT_COLLISION_TOKENS collision_tokens 120 32)" ;;
  esac
  local max_context_bytes prefix suffix prefix_bytes suffix_bytes head_bytes current_bytes
  max_context_bytes=$(( budget * bytes_per_token ))
  prefix=$'[coordkit]\n'; suffix=$'\n… compacted; use '"$(ck_digest_command)"$' for full context.'
  current_bytes="$(printf '%s%s' "$prefix" "$ctx" | wc -c | tr -d ' ')"
  case "$current_bytes" in ''|*[!0-9]*) current_bytes=0 ;; esac
  if [ "$current_bytes" -gt "$max_context_bytes" ]; then
    prefix_bytes="$(printf '%s' "$prefix" | wc -c | tr -d ' ')"
    suffix_bytes="$(printf '%s' "$suffix" | wc -c | tr -d ' ')"
    head_bytes=$(( max_context_bytes - prefix_bytes - suffix_bytes ))
    if [ "$head_bytes" -lt 0 ]; then
      ctx="$(ck_utf8_prefix_bytes "$ctx" "$(( max_context_bytes - prefix_bytes ))")"
    else
      ctx="$(ck_utf8_prefix_bytes "$ctx" "$head_bytes")${suffix}"
    fi
    suppressed=$(( suppressed + 1 )); reason="budget"
  fi
  ctx="${prefix}${ctx}"

  # Per-session/event exact-state dedupe. Volatile ages are intentionally not
  # rendered by bus.sh, making stable coordination state hash-identical.
  if [ "$mode" != "debug" ] && [ "$critical" -eq 0 ] && [ "$ttl" -gt 0 ]; then
    input_sid="$(printf '%s' "${input:-}" | jq -r '.session_id // empty' 2>/dev/null)"
    [ -n "$input_sid" ] || input_sid="$(ck_session_id)"
    local sid_key ev_key state_dir state_file digest prev_hash="" prev_ts=0 now_ts
    sid_key="$(ck_hash_text "$input_sid")"; ev_key="$(ck_hash_text "$ev")"
    state_dir="${repo}/.coordkit-bus/context-state/${sid_key}"; state_file="${state_dir}/${ev_key}.state"
    digest="$(ck_hash_text "$ctx")"; now_ts="$(date +%s)"
    if [ -f "$state_file" ]; then
      IFS=$'\t' read -r prev_hash prev_ts < "$state_file" || true
      case "$prev_ts" in ''|*[!0-9]*) prev_ts=0 ;; esac
    fi
    if [ "$prev_hash" = "$digest" ] && [ $(( now_ts - prev_ts )) -lt "$ttl" ]; then
      suppressed=$(( suppressed + 1 ))
      ck_context_metric "$repo" "$ev" 0 0 "$suppressed" duplicate "$metrics_max_bytes"
      return 0
    fi
    mkdir -p "$state_dir" 2>/dev/null
    printf '%s\t%s\n' "$digest" "$now_ts" > "${state_file}.tmp.$$" 2>/dev/null \
      && mv -f "${state_file}.tmp.$$" "$state_file" 2>/dev/null
  fi

  bytes="$(printf '%s' "$ctx" | wc -c | tr -d ' ')"; case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
  tokens=$(( (bytes + bytes_per_token - 1) / bytes_per_token ))
  ck_context_metric "$repo" "$ev" "$bytes" "$tokens" "$suppressed" "$reason" "$metrics_max_bytes"
  printf '{"hookSpecificOutput":{"hookEventName":%s,"additionalContext":%s}}\n' \
    "$(printf '%s' "$ev" | jq -Rs .)" "$(printf '%s' "$ctx" | jq -Rs .)"
}

event="${1:-}"
input="$(cat)"

ck_refresh_agent_catalog() {
  local runtime="${CK_ROOT}/scripts/agent-runtime.py" output agents_dir error_file
  local error_tmp message generated_at
  output="$(ck_data_dir)/agents/catalog.json"
  agents_dir="${COORDKIT_AGENT_DIR:-${CK_ROOT}/agents}"
  error_file="$(dirname "$output")/catalog.error.json"
  mkdir -p "$(dirname "$output")" 2>/dev/null || return 0
  error_tmp="$(mktemp "${TMPDIR:-/tmp}/coordkit-agent-catalog.XXXXXX" 2>/dev/null || true)"
  [ -n "$error_tmp" ] || return 0

  if command -v python3 >/dev/null 2>&1 && [ -f "$runtime" ] \
    && python3 "$runtime" --agents-dir "$agents_dir" compile --output "$output" \
      >/dev/null 2>"$error_tmp"; then
    rm -f "$error_file" "$error_tmp" 2>/dev/null || true
    return 0
  fi

  message="$(tr '\n' ' ' < "$error_tmp" 2>/dev/null | cut -c1-400)"
  [ -n "$message" ] || message="python3 or the agent runtime is unavailable"
  generated_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
  rm -f "$output" 2>/dev/null || true
  jq -nc --arg generated_at "$generated_at" --arg message "$message" \
    '{valid:false,generated_at:$generated_at,message:$message}' \
    > "${error_file}.tmp.$$" 2>/dev/null \
    && mv -f "${error_file}.tmp.$$" "$error_file" 2>/dev/null
  rm -f "$error_tmp" "${error_file}.tmp.$$" 2>/dev/null || true
  jq -nc --arg context \
    "[coordkit agents] catalog unavailable; stale catalog removed: ${message}. Run cobus agents validate." \
    '{hookSpecificOutput:{additionalContext:$context}}' 2>/dev/null || true
}

case "$event" in
  session-start)
    # statusline_drift_note is read-only and usually silent: it speaks up only
    # when the installed statusline wrapper can no longer find bus.sh, i.e. the
    # badge is already showing its not-found warning.
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-hook.XXXXXX" 2>/dev/null || true)"
    if [ -n "$tmpdir" ]; then
      bus_out="${tmpdir}/bus"
      ledger_out="${tmpdir}/ledger"
      catalog_out="${tmpdir}/catalog"
      ck_refresh_agent_catalog >"$catalog_out" & catalog_pid=$!
      bus_run start <<<"$input" >"$bus_out" & bus_pid=$!
      ledger_run start <<<"$input" >"$ledger_out" & ledger_pid=$!
      wait "$bus_pid" 2>/dev/null || true
      wait "$ledger_pid" 2>/dev/null || true
      wait "$catalog_pid" 2>/dev/null || true
      ck_emit_context SessionStart \
        "$(cat "$bus_out" 2>/dev/null)" \
        "$(cat "$ledger_out" 2>/dev/null)" \
        "$(cat "$catalog_out" 2>/dev/null; statusline_drift_note)"
      rm -rf "$tmpdir" 2>/dev/null || true
    else
      catalog_note="$(ck_refresh_agent_catalog)"
      ck_emit_context SessionStart \
        "$(bus_run    start <<<"$input")" \
        "$(ledger_run start <<<"$input")" \
        "$(printf '%s\n' "$catalog_note"; statusline_drift_note)"
    fi
    ;;

  prompt-submit)
    # guard_driftreport takes the hook JSON as a direct arg (like guard_check
    # below), not via stdin like bus_run/ledger_run — and, unlike guard_check,
    # it is ALWAYS ON: it never consults ck_enforcement_mode(), so it fires in
    # coordkit's default "warn" mode too. See its header comment in guard.sh.
    tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-hook.XXXXXX" 2>/dev/null || true)"
    if [ -n "$tmpdir" ]; then
      bus_out="${tmpdir}/bus"
      ledger_out="${tmpdir}/ledger"
      guard_out="${tmpdir}/guard"
      bus_run task <<<"$input" >"$bus_out" & bus_pid=$!
      ledger_run prompt <<<"$input" >"$ledger_out" & ledger_pid=$!
      guard_driftreport "$input" >"$guard_out" & guard_pid=$!
      wait "$bus_pid" 2>/dev/null || true
      wait "$ledger_pid" 2>/dev/null || true
      wait "$guard_pid" 2>/dev/null || true
      ck_emit_context UserPromptSubmit \
        "$(cat "$bus_out" 2>/dev/null)" \
        "$(cat "$ledger_out" 2>/dev/null)" \
        "$(cat "$guard_out" 2>/dev/null)"
      rm -rf "$tmpdir" 2>/dev/null || true
    else
      ck_emit_context UserPromptSubmit \
        "$(bus_run    task   <<<"$input")" \
        "$(ledger_run prompt <<<"$input")" \
        "$(guard_driftreport "$input")"
    fi
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
    bus_run record <<<"$input" >/dev/null & bus_pid=$!
    guard_record "$input" >/dev/null & guard_pid=$!
    wait "$bus_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true
    ;;

  posttool-bash)
    bus_run record <<<"$input" >/dev/null & bus_pid=$!
    guard_absorb "$input" >/dev/null & guard_pid=$!
    wait "$bus_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true
    ;;

  posttool-task)
    bus_run subagent-stop <<<"$input"
    ;;

  session-end)
    bus_run stop <<<"$input" >/dev/null & bus_pid=$!
    guard_cleanup "$input" >/dev/null & guard_pid=$!
    wait "$bus_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true
    ;;

  *)
    # Unknown event: do nothing, successfully.
    ;;
esac

exit 0
