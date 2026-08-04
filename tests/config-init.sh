#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN="${ROOT}/plugins/coordkit"
tmp="$(mktemp -d /tmp/coordkit-config-test.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
git -C "$tmp" init -q

COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PROJECT_DIR="$tmp" \
  bash "$PLUGIN/scripts/init-relay.sh" https://relay.example/v1/events short-room >/dev/null
toml="$tmp/.claude/coord/coord.toml"
test "$(sed -n '/^[[:space:]]*\[/q; /^[[:space:]]*mode[[:space:]]*=/p' "$toml")" = 'mode = "relay"'
grep -q '^room_id = "short-room"$' "$toml"
grep -q '^relay_url = "https://relay.example/v1/events"$' "$toml"
test "$(sed -n '/^\[enforcement\]/,/^\[/p' "$toml" | sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p')" = '"warn"'
test "$(sed -n '/^\[context\]/,/^\[/p' "$toml" | sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p')" = '"compact"'
! grep -q 'COORDKIT_RELAY_TOKEN[[:space:]]*=' "$toml"
python3 - "$toml" <<'PY'
import pathlib, sys, tomllib
value = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["mode"] == "relay" and value["enforcement"]["mode"] == "warn"
assert value["context"]["mode"] == "compact"
PY

COORDKIT_PLUGIN_ROOT="$PLUGIN" COORDKIT_PROJECT_DIR="$tmp" \
  bash "$PLUGIN/scripts/init-git.sh" git-room origin >/dev/null
test "$(sed -n '/^[[:space:]]*\[/q; /^[[:space:]]*mode[[:space:]]*=/p' "$toml")" = 'mode = "git"'
grep -q '^room_id = "git-room"$' "$toml"
grep -q '^remote = "origin"$' "$toml"
test "$(sed -n '/^\[enforcement\]/,/^\[/p' "$toml" | sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p')" = '"warn"'
test "$(sed -n '/^\[context\]/,/^\[/p' "$toml" | sed -n 's/^[[:space:]]*mode[[:space:]]*=[[:space:]]*//p')" = '"compact"'
python3 - "$toml" <<'PY'
import pathlib, sys, tomllib
value = tomllib.loads(pathlib.Path(sys.argv[1]).read_text())
assert value["mode"] == "git" and value["enforcement"]["mode"] == "warn"
assert value["context"]["mode"] == "compact"
PY

echo "transport config init: ok"
