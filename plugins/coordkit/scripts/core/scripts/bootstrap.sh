#!/usr/bin/env bash
# bootstrap.sh — OPTIONAL / MANUAL helper (kept for CLI use, e.g. `coordkit
# bootstrap`). It is NOT wired into any hook: the ledger is self-bootstrapping —
# ledger.sh's ensure_site() performs this same idempotent work on its init
# path, so a stable actor id is materialized on first ledger touch. Run this by
# hand only if you want to seed the site identity ahead of any ledger activity.
# Ensures a STABLE per-(machine+user+clone) actor/site identity exists in the
# persistent plugin data dir. No-op if already set. NEVER blocks: always exits 0.
set -uo pipefail

# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}/scripts/common.sh" || exit 0

SITE="$(ck_data_dir)/site.json"

if [ -s "$SITE" ] && jq -e '.actor' "$SITE" >/dev/null 2>&1; then
  exit 0   # already bootstrapped
fi

# ck_ensure_site() derives the stable actor id from host+user+home (NOT cwd —
# one identity per machine/user) and persists it. Same helper ledger.sh
# calls on its self-bootstrapping path, so both agree by construction.
ck_ensure_site

# emit nothing to stdout on the hook path (avoid polluting context); a CLI caller sees it on stderr
actor="$(jq -r '.actor // empty' "$SITE" 2>/dev/null)"
[ -n "$actor" ] && printf 'coordkit: bootstrapped actor %s\n' "$actor" >&2 2>/dev/null
exit 0
