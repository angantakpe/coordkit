#!/usr/bin/env bash
# bootstrap.sh — run once per session (SessionStart, before the bus/ledger hooks
# or by them). Ensures a STABLE per-(machine+user+clone) actor/site identity
# exists in the persistent plugin data dir. No-op if already set. NEVER blocks:
# always exits 0 so it can't wedge a session.
set -uo pipefail

DATA="${COORDKIT_DATA:-${CLAUDE_PLUGIN_DATA:-$HOME/.claude/coordkit-data}}"
SITE="${DATA}/site.json"

mkdir -p "$DATA" 2>/dev/null || exit 0

if [ -s "$SITE" ] && jq -e '.actor' "$SITE" >/dev/null 2>&1; then
  exit 0   # already bootstrapped
fi

# derive a stable actor id from host+user+home (NOT cwd — one identity per machine/user)
seed="${HOSTNAME:-$(hostname 2>/dev/null || echo host)}-${USER:-$(id -un 2>/dev/null || echo user)}-${HOME:-/}"
if command -v b3sum >/dev/null 2>&1; then
  digest="$(printf '%s' "$seed" | b3sum 2>/dev/null | cut -c1-8)"
else
  digest="$(printf '%s' "$seed" | sha256sum 2>/dev/null | cut -c1-8)"
fi
actor="site-${digest:-00000000}"

jq -nc --arg actor "$actor" --arg user "${USER:-}" --arg host "${HOSTNAME:-}" \
  '{actor:$actor, user:$user, host:$host}' > "$SITE" 2>/dev/null || exit 0

# emit nothing to stdout on the hook path (avoid polluting context); a CLI caller sees it on stderr
printf 'coordkit: bootstrapped actor %s\n' "$actor" >&2 2>/dev/null || true
exit 0
