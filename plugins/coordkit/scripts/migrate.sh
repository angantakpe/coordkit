#!/usr/bin/env bash
# migrate.sh — `coordkit migrate`. APPENDS a one-time schema-upgrade marker to
# the active log and ensures a MANIFEST.json is present. NEVER rewrites or
# deletes existing lines (so a union-merge between a migrated and an
# un-migrated clone stays safe — dedup is by eid). Idempotent: re-running is a
# no-op once the marker for the current epoch exists.
set -uo pipefail

ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}"
SCHEMA_DIR="${ROOT}/schema"

resolve_root() {
  local cwd="${CLAUDE_PROJECT_DIR:-$PWD}" dir
  if [ -n "${CLAUDE_BUS_ROOT:-}" ]; then printf '%s' "$CLAUDE_BUS_ROOT"; return; fi
  local top; top="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
  [ -n "$top" ] && { printf '%s' "$top"; return; }
  dir="$cwd"
  while [ -n "$dir" ] && [ "$dir" != "/" ]; do
    [ -d "$dir/.claude-bus" ] && { printf '%s' "$dir"; return; }
    dir="$(dirname "$dir")"
  done
  printf '%s' "$cwd"
}

repo="$(resolve_root)"
bus="${repo}/.claude-bus"
ledger="${bus}/ledger.jsonl"
lock="${bus}/.ledger.lock"
mkdir -p "$bus" 2>/dev/null || { echo "coordkit migrate: cannot create $bus" >&2; exit 1; }
[ -f "$ledger" ] || : > "$ledger"

# ensure a committed-style MANIFEST mirror is available next to the log
if [ -f "${SCHEMA_DIR}/MANIFEST.json" ]; then
  cp -n "${SCHEMA_DIR}/MANIFEST.json" "${bus}/MANIFEST.json" 2>/dev/null || true
fi
epoch="$(jq -r '.compaction_epoch // 0' "${SCHEMA_DIR}/MANIFEST.json" 2>/dev/null || echo 0)"

# idempotency: already marked for this epoch?
if grep -q "\"type\":\"schema-upgrade\"" "$ledger" 2>/dev/null && \
   jq -e --argjson e "$epoch" 'select(.type=="schema-upgrade" and (.epoch==$e))' "$ledger" >/dev/null 2>&1; then
  echo "coordkit migrate: already migrated (epoch $epoch). No-op."
  exit 0
fi

ts="$(date +%s)"
( flock 9
  jq -nc --argjson ts "$ts" --argjson epoch "$epoch" --arg sv "2.0" \
    '{schema_version:$sv, type:"schema-upgrade", subject:"_schema", epoch:$epoch, ts:$ts, body:"coordkit v2 envelope active"}' \
    >> "$ledger" 2>/dev/null
) 9>"$lock"

echo "coordkit migrate: appended schema-upgrade marker (epoch $epoch) to $ledger"
echo "  (existing lines untouched; readers up-convert v1 on read)"
exit 0
