#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="${ROOT}/plugins/coordkit/templates/coord.toml"

python3 - "$TEMPLATE" <<'PY'
import pathlib
import sys
import tomllib

config = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
expected = {
    "mode": "compact",
    "session_start_tokens": 160,
    "prompt_tokens": 96,
    "collision_tokens": 64,
    "bytes_per_token": 4,
    "max_tasks": 2,
    "max_decisions": 1,
    "max_questions": 1,
    "max_events": 3,
    "max_messages": 2,
    "max_peers": 1,
    "event_body_chars": 80,
    "repeat_ttl_seconds": 3600,
    "metrics_max_bytes": 262144,
    "skill_top_k": 1,
}
assert config.get("context") == expected, config.get("context")
PY

docs="$(printf '%s\n' \
  "$ROOT/README.md" \
  "$ROOT/docs/BUS.md" \
  "$ROOT/docs/LEDGER.md" \
  "$ROOT/docs/HOSTS.md" \
  "$ROOT/plugins/coordkit/adapters/codex/README.md" \
  "$ROOT/plugins/coordkit/skills/coordkit/SKILL.md")"

require_doc() {
  local pattern="$1"
  if ! xargs grep -Fq -- "$pattern" <<<"$docs"; then
    printf 'missing context documentation: %s\n' "$pattern" >&2
    exit 1
  fi
}

for mode in quiet compact debug; do require_doc "$mode"; done
for env in \
  COORDKIT_CONTEXT_MODE \
  COORDKIT_CONTEXT_SESSION_START_TOKENS \
  COORDKIT_CONTEXT_PROMPT_TOKENS \
  COORDKIT_CONTEXT_COLLISION_TOKENS \
  COORDKIT_CONTEXT_BYTES_PER_TOKEN \
  COORDKIT_CONTEXT_MAX_TASKS \
  COORDKIT_CONTEXT_MAX_DECISIONS \
  COORDKIT_CONTEXT_MAX_QUESTIONS \
  COORDKIT_CONTEXT_MAX_EVENTS \
  COORDKIT_CONTEXT_MAX_MESSAGES \
  COORDKIT_CONTEXT_MAX_PEERS \
  COORDKIT_CONTEXT_EVENT_BODY_CHARS \
  COORDKIT_CONTEXT_REPEAT_TTL_SECONDS \
  COORDKIT_CONTEXT_METRICS_MAX_BYTES \
  COORDKIT_CONTEXT_SKILL_TOP_K; do
  require_doc "$env"
done

require_doc '$coordkit'
require_doc 'cobus digest'
require_doc 'does not consume model tokens'
require_doc '.coordkit-bus/metrics/context.ndjson'

echo "context config contract: ok"
