#!/usr/bin/env bash
# deprecated-notice.sh — the whole of coordguard 2.0.0.
#
# The anti-clobber guard moved into coordkit >=3.0.0 as an opt-in mode. This
# plugin installs no enforcement hooks any more; it only tells the session
# where the guard went, once per SessionStart.
set -uo pipefail

msg="⚠️  coordguard is deprecated. Its enforcement was merged into coordkit >=3.0.0.
Run /guard on to enable hard anti-clobber blocking there; this plugin now does nothing else.
You can uninstall coordguard once you've switched."

if command -v jq >/dev/null 2>&1; then
  enc="$(printf '%s' "$msg" | jq -Rs .)"
else
  enc="$(printf '%s' "$msg" | tr '\n' ' ')"
  enc="\"${enc//\"/\\\"}\""
fi

printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$enc"
exit 0
