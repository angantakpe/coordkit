#!/usr/bin/env bash
# init-relay.sh — configure a repo's secret-free relay transport pointer.
set -euo pipefail

# shellcheck source=./common.sh
. "${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}/scripts/common.sh"

url="${1:-}"
room="${2:-default}"
case "$url" in
  https://*) ;;
  http://127.0.0.1:*|http://localhost:*) ;;
  *)
    echo "coordkit init-relay: use an https:// endpoint (http is allowed only on loopback)." >&2
    exit 2 ;;
esac
case "$url" in *$'\r'*|*$'\n'*|*[[:space:]]*) echo "coordkit init-relay: invalid endpoint." >&2; exit 2 ;; esac
case "$room" in ""|*[!A-Za-z0-9._:-]*)
  echo "coordkit init-relay: room must use only letters, digits, dot, underscore, colon, or dash." >&2
  exit 2 ;;
esac
[ "${#room}" -le 200 ] || { echo "coordkit init-relay: room is longer than 200 characters." >&2; exit 2; }

repo="$(git -C "$(ck_project_dir)" rev-parse --show-toplevel 2>/dev/null)" || {
  echo "coordkit init-relay: run this inside the project Git repository." >&2
  exit 1
}
plugin="$(ck_plugin_root)"
coord="${repo}/.claude/coord"
toml="${coord}/coord.toml"
mkdir -p "$coord"
if [ ! -f "$toml" ]; then
  cp "${plugin}/templates/coord.toml" "$toml"
fi
[ -f "${plugin}/schema/MANIFEST.json" ] && cp -f "${plugin}/schema/MANIFEST.json" "${coord}/MANIFEST.json"

ck_toml_set_top "$toml" mode relay
ck_toml_set_top "$toml" room_id "$room"
ck_toml_set_top "$toml" relay_url "$url"

ck_git_info_exclude_add "$repo" '/.coordkit-bus/'

echo "coordkit init-relay: relay pointer configured for ${repo}"
echo "  endpoint = ${url}"
echo "  room_id  = ${room}"
echo "  pointer  = ${toml}"
echo
echo "No token was written. Next steps:"
echo "  1) export COORDKIT_RELAY_TOKEN through your shell, keychain, or secret manager"
case "$url" in http://*) echo "     local HTTP also requires: export COORDKIT_RELAY_ALLOW_INSECURE_HTTP=1" ;; esac
echo "  2) review the pointer, then run: cobus trust"
echo "  3) verify delivery with: cobus relay-sync"
echo "  4) commit .claude/coord/coord.toml .claude/coord/MANIFEST.json"
