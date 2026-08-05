#!/usr/bin/env bash
# skillkit — skill auto-activation engine (UserPromptSubmit hook)
#
# Ported from claude-code-infrastructure-showcase's skill-activation-prompt.ts
# (npx tsx per prompt) to dependency-free bash+jq, and extended with layered
# rules resolution:
#
#   1. global   ~/.claude/skills/skill-rules.json
#   2. project  <resolved-repo>/.claude/skills/skill-rules.json
#
# Both files use the same schema; a project entry overrides the global entry
# of the same skill name. Matching is suggest-only: stdout is injected as
# context for the turn. This hook never blocks anything (coordkit's WARN-only
# philosophy).
#
# skill-rules.json shape (per skill):
#   {
#     "skills": {
#       "<skill-name-as-invocable-by-Skill-tool>": {
#         "type": "domain" | "guardrail",
#         "enforcement": "suggest",           # reserved; v1 is suggest-only
#         "priority": "critical|high|medium|low",
#         "description": "...",
#         "promptTriggers": {
#           "keywords": ["substring", ...],           # case-insensitive
#           "intentPatterns": ["regex", ...]          # case-insensitive
#         }
#       }
#     }
#   }
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

SCRIPT_ROOT="${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}"
# shellcheck source=./common.sh
. "${SCRIPT_ROOT}/scripts/common.sh" 2>/dev/null || exit 0

