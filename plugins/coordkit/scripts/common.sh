#!/usr/bin/env bash
# shellcheck shell=bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
. "${script_dir}/core/scripts/common.sh" || exit 1
return 0 2>/dev/null || exit 0
