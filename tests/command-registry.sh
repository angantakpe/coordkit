#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/coordkit-command-registry.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# shellcheck source=../plugins/coordkit/scripts/common.sh
. "${ROOT}/plugins/coordkit/scripts/common.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [ "$expected" != "$actual" ]; then
    printf 'FAIL %s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_eq "/bus" "$(ck_command_surface dashboard claude-code)" "claude dashboard"
assert_eq "\$coordkit" "$(ck_command_surface context codex)" "codex context"
assert_eq "cobus digest" "$(ck_command_surface context cli)" "cli context"
assert_eq "cobus msg" "$(ck_command_surface message cli)" "cli message"

dashboard_help="$(bash "${ROOT}/plugins/coordkit/scripts/command-registry.sh" describe claude-code dashboard)"
[ -n "$dashboard_help" ]

# The CLI command catalog advertises `cobus msg`; prove that the public CLI
# reaches the bus inbox rather than being forwarded to the ledger command set.
repo="$tmp/repo"
mkdir -p "$repo/.coordkit-bus/agents"
git -C "$repo" init -q
target_sid="target-session-1234"
jq -nc \
  --arg sid "$target_sid" \
  --argjson last_seen "$(date +%s)" \
  '{sid:$sid,last_seen:$last_seen,branch:"main",host:"codex"}' \
  > "$repo/.coordkit-bus/agents/${target_sid}.json"
message='literal $HOME `not-run` * "quotes" & spaces'
COORDKIT_PLUGIN_ROOT="$ROOT/plugins/coordkit" \
  COORDKIT_PROJECT_DIR="$repo" COORDKIT_BUS_ROOT="$repo" COORDKIT_HOST=cli \
  "$ROOT/plugins/coordkit/bin/cobus" msg target-session "$message" >/dev/null
mapfile -t inbox_files < <(find "$repo/.coordkit-bus/inbox/$target_sid" -maxdepth 1 -type f -name '*.msg')
assert_eq "1" "${#inbox_files[@]}" "cli message delivery count"
inbox_line="$(<"${inbox_files[0]}")"
delivered_text="${inbox_line: -${#message}}"
assert_eq "$message" "$delivered_text" "cli message literal text"

set +e
missing_output="$(COORDKIT_PLUGIN_ROOT="$ROOT/plugins/coordkit" \
  COORDKIT_PROJECT_DIR="$repo" COORDKIT_BUS_ROOT="$repo" COORDKIT_HOST=cli \
  "$ROOT/plugins/coordkit/bin/cobus" msg missing-session "unmatched" 2>&1)"
missing_rc=$?
set -e
assert_eq "1" "$missing_rc" "cli missing recipient status"
printf '%s\n' "$missing_output" | grep -q 'live instance(s) found, none matched "missing-session"'

printf 'command registry: ok\n'