input=$(cat) || exit 0
prompt=$(jq -r '.prompt // empty' <<<"$input" 2>/dev/null) || exit 0
[[ -z "$prompt" ]] && exit 0
# Slash commands already name their skill — nothing to suggest.
[[ "$prompt" == /* ]] && exit 0

prompt_lc="${prompt,,}"

cwd="$(jq -r '.cwd // .workspace.current_dir // empty' <<<"$input" 2>/dev/null)"
[[ -n "$cwd" ]] || cwd="$(ck_project_dir)"
repo="$(resolve_root "$cwd")"
sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null)"
[[ -n "$sid" ]] || sid="$(ck_session_id)"

cfg_value() { # <key>
  local key="$1" cfg; cfg="$(ck_coord_toml "$repo")"
  [[ -f "$cfg" ]] || return 1
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

mode_value() {
  local value="${COORDKIT_CONTEXT_MODE:-}"
  case "$value" in quiet|compact|debug) printf '%s' "$value"; return ;; esac
  value="$(cfg_value mode 2>/dev/null || true)"
  case "$value" in quiet|compact|debug) printf '%s' "$value" ;; *) printf 'compact' ;; esac
}

int_value() { # <env-name> <key> <default> <minimum>
  local env_name="$1" key="$2" fallback="$3" minimum="$4" value
  value="${!env_name:-}"
  case "$value" in ''|*[!0-9]*) ;; *) [[ "$value" -ge "$minimum" ]] && { printf '%s' "$value"; return; } ;; esac
  value="$(cfg_value "$key" 2>/dev/null || true)"
  case "$value" in ''|*[!0-9]*) ;; *) [[ "$value" -ge "$minimum" ]] && { printf '%s' "$value"; return; } ;; esac
  printf '%s' "$fallback"
}

hash_text() {
  local value="$1" out=""
  out="$(printf '%s' "$value" | sha256sum 2>/dev/null | cut -d' ' -f1)"; [[ -n "$out" ]] && { printf '%s' "$out"; return; }
  out="$(printf '%s' "$value" | shasum -a 256 2>/dev/null | cut -d' ' -f1)"; [[ -n "$out" ]] && { printf '%s' "$out"; return; }
  printf '%s' "$value" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-160
}

metric() { # <bytes> <tokens> <suppressed> <reason>
  local bytes="$1" tokens="$2" suppressed="$3" reason="$4"
  local max_bytes dir file row size=0
  max_bytes="$(int_value COORDKIT_CONTEXT_METRICS_MAX_BYTES metrics_max_bytes 262144 256)"
  dir="${repo}/.coordkit-bus/metrics"; file="${dir}/context.ndjson"
  mkdir -p "$dir" 2>/dev/null || return 0
  [[ -f "${repo}/.coordkit-bus/.gitignore" ]] || printf '*\n' > "${repo}/.coordkit-bus/.gitignore" 2>/dev/null
  row="$(jq -nc --argjson ts "$(date +%s)" --arg event SkillActivation --arg host "$(ck_host)" \
    --argjson bytes "$bytes" --argjson tokens "$tokens" --argjson suppressed "$suppressed" --arg reason "$reason" \
    '{ts:$ts,event:$event,host:$host,bytes:$bytes,estimated_tokens:$tokens,suppressed:$suppressed,reason:$reason}' 2>/dev/null)" || return 0
  ( flock 9
    [[ -f "$file" ]] && size="$(wc -c < "$file" 2>/dev/null || printf '0')"
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [[ $(( size + ${#row} + 1 )) -gt "$max_bytes" && -s "$file" ]]; then mv -f "$file" "${file}.1" 2>/dev/null || true; fi
    printf '%s\n' "$row" >> "$file" 2>/dev/null
  ) 9>"${file}.lock" 2>/dev/null
  return 0
}

mode="$(mode_value)"
ttl="$(int_value COORDKIT_CONTEXT_REPEAT_TTL_SECONDS repeat_ttl_seconds 3600 0)"
top_k="$(int_value COORDKIT_CONTEXT_SKILL_TOP_K skill_top_k 1 1)"

global_rules="${HOME}/.claude/skills/skill-rules.json"
project_rules="${repo}/.claude/skills/skill-rules.json"

files=()
[[ -f "$global_rules" ]] && files+=("$global_rules")
[[ -f "$project_rules" && "$project_rules" != "$global_rules" ]] && files+=("$project_rules")
[[ ${#files[@]} -eq 0 ]] && exit 0

matches="$(jq -rs --arg p "$prompt_lc" '
  (map(.skills // {}) | add // {}) as $skills
  | [ $skills | to_entries[]
      | select(
          ((.value.promptTriggers.keywords // [])
            | any(. as $kw | ($p | contains($kw | ascii_downcase))))
          or
          ((.value.promptTriggers.intentPatterns // [])
            | any(. as $re | (try ($p | test($re; "i")) catch false)))
        )
      | {name: .key, priority: (.value.priority // "medium")}
    ]
  | def rank: if .priority == "critical" then 0 elif .priority == "high" then 1 elif .priority == "medium" then 2 else 3 end;
    sort_by(rank, .name)[] | [.name, .priority] | @tsv
' "${files[@]}" 2>/dev/null)"

[[ -n "$matches" ]] || { metric 0 0 0 no-match; exit 0; }
total="$(printf '%s\n' "$matches" | awk 'NF{n++} END{print n+0}')"
if [[ "$mode" == quiet ]]; then metric 0 0 "$total" quiet; exit 0; fi

state_dir="${repo}/.coordkit-bus/context-state/skills/$(hash_text "$sid")"
mkdir -p "$state_dir" 2>/dev/null
selected=(); selected_priorities=(); seen=0; eligible=0; now_ts="$(date +%s)"
while IFS=$'\t' read -r name priority; do
  [[ -n "$name" ]] || continue
  marker="${state_dir}/$(hash_text "$name").seen"
  if [[ "$mode" != debug && "$ttl" -gt 0 && -f "$marker" ]]; then
    seen_ts="$(cat "$marker" 2>/dev/null || printf '0')"
    case "$seen_ts" in ''|*[!0-9]*) seen_ts=0 ;; esac
    if [[ $(( now_ts - seen_ts )) -lt "$ttl" ]]; then seen=$(( seen + 1 )); continue; fi
  fi
  eligible=$(( eligible + 1 ))
  [[ "${#selected[@]}" -ge "$top_k" ]] && continue
  selected+=("$name"); selected_priorities+=("$priority")
  [[ "$mode" == debug || "$ttl" -eq 0 ]] || { printf '%s\n' "$now_ts" > "${marker}.tmp.$$" 2>/dev/null && mv -f "${marker}.tmp.$$" "$marker" 2>/dev/null; }
done <<< "$matches"

if [[ "${#selected[@]}" -eq 0 ]]; then metric 0 0 "$seen" duplicate; exit 0; fi

rendered=""
for i in "${!selected[@]}"; do
  label="${selected[$i]}"
  [[ "${selected_priorities[$i]}" == critical ]] && label+="!"
  rendered+="${rendered:+, }${label}"
done
out="CK skills: ${rendered} — invoke matching skill(s) before responding."
bytes="$(printf '%s' "$out" | wc -c | tr -d ' ')"; tokens=$(( (bytes + 3) / 4 ))
overflow=$(( eligible - ${#selected[@]} )); suppressed=$(( seen + overflow ))
metric "$bytes" "$tokens" "$suppressed" emitted
printf '%s\n' "$out"

exit 0
