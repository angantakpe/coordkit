#!/usr/bin/env bash
# shellcheck shell=bash
set -uo pipefail

ROOT="${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-${GEMINI_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}}"
# shellcheck source=../transports/lib.sh
. "${ROOT}/transports/lib.sh" 2>/dev/null || exit 1

case "${1:-status}" in
  status)
    __relay_status
    ;;
  sync)
    __relay_sync
    __relay_status
    ;;
  *)
    echo "usage: relay-client.sh status|sync" >&2
    exit 2
    ;;
esac
