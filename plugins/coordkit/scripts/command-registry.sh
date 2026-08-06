#!/usr/bin/env bash
# shellcheck shell=bash
# command-registry.sh — provider-neutral command surface metadata.
#
# The command markdown files remain harness-specific wrappers, but this registry
# is the shared source of truth for what each command means and how it is exposed
# on each surface. Other scripts should query this file instead of hardcoding
# Claude/Codex labels.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

ROOT="${COORDKIT_PLUGIN_ROOT:-${CLAUDE_PLUGIN_ROOT:-${CODEX_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." 2>/dev/null && pwd)}}}"
# shellcheck source=./common.sh
. "${ROOT}/scripts/common.sh" 2>/dev/null || exit 0

CATALOG="$(ck_command_catalog_file)"

[ -f "$CATALOG" ] || exit 0

normalize_host() {
  case "${1:-}" in
    claude|claude-code|claude_code) printf 'claude-code' ;;
    codex) printf 'codex' ;;
    cli|shell) printf 'cli' ;;
    *) printf 'cli' ;;
  esac
}

case "${1:-list}" in
  list)
    jq -r '.commands | to_entries[] | [.key, .value.description] | @tsv' "$CATALOG"
    ;;
  show)
    name="${2:-}"
    [ -n "$name" ] || exit 0
    jq -c --arg name "$name" '.commands[$name] // empty' "$CATALOG"
    ;;
  surface)
    host="$(normalize_host "${2:-}")"
    name="${3:-}"
    [ -n "$name" ] || exit 0
    jq -r --arg host "$host" --arg name "$name" '
      .commands[$name].surfaces[$host]
      // .commands[$name].surfaces.default
      // empty
    ' "$CATALOG"
    ;;
  describe)
    host="$(normalize_host "${2:-}")"
    name="${3:-}"
    [ -n "$name" ] || exit 0
    jq -r --arg host "$host" --arg name "$name" '
      .commands[$name] as $cmd
      | if $cmd == null then empty
        else {
          name: $name,
          host: $host,
          description: $cmd.description,
          surface: ($cmd.surfaces[$host] // $cmd.surfaces.default // empty)
        } | @json
        end
    ' "$CATALOG"
    ;;
  *)
    exit 0
    ;;
esac

exit 0
