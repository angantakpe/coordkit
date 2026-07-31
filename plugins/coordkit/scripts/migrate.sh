#!/usr/bin/env bash
# migrate.sh — `coordkit migrate`. APPENDS a one-time schema-upgrade marker to
# the active log and ensures a MANIFEST.json is present. NEVER rewrites or
# deletes existing lines (so a union-merge between a migrated and an
# un-migrated clone stays safe — dedup is by eid). Idempotent: re-running is a
# no-op once the marker for the current epoch exists.
set -uo pipefail

# resolve_root() / ck_actor() / ck_clock_c() come from the shared library, so
# migrate resolves the same repo and mints the same actor id as the ledger.
# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh"

ROOT="$(ck_plugin_root)"
SCHEMA_DIR="${ROOT}/schema"

repo="$(resolve_root "$PWD")"
bus="${repo}/.coordkit-bus"
ledger="${bus}/ledger.jsonl"
lock="${bus}/.ledger.lock"
mkdir -p "$bus" 2>/dev/null || { echo "coordkit migrate: cannot create $bus" >&2; exit 1; }
[ -f "$ledger" ] || : > "$ledger"

# ensure a committed-style MANIFEST mirror is available next to the log
if [ -f "${SCHEMA_DIR}/MANIFEST.json" ]; then
  cp -n "${SCHEMA_DIR}/MANIFEST.json" "${bus}/MANIFEST.json" 2>/dev/null || true
fi

# robust max seq — mirrors ledger.sh's max_seq so a corrupt / seq-less
# LAST line can never reset the sequence to 0 (which would blind every downstream
# `select(.seq > N)` cursor).
mig_max_seq() {
  [ -s "$ledger" ] || { echo 0; return; }
  local last
  last="$(tail -n1 "$ledger" 2>/dev/null | jq -r '.seq // empty' 2>/dev/null)"
  case "$last" in
    ''|*[!0-9]*) : ;;
    *) printf '%s' "$last"; return ;;
  esac
  jq -Rrn '[inputs | fromjson? | .seq? | numbers] | max // 0' "$ledger" 2>/dev/null || echo 0
}
epoch="$(jq -r '.compaction_epoch // 0' "${SCHEMA_DIR}/MANIFEST.json" 2>/dev/null || echo 0)"
case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac

# idempotency: already marked for this epoch? The marker is now a `note` tagged
# "schema-upgrade" (a schema-valid type), so detect by tag+epoch. Also tolerate a
# legacy marker (type=="schema-upgrade") so re-running over an old ledger stays a
# no-op instead of double-marking.
if grep -q "schema-upgrade" "$ledger" 2>/dev/null && \
   jq -e --argjson e "$epoch" \
     'select((((.tags // []) | index("schema-upgrade")) or (.type=="schema-upgrade")) and (.epoch==$e))' \
     "$ledger" >/dev/null 2>&1; then
  echo "coordkit migrate: already migrated (epoch $epoch). No-op."
  exit 0
fi

# Allocate seq = max+1 and append under the SAME lock discipline ledger.sh's
# direct-mode append_event uses (flock on .ledger.lock, fd 9), so a concurrent
# migrate and a concurrent event can't mint the same seq. The marker is a fully
# schema-conformant v2 line (note + schema_version + eid + id + actor + clock),
# tagged "schema-upgrade" and carrying the epoch for idempotence.
( flock 9
  seq="$(mig_max_seq)"; case "$seq" in ''|*[!0-9]*) seq=0 ;; esac; seq=$(( seq + 1 ))
  ts="$(date +%s)"
  actor="$(ck_actor)"
  p="$(date +%s%3N 2>/dev/null)"; case "$p" in *[!0-9]*|'') p="$(( ts * 1000 ))";; esac
  c="$(ck_clock_c)"; case "$c" in ''|*[!0-9]*) c=1 ;; esac
  id="$(printf '%x%04x' "$ts" "$(( ${RANDOM:-0} ))")"
  hasher="sha256"; hcmd="sha256sum"
  command -v b3sum >/dev/null 2>&1 && { hasher="blake3"; hcmd="b3sum"; }
  base="$(jq -nc \
    --arg sv "2.0" --arg actor "$actor" --argjson p "$p" --argjson c "$c" --argjson seq "$seq" \
    --argjson ts "$ts" --arg id "$id" --argjson epoch "$epoch" \
    '{schema_version:$sv,eid:"",id:$id,actor:$actor,clock:{p:$p,c:$c},seq:$seq,ts:$ts,type:"note",subject:"_schema",body:"coordkit v2 envelope active",refs:[],tags:["schema-upgrade"],epoch:$epoch,lease:null,supersedes:null,sig:null}' 2>/dev/null)"
  eid="${hasher}:$(printf '%s' "$base" | jq -Sc 'del(.eid,.sig)' 2>/dev/null | "$hcmd" 2>/dev/null | cut -d' ' -f1 | cut -c1-32)"
  printf '%s' "$base" | jq -c --arg eid "$eid" '.eid=$eid' 2>/dev/null >> "$ledger"
) 9>"$lock"

echo "coordkit migrate: appended schema-upgrade marker (epoch $epoch) to $ledger"
echo "  (existing lines untouched; v1 lines are read verbatim, no on-read rewrite)"
exit 0
