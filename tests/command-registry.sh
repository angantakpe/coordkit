#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

printf 'command registry: ok\n'
