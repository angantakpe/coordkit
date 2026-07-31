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

# The LogStore dispatcher. migrate MUST write through the same four public functions
# every other writer uses — hardcoding <repo>/.coordkit-bus/ledger.jsonl would, under
# mode=git, drop the marker into a file nobody reads (the active log lives at
# .claude/coord/log/), so the idempotency check below would report "not migrated"
# forever and a later switch back to local mode would find a stray duplicate.
LIB="${ROOT}/transports/lib.sh"
[ -f "$LIB" ] || { echo "coordkit migrate: transport library missing at $LIB" >&2; exit 1; }
# shellcheck source=../transports/lib.sh
. "$LIB"

repo="$(resolve_root "$PWD")"
bus="${repo}/.coordkit-bus"
mode="$(logstore_mode)"
# The bus dir is still where the MANIFEST mirror and migrate's own seq-allocation
# lock live; it is NOT the append target any more — logstore_append picks that.
mkdir -p "$bus" 2>/dev/null || { echo "coordkit migrate: cannot create $bus" >&2; exit 1; }
lock="${bus}/.ledger.lock.seq"

# ensure a committed-style MANIFEST mirror is available next to the log
if [ -f "${SCHEMA_DIR}/MANIFEST.json" ]; then
  cp -n "${SCHEMA_DIR}/MANIFEST.json" "${bus}/MANIFEST.json" 2>/dev/null || true
fi

# Read the union. logstore_readall's EXIT STATUS is not meaningful — local.sh's
# __local_readall ends in `[ -f <legacy ledger> ] && awk 1 …`, so it reports failure
# whenever the legacy flat ledger is simply absent — and this script runs with
# `set -o pipefail`, which would otherwise turn that into a failed check. Its stdout
# is what matters, so normalise the status here once.
mig_readall() { logstore_readall 2>/dev/null || true; }

# robust max seq — same intent as ledger.sh's max_seq (a corrupt / seq-less line can
# never reset the sequence to 0, which would blind every downstream `select(.seq > N)`
# cursor), but computed over the logstore UNION rather than one physical file, so it
# accounts for every actor's segments in whichever mode is active.
mig_max_seq() {
  mig_readall \
    | jq -Rrn '[inputs | fromjson? | .seq? | numbers] | max // 0' 2>/dev/null || echo 0
}
epoch="$(jq -r '.compaction_epoch // 0' "${SCHEMA_DIR}/MANIFEST.json" 2>/dev/null || echo 0)"
case "$epoch" in ''|*[!0-9]*) epoch=0 ;; esac

# idempotency: already marked for this epoch? The marker is a `note` tagged
# "schema-upgrade" (a schema-valid type), so detect by tag+epoch. Also tolerate a
# legacy marker (type=="schema-upgrade") so re-running over an old ledger stays a
# no-op instead of double-marking. Scanned over logstore_readall — which in local mode
# still folds in the legacy flat ledger.jsonl, so a marker written by an older migrate
# is still found. `fromjson?` skips unparseable legacy lines instead of aborting the
# scan on them (which would have silently double-marked).
if mig_readall | jq -e -Rrn --argjson e "$epoch" '
     [ inputs
       | fromjson?
       | select(type == "object")
       | select(((((.tags // []) | index("schema-upgrade")) != null) or (.type == "schema-upgrade"))
                and (.epoch == $e)) ]
     | length > 0' >/dev/null 2>&1; then
  echo "coordkit migrate: already migrated (epoch $epoch, mode $mode). No-op."
  exit 0
fi

# Allocate seq = max+1 under a DEDICATED lock (fd 7 on .ledger.lock.seq — the same
# file ledger.sh's logstore-mode append_event uses), then append via logstore_append,
# which takes the transport's OWN append lock. Two different lock files can never
# deadlock: this one orders seq allocation, the transport's orders the byte-append.
# The marker is a fully schema-conformant v2 line (note + schema_version + eid + id +
# actor + clock), tagged "schema-upgrade" and carrying the epoch for idempotence.
( flock 7
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
  line="$(printf '%s' "$base" | jq -c --arg eid "$eid" '.eid=$eid' 2>/dev/null)"
  [ -n "$line" ] || { echo "coordkit migrate: could not build the marker event" >&2; exit 1; }
  logstore_append "$line" || { echo "coordkit migrate: append failed" >&2; exit 1; }
) 7>"$lock" || exit 1

echo "coordkit migrate: appended schema-upgrade marker (epoch $epoch) to the active log (mode $mode)"
echo "  (existing lines untouched; v1 lines are read verbatim, no on-read rewrite)"
exit 0
