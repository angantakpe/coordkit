#!/usr/bin/env bash
# shellcheck shell=bash
CORE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../packages/core" 2>/dev/null && pwd)"
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)"
export COORDKIT_CORE_ROOT="${COORDKIT_CORE_ROOT:-$CORE_ROOT}"
export COORDKIT_PLUGIN_ROOT="${COORDKIT_PLUGIN_ROOT:-$PLUGIN_ROOT}"
exec bash "$COORDKIT_CORE_ROOT/scripts/command-registry.sh" "$@"
