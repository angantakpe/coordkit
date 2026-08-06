#!/usr/bin/env bash
# shellcheck shell=bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec bash "${script_dir}/core/scripts/ledger.sh" "$@"
