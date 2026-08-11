#!/usr/bin/env bash
# shellcheck shell=bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  exec bash "${script_dir}/core/scripts/guard.sh" "$@"
fi
. "${script_dir}/core/scripts/guard.sh" || return 1
